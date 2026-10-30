import Foundation

typealias Bytes = UnsafeBufferPointer<UInt8>

/// Reads a few fields of a JSON object without allocating. Transcripts run to many gigabytes, and nearly all of
/// that is message text the stats never look at: skipping it byte by byte is hundreds of times cheaper than
/// parsing it. It walks real JSON structure, so a key inside a string or a nested object can't be mistaken for one.
enum JSONSkim {
    /// Calls `visit` with each key and raw value of the object in `bytes`. Stops at the first malformed byte.
    @inline(__always)
    static func fields(_ bytes: Bytes, _ visit: (Bytes, Bytes) -> Void) {
        var i = whitespace(bytes, 0)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return }
        i = whitespace(bytes, i + 1)
        while i < bytes.count, bytes[i] == UInt8(ascii: "\"") {
            guard let keyEnd = stringEnd(bytes, i) else { return }
            let key = Bytes(rebasing: bytes[(i + 1)..<(keyEnd - 1)])
            i = whitespace(bytes, keyEnd)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return }
            i = whitespace(bytes, i + 1)
            guard let valueEnd = valueEnd(bytes, i) else { return }
            visit(key, Bytes(rebasing: bytes[i..<valueEnd]))
            i = whitespace(bytes, valueEnd)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ",") else { return }
            i = whitespace(bytes, i + 1)
        }
    }

    @inline(__always)
    private static func whitespace(_ b: Bytes, _ start: Int) -> Int {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    /// The index just past the string that opens at `start`.
    private static func stringEnd(_ b: Bytes, _ start: Int) -> Int? {
        var i = start + 1
        let base = b.baseAddress!
        while i < b.count, let hit = memchr(base + i, 0x22, b.count - i) {
            let quote = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
            var backslashes = 0
            while quote - backslashes - 1 > start, b[quote - backslashes - 1] == 0x5C { backslashes += 1 }
            if backslashes % 2 == 0 { return quote + 1 }
            i = quote + 1
        }
        return nil
    }

    /// The index just past the value that opens at `start`.
    private static func valueEnd(_ b: Bytes, _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case 0x22: return stringEnd(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case 0x22:
                    guard let end = stringEnd(b, i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, b[i] != UInt8(ascii: ","), b[i] != UInt8(ascii: "}"), b[i] != UInt8(ascii: "]"), b[i] > 0x20 { i += 1 }
            return i
        }
    }
}

extension UnsafeBufferPointer<UInt8> {
    /// Whether these bytes are exactly `text`.
    @inline(__always)
    func `is`(_ text: StaticString) -> Bool {
        count == text.utf8CodeUnitCount && memcmp(baseAddress, text.utf8Start, count) == 0
    }

    /// The whole number in these bytes; 0 for anything else, as `null`.
    var int: Int64 {
        var value: Int64 = 0
        for byte in self {
            guard byte >= 0x30, byte <= 0x39 else { return 0 }
            value = value &* 10 &+ Int64(byte - 0x30)
        }
        return value
    }

    /// The text of a JSON string value; nil for anything else.
    var string: String? {
        guard count >= 2, self[0] == 0x22 else { return nil }
        let inner = Bytes(rebasing: self[1..<(count - 1)])
        guard memchr(inner.baseAddress, 0x5C, inner.count) != nil else { return String(decoding: inner, as: UTF8.self) }
        return try? JSONSerialization.jsonObject(with: Data(self), options: .fragmentsAllowed) as? String
    }

    /// The bytes of a JSON string value without its quotes, as they stand in the file.
    var rawString: Bytes {
        count >= 2 && self[0] == 0x22 ? Bytes(rebasing: self[1..<(count - 1)]) : Bytes(start: nil, count: 0)
    }

    var bool: Bool { self.is("true") }

    func contains(_ needle: StaticString) -> Bool {
        memmem(baseAddress, count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// The hour of an ISO 8601 UTC time ("2026-10-30T16:25:03.424Z"), in hours since 1970.
    var utcHour: Int32? {
        guard count >= 14, self[count - 1] == UInt8(ascii: "Z"), self[4] == 0x2D, self[7] == 0x2D, self[10] == UInt8(ascii: "T") else { return nil }
        func number(_ start: Int, _ length: Int) -> Int {
            var value = 0
            for i in start..<(start + length) { value = value * 10 + Int(self[i]) - 0x30 }
            return value
        }
        // Days from the civil date, after Howard Hinnant's algorithm.
        let month = number(5, 2), day = number(8, 2)
        let year = number(0, 4) - (month <= 2 ? 1 : 0)
        let era = year / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int32((era * 146097 + dayOfEra - 719468) * 24 + number(11, 2))
    }
}

/// FNV-1a, stable across launches, unlike Swift's `Hasher`. Keeps dedupe keys to eight bytes.
struct StableHash {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    @inline(__always)
    mutating func add(_ bytes: Bytes) {
        for byte in bytes { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        value = (value ^ 0xFF) &* 0x100000001b3
    }

    mutating func add(_ number: Int64) {
        withUnsafeBytes(of: number) { add($0.assumingMemoryBound(to: UInt8.self)) }
    }

    /// As SQLite stores it.
    var signed: Int64 { Int64(bitPattern: value) }

    static func of(_ text: String) -> Int64 {
        var hash = StableHash()
        var text = text
        text.withUTF8 { hash.add($0) }
        return hash.signed
    }
}
