import Foundation

/// Edits keys of the top-level `env` object in Claude Code's `settings.json` without reformatting the
/// rest of the file: only the changed members are touched, everything else stays byte for byte.
enum SettingsFile {
    static var url: URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
    }

    enum EditError: LocalizedError {
        case notJSON, busy
        var errorDescription: String? {
            switch self {
            case .notJSON: "~/.claude/settings.json is not plain JSON, so Headroom left it alone."
            case .busy: "~/.claude/settings.json kept changing while Headroom tried to update it. Try again."
            }
        }
    }

    /// The current `env` values (strings only).
    static func env(in text: String) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return [:] }
        return env.compactMapValues { $0 as? String }
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Applies `transform` to the current file and writes the result. If the file changes between the
    /// read and the write (Claude Code saving its own settings), it starts over, so nothing is lost.
    static func modify(_ transform: (String) throws -> String) throws {
        for _ in 0..<5 {
            let before = read() ?? ""
            let after = try transform(before)
            guard after != before else { return }
            guard (read() ?? "") == before else { continue }
            try write(after)
            return
        }
        throw EditError.busy
    }

    /// Writes in place in one call, keeping the file's permissions; Claude Code watches it and applies
    /// `env` live.
    static func write(_ text: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Sets (non-nil) or removes (nil) members of the top-level `env` object. An `env` left empty by a
    /// removal is removed too; a missing one is created as the first member of the root object.
    static func update(_ text: String, env changes: [(key: String, value: String?)]) throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : text
        guard (try? JSONSerialization.jsonObject(with: Data(source.utf8))) is [String: Any] else { throw EditError.notJSON }
        var bytes = Array(source.utf8)
        for (key, value) in changes {
            bytes = try apply(bytes, key: key, value: value)
        }
        let out = String(decoding: bytes, as: UTF8.self)
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8))) is [String: Any] else { throw EditError.notJSON }
        return out
    }

    // MARK: Editing

    private struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int   // exclusive
    }

    private static func apply(_ b: [UInt8], key: String, value: String?) throws -> [UInt8] {
        guard let rootOpen = skipSpace(b, 0), rootOpen < b.count, b[rootOpen] == UInt8(ascii: "{") else { throw EditError.notJSON }
        let (rootMembers, rootClose) = try members(b, open: rootOpen)
        let literal = Array(quoted(value ?? "").utf8)

        if let env = rootMembers.first(where: { $0.key == "env" }), b[env.valueStart] != UInt8(ascii: "{") {
            // `"env": null` or another non-object: replace it rather than add a second "env".
            guard value != nil else { return b }
            let indent = indentation(b, before: env.keyStart)
            let object = "{\n\(indent)  \(quoted(key)): " + String(decoding: literal, as: UTF8.self) + "\n\(indent)}"
            var out = b
            out.replaceSubrange(env.valueStart..<env.valueEnd, with: Array(object.utf8))
            return out
        }
        guard let env = rootMembers.first(where: { $0.key == "env" }) else {
            guard value != nil else { return b }
            // No env object: add one as the root's first member.
            let indent = rootMembers.first.map { indentation(b, before: $0.keyStart) } ?? "  "
            let inner = indent + indent
            var insert = "\n\(indent)\"env\": {\n\(inner)\(quoted(key)): " + String(decoding: literal, as: UTF8.self) + "\n\(indent)}"
            insert += rootMembers.isEmpty ? "\n" : ","
            var out = b
            if rootMembers.isEmpty {
                // "{}" or "{ }": replace everything between the braces.
                out.replaceSubrange((rootOpen + 1)..<rootClose, with: Array(insert.utf8))
            } else {
                out.insert(contentsOf: Array(insert.utf8), at: rootOpen + 1)
            }
            return out
        }

        let (envMembers, envClose) = try members(b, open: env.valueStart)
        var out = b
        if let i = envMembers.firstIndex(where: { $0.key == key }) {
            let member = envMembers[i]
            if value != nil {
                out.replaceSubrange(member.valueStart..<member.valueEnd, with: literal)
                return out
            }
            if envMembers.count == 1 {
                // The last key: drop the whole env member from the root.
                return removeMember(b, members: rootMembers, index: rootMembers.firstIndex { $0.key == "env" }!, close: rootClose)
            }
            return removeMember(b, members: envMembers, index: i, close: envClose)
        }
        guard value != nil else { return b }
        if let last = envMembers.last {
            let indent = indentation(b, before: last.keyStart)
            let insert = ",\n\(indent)\(quoted(key)): " + String(decoding: literal, as: UTF8.self)
            out.insert(contentsOf: Array(insert.utf8), at: last.valueEnd)
        } else {
            let outer = indentation(b, before: env.keyStart)
            let insert = "\n\(outer)  \(quoted(key)): " + String(decoding: literal, as: UTF8.self) + "\n\(outer)"
            out.replaceSubrange((env.valueStart + 1)..<envClose, with: Array(insert.utf8))
        }
        return out
    }

    /// Removes a member and the comma that separated it from its neighbour.
    private static func removeMember(_ b: [UInt8], members: [Member], index i: Int, close: Int) -> [UInt8] {
        var out = b
        if i > 0 {
            out.removeSubrange(members[i - 1].valueEnd..<members[i].valueEnd)
        } else if members.count > 1 {
            out.removeSubrange(members[0].keyStart..<members[1].keyStart)
        } else {
            // Only member: keep the braces, drop what was between them.
            let open = members[0].keyStart
            var start = open
            while start > 0, b[start - 1] != UInt8(ascii: "{") { start -= 1 }
            out.removeSubrange(start..<close)
        }
        return out
    }

    private static func indentation(_ b: [UInt8], before index: Int) -> String {
        var i = index
        while i > 0, b[i - 1] == UInt8(ascii: " ") || b[i - 1] == UInt8(ascii: "\t") { i -= 1 }
        return String(decoding: b[i..<index], as: UTF8.self)
    }

    private static func quoted(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: Scanning

    /// The members of the object whose `{` is at `open`, and the index of its `}`.
    private static func members(_ b: [UInt8], open: Int) throws -> ([Member], Int) {
        var result: [Member] = []
        guard var i = skipSpace(b, open + 1) else { throw EditError.notJSON }
        if b[i] == UInt8(ascii: "}") { return ([], i) }
        while true {
            guard b[i] == UInt8(ascii: "\"") else { throw EditError.notJSON }
            let keyStart = i
            let keyEnd = try skipString(b, i)
            let key = (try? JSONDecoder().decode(String.self, from: Data(b[keyStart..<keyEnd]))) ?? ""
            guard let colon = skipSpace(b, keyEnd), b[colon] == UInt8(ascii: ":"),
                  let valueStart = skipSpace(b, colon + 1) else { throw EditError.notJSON }
            let valueEnd = try skipValue(b, valueStart)
            result.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            guard let next = skipSpace(b, valueEnd) else { throw EditError.notJSON }
            if b[next] == UInt8(ascii: "}") { return (result, next) }
            guard b[next] == UInt8(ascii: ","), let after = skipSpace(b, next + 1) else { throw EditError.notJSON }
            i = after
        }
    }

    private static func skipSpace(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start
        while i < b.count, [9, 10, 13, 32].contains(b[i]) { i += 1 }
        return i < b.count ? i : nil
    }

    /// Index just past the string starting at `start`.
    private static func skipString(_ b: [UInt8], _ start: Int) throws -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        throw EditError.notJSON
    }

    /// Index just past the value starting at `start`.
    private static func skipValue(_ b: [UInt8], _ start: Int) throws -> Int {
        switch b[start] {
        case UInt8(ascii: "\""):
            return try skipString(b, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""): i = try skipString(b, i); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            throw EditError.notJSON
        default:
            var i = start
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 9, 10, 13, 32].contains(b[i]) { i += 1 }
            return i
        }
    }
}
