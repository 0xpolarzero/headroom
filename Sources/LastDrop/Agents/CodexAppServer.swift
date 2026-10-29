import Foundation
import Darwin

/// One `codex app-server --listen stdio://` process: JSON-RPC 2.0 over its stdin and stdout, one JSON object
/// per line. Requests wait for their answer; notifications queue up in `notifications` in order; requests
/// from the server go to `onRequest`, whose answer is written right away, so none is ever left hanging.
final class CodexAppServer: @unchecked Sendable {
    /// A JSON object off the wire. `Any` isn't Sendable, so it travels wrapped.
    struct Message: @unchecked Sendable {
        var object: [String: Any]
        var method: String? { object.string("method") }
        var params: [String: Any] { object.dict("params") ?? [:] }
    }

    /// A JSON-RPC error answer, kept whole rather than reduced to its message.
    struct RPCError: Error, LocalizedError {
        var code: Int
        var message: String
        var data: Any?
        var errorDescription: String? { message }
    }

    enum Reply {
        case result([String: Any])
        case error(code: Int, message: String)
    }

    let process = Process()
    let notifications: AsyncStream<Message>
    /// Answers a server request (its method and params): it runs on the reading thread, so keep it quick.
    let onRequest: @Sendable (String, [String: Any]) -> Reply

    private let continuation: AsyncStream<Message>.Continuation
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private struct Pending {
        var continuation: CheckedContinuation<[String: Any], Error>
        var timeout: DispatchWorkItem
    }
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var closed: Error?

    var pid: Int32 { process.processIdentifier }

    init(executable: String, directory: String, environment: [String: String],
         onRequest: @escaping @Sendable (String, [String: Any]) -> Reply = { _, _ in .error(code: -32601, message: "Not supported") }) {
        self.onRequest = onRequest
        (notifications, continuation) = AsyncStream.makeStream(of: Message.self)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        // A killed server can leave MCP children holding stdout open. Its own exit must end waiters.
        process.terminationHandler = { [weak self] _ in self?.finish() }
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let out = output.fileHandleForReading
        Thread.detachNewThread { [self] in read(out) }
        let err = errors.fileHandleForReading
        // Drain diagnostics without putting configuration values or credentials in a transcript.
        Thread.detachNewThread { while !err.availableData.isEmpty {} }
    }

    /// `initialize` with lastdrop as the client, then `initialized`.
    func initialize() async throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        _ = try await call("initialize", ["clientInfo": ["name": "lastdrop", "title": "lastdrop", "version": version],
                                          "capabilities": ["experimentalApi": false]])
        try send(["method": "initialized"])
    }

    /// Sends a request and waits for its answer. The connection ending first throws.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            if let closed {
                lock.unlock()
                return waiting.resume(throwing: closed)
            }
            nextID += 1
            let id = nextID
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.finish(RPCError(code: -32000, message: "Codex request timed out: \(method)", data: nil), waitingFor: id) {
                    self.stop()
                }
            }
            pending[id] = Pending(continuation: waiting, timeout: timer)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            do { try send(["id": id, "method": method, "params": params]) } catch { fail(id, error) }
        }
    }

    /// Ends waiters immediately, then asks the process to exit and kills it after five seconds if needed.
    func stop() {
        finish()
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) + Data("\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if let closed { throw closed }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func fail(_ id: Int, _ error: Error) {
        lock.lock()
        let waiting = pending.removeValue(forKey: id)
        lock.unlock()
        waiting?.timeout.cancel()
        waiting?.continuation.resume(throwing: error)
    }

    /// Reads lines until the process closes stdout, then fails whatever still waits.
    private func read(_ handle: FileHandle) {
        var buffer = Data()
        while case let data = handle.availableData, !data.isEmpty {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    finish(RPCError(code: -32700, message: "Codex returned invalid protocol JSON.", data: nil))
                    stop()
                    return
                }
                receive(object)
            }
        }
        finish()
    }

    @discardableResult
    private func finish(_ error: Error = RPCError(code: -32000, message: "Codex app-server exited", data: nil), waitingFor id: Int? = nil) -> Bool {
        lock.lock()
        guard closed == nil, id.map({ pending[$0] != nil }) ?? true else { lock.unlock(); return false }
        closed = error
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, w) in waiting { w.timeout.cancel(); w.continuation.resume(throwing: error) }
        continuation.finish()
        return true
    }

    private func receive(_ object: [String: Any]) {
        let message = Message(object: object)
        if let method = message.method {
            guard let id = object["id"] else { continuation.yield(message); return }
            do {
                switch onRequest(method, message.params) {
                case .result(let result): try send(["id": id, "result": result])
                case .error(let code, let text): try send(["id": id, "error": ["code": code, "message": text]])
                }
            } catch {
                finish(error)
                stop()
                return
            }
            continuation.yield(Message(object: ["method": "lastdrop/requestDeclined", "params": ["method": method]]))
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let waiting = pending.removeValue(forKey: id)
        lock.unlock()
        waiting?.timeout.cancel()
        if let error = object.dict("error") {
            waiting?.continuation.resume(throwing: RPCError(code: (error["code"] as? NSNumber)?.intValue ?? 0,
                                               message: error.string("message") ?? "Codex error", data: error["data"]))
        } else {
            waiting?.continuation.resume(returning: object.dict("result") ?? [:])
        }
    }
}
