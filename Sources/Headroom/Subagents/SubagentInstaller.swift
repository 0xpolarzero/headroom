import Foundation

/// Registers `Headroom --mcp` with Claude Code for every session (user scope), through Claude Code's own
/// `claude mcp add`, so Headroom never edits Claude Code's files itself.
enum SubagentInstaller {
    static let name = "headroom"

    enum InstallError: LocalizedError {
        case noClaude, failed(String)
        var errorDescription: String? {
            switch self {
            case .noClaude: "Claude Code (`claude`) was not found on this Mac."
            case .failed(let output): "Claude Code refused: \(output)"
            }
        }
    }

    /// The server is listed under `mcpServers` in `~/.claude.json`.
    static func isInstalled() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let root = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return false }
        return root.dict("mcpServers")?[name] != nil
    }

    static func install() async throws {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        if isInstalled() { try await claude(["mcp", "remove", "--scope", "user", name]) }
        try await claude(["mcp", "add", "--scope", "user", name, "--", executable, "--mcp"])
    }

    static func uninstall() async throws {
        try await claude(["mcp", "remove", "--scope", "user", name])
    }

    private static func claude(_ args: [String]) async throws {
        guard let path = SubagentRunner.executable() else { throw InstallError.noClaude }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // Its own default config, whichever session or account Headroom was started from.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.failed(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
