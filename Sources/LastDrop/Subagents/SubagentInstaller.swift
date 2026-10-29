import Foundation

/// Installs lastdrop's Claude Code plugin for every session (user scope), through Claude Code's own
/// `claude plugin` commands. The plugin ships inside lastdrop.app as a folder marketplace, which Claude
/// Code reads in place, so it updates with the app.
enum SubagentInstaller {
    static let marketplace = "lastdrop"
    static let plugin = "lastdrop@lastdrop"

    enum InstallError: LocalizedError {
        case noClaude, noPlugin, failed(String)
        var errorDescription: String? {
            switch self {
            case .noClaude: "Claude Code (`claude`) was not found on this Mac."
            case .noPlugin: "This copy of lastdrop has no Claude Code plugin; build it with script/build_app.sh."
            case .failed(let output): "Claude Code refused: \(output)"
            }
        }
    }

    /// The plugin's marketplace folder inside the app bundle.
    static var marketplaceFolder: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/ClaudePlugin"
        return FileManager.default.fileExists(atPath: path + "/.claude-plugin/marketplace.json") ? path : nil
    }

    /// Enabled in Claude Code's user settings (`enabledPlugins` in `~/.claude/settings.json`).
    static func isInstalled() -> Bool { isEnabled(plugin) }

    /// The plugin under the app's old name, which installing replaces.
    static func oldIsInstalled() -> Bool { isEnabled(Rename.oldPlugin) }

    private static func isEnabled(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        guard let root = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return false }
        return root.dict("enabledPlugins")?[name] as? Bool == true
    }

    static func install() async throws {
        guard let folder = marketplaceFolder else { throw InstallError.noPlugin }
        if oldIsInstalled() {
            _ = try? await claude(["plugin", "uninstall", Rename.oldPlugin, "--scope", "user"])
            _ = try? await claude(["plugin", "marketplace", "remove", Rename.oldMarketplace])
        }
        _ = try? await claude(["plugin", "marketplace", "remove", marketplace])
        try await claude(["plugin", "marketplace", "add", folder])
        try await claude(["plugin", "install", plugin, "--scope", "user"])
    }

    static func uninstall() async throws {
        try await claude(["plugin", "uninstall", plugin, "--scope", "user"])
        _ = try? await claude(["plugin", "marketplace", "remove", marketplace])
    }

    @discardableResult
    private static func claude(_ args: [String]) async throws -> String {
        guard let path = SubagentRunner.executable() else { throw InstallError.noClaude }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // Its own default config, whichever session or account lastdrop was started from.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw InstallError.failed(text) }
        return text
    }
}
