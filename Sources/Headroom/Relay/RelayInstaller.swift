import Foundation
import Network

/// Turns routing on and off: the relay's LaunchAgent and the three `env` keys in Claude Code's
/// `settings.json`. Nothing of the Claude app is touched.
enum RelayInstaller {
    static let label = "dev.polarzero.headroom.relay"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var logURL: URL { HeadroomPaths.logs.appendingPathComponent("relay.log") }

    /// The keys Headroom sets while routing is on.
    static func keys() -> [(String, String)] {
        [("HTTPS_PROXY", Relay.proxyURL),
         ("NODE_EXTRA_CA_CERTS", LocalCA.caCert.path),
         ("NO_PROXY", "localhost,127.0.0.1,::1")]
    }

    enum InstallError: LocalizedError {
        case proxyInUse(String), relayDown
        var errorDescription: String? {
            switch self {
            case .proxyInUse(let v): "Claude Code already uses a proxy (\(v)) in ~/.claude/settings.json."
            case .relayDown: "The relay did not start. See ~/Library/Logs/Headroom/relay.log."
            }
        }
    }

    // MARK: On and off

    /// Starts the relay, then points Claude Code at it. Sessions started from now on route through it.
    static func enable() async throws {
        var config = ClaudeAccountsConfig.load()
        let text = SettingsFile.read() ?? ""
        let env = SettingsFile.env(in: text)
        for key in ["HTTPS_PROXY", "https_proxy"] {
            if let current = env[key], !current.isEmpty, current != Relay.proxyURL { throw InstallError.proxyInUse(current) }
        }

        try LocalCA.ensure()
        try await ensureAgent()

        // NO_PROXY is only added when the user has none of their own.
        let changes = keys().filter { key, _ in key != "NO_PROXY" || (env[key] ?? "").isEmpty || config.wroteKeys.contains(key) }
        try SettingsFile.modify { try SettingsFile.update($0, env: changes.map { (key: $0.0, value: $0.1) }) }
        // Set after the write: a process started in between has the CA but is not trusted yet, which
        // only means a plain tunnel. The other way round it would fail TLS.
        config.routing = true
        config.routingSince = Date()
        config.wroteKeys = changes.map(\.0)
        config.cleanupAfter = nil
        try config.save()
    }

    /// Stops new decryption and blanks the keys, so running sessions drop the proxy live. The keys
    /// are removed by `finishCleanup` a minute later; the relay keeps tunnelling until it is idle.
    static func disable() throws {
        var config = ClaudeAccountsConfig.load()
        config.routing = false
        config.cleanupAfter = Date().addingTimeInterval(60)
        try config.save()
        if SettingsFile.read() != nil {
            let blank = config.wroteKeys.map { (key: $0, value: Optional("")) }
            try SettingsFile.modify { try SettingsFile.update($0, env: blank) }
        }
    }

    /// Removes the blanked keys once running sessions have had time to pick up the blank values.
    static func finishCleanup(now: Date = .now) {
        var config = ClaudeAccountsConfig.load()
        guard !config.routing, let after = config.cleanupAfter, after <= now else { return }
        if SettingsFile.read() != nil {
            // Only keys still blank: anything the user set in the meantime stays.
            try? SettingsFile.modify { text in
                let env = SettingsFile.env(in: text)
                let removals = config.wroteKeys.filter { env[$0] == "" }.map { (key: $0, value: String?.none) }
                return removals.isEmpty ? text : try SettingsFile.update(text, env: removals)
            }
        }
        config.wroteKeys = []
        config.cleanupAfter = nil
        try? config.save()
    }

    // MARK: LaunchAgent

    static func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Relay.port)\(Relay.healthPath)")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await HTTP.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200 && data == Data("ok".utf8)
    }

    /// Installs and starts the agent unless a healthy relay from this same binary already runs.
    /// A running relay is never restarted needlessly: that would cut every Claude Code connection.
    static func ensureAgent() async throws {
        let plist = agentPlist()
        let current = try? Data(contentsOf: plistURL)
        if current == plist, await isHealthy() { return }
        HeadroomPaths.ensure(HeadroomPaths.logs)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: plistURL, options: .atomic)
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])
        launchctl(["bootstrap", domain, plistURL.path])
        for _ in 0..<20 {
            if await isHealthy() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw InstallError.relayDown
    }

    /// Called by the relay when it stops for good, so it isn't started again at the next login.
    static func removeAgentFile() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func agentPlist() -> Data {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--relay"],
            "RunAtLoad": true,
            // Restarted after a crash, not after it stops itself.
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "ProcessType": "Interactive",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// `Headroom --relay`: the relay process the LaunchAgent runs.
enum RelayMain {
    static func run() -> Never {
        setvbuf(stderr, nil, _IOLBF, 0)
        let engine = RelayEngine()
        let server = RelayServer(engine: engine)
        Task.detached {
            var identity: sec_identity_t?
            do {
                try LocalCA.ensure()
                identity = try LocalCA.identity()
            } catch {
                relayLog("No certificate, tunnelling only: \(error.localizedDescription)")
            }
            engine.hasIdentity = identity != nil
            do {
                try await server.start(identity: identity)
                relayLog("Relay listening on 127.0.0.1:\(Relay.port)")
            } catch {
                relayLog("Relay could not start: \(error)")
                exit(1)
            }
            await engine.runHousekeeping()
        }
        dispatchMain()
    }
}
