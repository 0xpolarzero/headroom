import Foundation

/// Where Headroom keeps its own files.
enum HeadroomPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Headroom", isDirectory: true)
    }()
    static let accounts = support.appendingPathComponent("claude-accounts.json")
    static let presetSync = support.appendingPathComponent("preset-sync.json")

    /// Creates `dir` readable by the user only.
    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// One Claude account: its own copy of the Claude app (a data folder of its own, so its own sign-in and
/// session list) and its own terminal sign-in (a Claude Code config folder), which is what Headroom reads
/// usage from. Main is the default pair: the Claude app as installed, and `~/.claude`.
struct ClaudeAccount: Codable, Hashable, Sendable, Identifiable {
    static let mainID = "main"

    /// "main", or a short name also used in folder names ("Pro").
    var id: String
    var addedAt = Date()

    var isMain: Bool { id == Self.mainID }

    /// The Claude app's data folder for this account.
    var appDataDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        return isMain ? support + "/Claude" : support + "/Claude-\(id)"
    }

    /// `CLAUDE_CONFIG_DIR` for this account's terminal sign-in; nil for Main (the default `~/.claude`).
    var cliConfigDir: String? { isMain ? nil : NSHomeDirectory() + "/.claude-accounts/\(id)" }

    init(id: String) { self.id = id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    /// "Pro" → "Pro"; "my work" → "my-work". Letters, digits, "-" and "_" only.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.trimmingCharacters(in: .whitespaces).components(separatedBy: allowed.inverted)
        return parts.filter { !$0.isEmpty }.joined(separator: "-")
    }
}

/// The account list and its order, in Headroom's support folder.
struct ClaudeAccountsConfig: Codable, Equatable, Sendable {
    /// Accounts besides Main.
    var accounts: [ClaudeAccount] = []
    /// Priority order of account IDs; always contains "main" exactly once.
    var order: [String] = [ClaudeAccount.mainID]
    /// New sessions go to the first account below this share (0...1) of its Session and Weekly limits.
    var newSessionThreshold = ClaudeAccountsConfig.defaultThreshold
    static let defaultThreshold = 0.85

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([ClaudeAccount].self, forKey: .accounts) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? [ClaudeAccount.mainID]
        newSessionThreshold = try c.decodeIfPresent(Double.self, forKey: .newSessionThreshold) ?? Self.defaultThreshold
    }

    /// Every account, Main included, in priority order.
    var ordered: [ClaudeAccount] {
        order.compactMap { id in id == ClaudeAccount.mainID ? ClaudeAccount(id: id) : accounts.first { $0.id == id } }
    }

    /// Keeps `order` consistent with `accounts`: drops unknown IDs, appends missing ones, one "main".
    mutating func normalize() {
        var seen = Set<String>()
        order = order.filter { id in
            guard !seen.contains(id), id == ClaudeAccount.mainID || accounts.contains(where: { $0.id == id }) else { return false }
            seen.insert(id)
            return true
        }
        if !seen.contains(ClaudeAccount.mainID) { order.insert(ClaudeAccount.mainID, at: 0) }
        for a in accounts where !seen.contains(a.id) { order.append(a.id) }
    }

    static func load() -> ClaudeAccountsConfig {
        guard let data = try? Data(contentsOf: HeadroomPaths.accounts),
              var config = try? JSONDecoder.headroom.decode(ClaudeAccountsConfig.self, from: data) else { return .init() }
        config.normalize()
        return config
    }

    func save() throws {
        HeadroomPaths.ensure(HeadroomPaths.support)
        try JSONEncoder.headroom.encode(self).write(to: HeadroomPaths.accounts, options: .atomic)
    }
}

extension JSONEncoder {
    static let headroom: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let headroom: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
