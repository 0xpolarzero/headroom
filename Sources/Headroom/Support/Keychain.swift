import Foundation

/// Keychain access through `/usr/bin/security`.
///
/// Items created by the `security` tool (Claude Code, Antigravity's go-keyring, and our own)
/// list that tool in their access list, so reading them this way never shows a prompt,
/// even though Headroom is only ad-hoc signed and its signature changes on every build.
enum Keychain {
    static func read(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        guard let out = run(args), !out.isEmpty else { return nil }
        return out
    }

    /// Our own secrets are stored base64-encoded and written through `security -i` on stdin,
    /// so they never appear in a process argument list.
    static func writeOwn(service: String, account: String, value: String) -> Bool {
        let encoded = Data(value.utf8).base64EncodedString()
        let line = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(encoded)\"\n"
        return run(["-i"], stdin: line) != nil
    }

    static func readOwn(service: String, account: String) -> String? {
        guard let encoded = read(service: service, account: account),
              let data = Data(base64Encoded: encoded) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        run(["delete-generic-password", "-s", service, "-a", account]) != nil
    }

    private static func run(_ args: [String], stdin: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        let input = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = input
        do { try p.run() } catch { return nil }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
