import AppKit
import Foundation

/// Signing an account in: Claude Code does it itself, in Terminal, in the account's own folder.
enum ClaudeSignIn {
    /// What a new account's terminal sign-in shares with `~/.claude`: everything but the sessions
    /// and the sign-in itself.
    static let sharedItems = ["settings.json", "settings.local.json", "CLAUDE.md", "skills", "agents", "commands",
                              "hooks", "plugins", "output-styles"]

    /// Prepares the account's Claude Code folder (links to the shared items in `~/.claude`) and opens
    /// Terminal on `claude` there, where Claude Code signs in itself.
    static func openTerminalSignIn(_ account: ClaudeAccount, name: String) throws {
        let fm = FileManager.default
        if let dir = account.cliConfigDir {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let shared = NSHomeDirectory() + "/.claude"
            for item in sharedItems {
                let source = shared + "/" + item, target = dir + "/" + item
                guard fm.fileExists(atPath: source),
                      (try? fm.attributesOfItem(atPath: target)) == nil else { continue }   // keep anything already there
                try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            }
        }
        let script = HeadroomPaths.support.appendingPathComponent("sign-in-\(account.id).command")
        HeadroomPaths.ensure(HeadroomPaths.support)
        let export = account.cliConfigDir.map { "export CLAUDE_CONFIG_DIR=\(shellQuote($0))\n" } ?? ""
        try """
        #!/bin/zsh -l
        \(export)echo "Claude Code for \(name): sign in with the same account as its Claude window."
        echo "If it doesn't ask, type /login. Headroom reads this sign-in to show the account's usage."
        exec claude
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    /// Claude Code renews an account's sign-in when it starts; Headroom only reads it. So when an account's
    /// sign-in has expired (unused for a while), Headroom starts Claude Code on it with no prompt, which costs
    /// no usage, until its usage reads again, then lets it go. Nil when that didn't renew it.
    static func renew(_ account: ClaudeAccount) async -> UsageSnapshot? {
        guard !account.isMain, let claude = SubagentRunner.executable() else { return nil }
        SubagentLog.write("renewing the \(account.id) sign-in")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        process.environment = SubagentRunner.environment(for: account, from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { try? input.fileHandleForWriting.close() }   // no prompt: it exits by itself
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(2))
            if let snapshot = try? await ClaudeProvider(configDir: account.cliConfigDir).fetch() { return snapshot }
            if !process.isRunning { break }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
