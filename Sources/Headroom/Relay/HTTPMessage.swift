import Foundation
import Network

/// The start line and headers of an HTTP/1.1 message, kept in order and case so they can be
/// forwarded exactly as they came, apart from what the relay changes on purpose.
struct HTTPHead: Equatable, Sendable {
    var startLine: String
    var headers: [(name: String, value: String)]

    static func == (a: HTTPHead, b: HTTPHead) -> Bool {
        a.startLine == b.startLine && a.headers.map(\.name) == b.headers.map(\.name) && a.headers.map(\.value) == b.headers.map(\.value)
    }

    /// Parses everything before the blank line (the `\r\n\r\n` excluded).
    static func parse(_ data: Data) -> HTTPHead? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty, !lines[0].isEmpty else { return nil }
        let start = lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return HTTPHead(startLine: start, headers: headers)
    }

    var serialized: Data {
        var text = startLine + "\r\n"
        for h in headers { text += "\(h.name): \(h.value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    mutating func set(_ name: String, _ value: String) {
        if let i = headers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[i].value = value
            headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.value != value }
        } else {
            headers.append((name, value))
        }
    }

    mutating func remove(_ name: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // Request line: "POST /v1/messages?beta=true HTTP/1.1"
    var method: String { String(startLine.split(separator: " ").first ?? "") }
    var target: String { startLine.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    // Status line: "HTTP/1.1 429 Too Many Requests"
    var statusCode: Int { Int(startLine.split(separator: " ").dropFirst().first ?? "") ?? 0 }

    var contentLength: Int? { value("content-length").flatMap { Int($0) } }
    var isChunked: Bool { value("transfer-encoding")?.lowercased().contains("chunked") == true }

    /// Lowercased names, last value wins; for reading rate-limit headers.
    var lowercasedHeaders: [String: String] {
        var out: [String: String] = [:]
        for h in headers { out[h.name.lowercased()] = h.value }
        return out
    }
}

/// Buffered async reads over an `NWConnection`.
final class ByteStream: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    enum StreamError: Error { case closed, tooLarge, malformed }

    /// More bytes, or nil at end of stream.
    private func receive() async throws -> Data? {
        if closed { return nil }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    if isComplete { self.closed = true }
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    self.closed = true
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// The head of the next message, or nil if the stream ended cleanly before one started.
    func readHead(limit: Int = 128 * 1024) async throws -> HTTPHead? {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let r = buffer.range(of: separator) {
                let head = buffer[buffer.startIndex..<r.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                guard let parsed = HTTPHead.parse(Data(head)) else { throw StreamError.malformed }
                return parsed
            }
            guard buffer.count < limit else { throw StreamError.tooLarge }
            guard let more = try await receive() else {
                if buffer.isEmpty { return nil }
                throw StreamError.closed
            }
            buffer.append(more)
        }
    }

    func read(exactly n: Int) async throws -> Data {
        while buffer.count < n {
            guard let more = try await receive() else { throw StreamError.closed }
            buffer.append(more)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    func readLine(limit: Int = 8192) async throws -> Data {
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buffer.range(of: crlf) {
                let line = buffer[buffer.startIndex..<r.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return Data(line)
            }
            guard buffer.count < limit else { throw StreamError.tooLarge }
            guard let more = try await receive() else { throw StreamError.closed }
            buffer.append(more)
        }
    }

    /// Puts bytes read past the end of a message back, for the next read.
    func unread(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer = data + buffer
    }

    /// Whatever is available next (buffered first), or nil at end of stream.
    func readSome() async throws -> Data? {
        if !buffer.isEmpty {
            let out = buffer
            buffer = Data()
            return out
        }
        return try await receive()
    }

    /// A request body, de-chunked if it came chunked.
    func readBody(of head: HTTPHead, limit: Int = 64 * 1024 * 1024) async throws -> Data {
        if head.isChunked {
            var body = Data()
            while true {
                let sizeLine = String(decoding: try await readLine(), as: UTF8.self)
                guard let size = Int(sizeLine.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16)
                else { throw StreamError.malformed }
                if size == 0 {
                    while !(try await readLine()).isEmpty {}   // trailers
                    return body
                }
                body.append(try await read(exactly: size))
                _ = try await readLine()
                guard body.count <= limit else { throw StreamError.tooLarge }
            }
        }
        let n = head.contentLength ?? 0
        guard n <= limit else { throw StreamError.tooLarge }
        return n > 0 ? try await read(exactly: n) : Data()
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() { connection.cancel() }
}

/// Tracks a chunked body passing through unchanged, to know where it ends.
struct ChunkedScanner {
    private enum State { case size, data(Int), dataCRLF(Int), trailer, done }
    private var state = State.size
    private var line = Data()

    var isDone: Bool { if case .done = state { true } else { false } }

    /// Feeds bytes; returns how many of them belong to the body (the rest is the next message).
    mutating func feed(_ data: Data) -> Int {
        var i = data.startIndex
        while i < data.endIndex {
            switch state {
            case .done:
                return i - data.startIndex
            case .data(let left):
                let take = min(left, data.endIndex - i)
                i += take
                state = left - take == 0 ? .dataCRLF(2) : .data(left - take)
            case .dataCRLF(let left):
                i += 1
                state = left == 1 ? .size : .dataCRLF(left - 1)
            case .size, .trailer:
                let byte = data[i]
                i += 1
                if byte == UInt8(ascii: "\n") {
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    line = Data()
                    if case .trailer = state {
                        if text.isEmpty { state = .done }
                    } else {
                        let size = Int(text.split(separator: ";").first ?? "", radix: 16) ?? 0
                        state = size == 0 ? .trailer : .data(size)
                    }
                } else {
                    line.append(byte)
                }
            }
        }
        return i - data.startIndex
    }
}
