import AppKit
import Darwin
import Foundation

/// The copies of the Claude app, one per account, and each account's terminal sign-in.
///
/// A second copy runs with Chromium's `--user-data-dir`, which the Claude app honours (it ignores
/// `CLAUDE_USER_DATA_DIR` in signed builds). macOS sees every copy as the same app, so the Dock icon
/// and `open -a Claude` reach whichever copy is already running; Headroom tells them apart by the
/// `--user-data-dir` argument each process was started with.
enum ClaudeApps {
    static let bundleID = "com.anthropic.claudefordesktop"

    // MARK: Running copies

    /// Running copies by data folder (`nil` key: the default one, Main).
    static func running() -> [String?: NSRunningApplication] {
        var result: [String?: NSRunningApplication] = [:]
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let dir = arguments(of: app.processIdentifier)?.lazy
                .compactMap { $0.hasPrefix("--user-data-dir=") ? String($0.dropFirst("--user-data-dir=".count)) : nil }
                .first
            result[dir.map(normalize)] = app
        }
        return result
    }

    static func isRunning(_ account: ClaudeAccount) -> Bool { runningApp(account) != nil }

    static func runningApp(_ account: ClaudeAccount) -> NSRunningApplication? {
        running()[account.isMain ? nil : normalize(account.appDataDir)]
    }

    private static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// A process's arguments, from `KERN_PROCARGS2` (argc, the executable path, then argv).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    // MARK: Opening

    /// Brings the account's Claude window forward, starting its copy if needed.
    static func open(_ account: ClaudeAccount) {
        if let app = runningApp(account) {
            app.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Always a new instance: otherwise macOS just activates whichever copy is already running.
        configuration.createsNewApplicationInstance = true
        if !account.isMain { configuration.arguments = ["--user-data-dir=\(account.appDataDir)"] }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // MARK: Sign-ins

    /// The account the app copy is signed in to, from its `config.json`; nil when signed out.
    static func appAccountUUID(_ account: ClaudeAccount) -> String? {
        let url = URL(fileURLWithPath: account.appDataDir + "/config.json")
        guard let root = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              root["oauth:tokenCacheV2"] != nil || root["oauth:tokenCache"] != nil else { return nil }
        return root.string("lastKnownAccountUuid")
    }

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
        // An interactive login shell, so the user's own launcher is found: some setups block plain
        // `claude` and start it through a confirming `clod` alias instead.
        try """
        #!/bin/zsh -il
        \(export)echo "Claude Code for \(name): sign in with the same account as its Claude window."
        echo "If it doesn't ask, type /login. Headroom reads this sign-in to show the account's usage."
        if whence clod >/dev/null; then clod; else claude; fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
