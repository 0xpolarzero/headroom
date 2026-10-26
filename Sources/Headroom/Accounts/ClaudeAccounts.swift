import Foundation

/// Where Headroom keeps its own files: the account list, the relay's state, its CA and its log.
enum HeadroomPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Headroom", isDirectory: true)
    }()
    static let accounts = support.appendingPathComponent("claude-accounts.json")
    static let relayState = support.appendingPathComponent("relay-state.json")
    static let relayDir = support.appendingPathComponent("relay", isDirectory: true)
    static let tokenLock = support.appendingPathComponent("claude-tokens.lock")
    static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Headroom", isDirectory: true)

    /// Creates `dir` readable by the user only.
    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// One entry of the priority list: the account Claude Code is signed in to, or one Headroom signed in.
enum AccountRef: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Whatever account the request's own token belongs to (the Claude app's or the terminal's sign-in).
    case main
    case extra(String)   // account UUID

    var key: String {
        switch self {
        case .main: "main"
        case .extra(let uuid): uuid
        }
    }

    init(key: String) { self = key == "main" ? .main : .extra(key) }

    var description: String { key }

    init(from decoder: Decoder) throws { self.init(key: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

/// An account Headroom signed in itself. Its tokens are in the keychain, never in this file.
struct ClaudeAccount: Codable, Hashable, Sendable, Identifiable {
    var uuid: String
    var email: String?
    var orgUUID: String?
    var plan: String?
    /// Keep using it past its limit when Anthropic would bill extra usage.
    var allowOverage = false
    var addedAt = Date()

    var id: String { uuid }

    init(uuid: String, email: String?, orgUUID: String?, plan: String?) {
        self.uuid = uuid
        self.email = email
        self.orgUUID = orgUUID
        self.plan = plan
    }

    // Missing keys take their defaults, so fields can be added without losing saved accounts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        orgUUID = try c.decodeIfPresent(String.self, forKey: .orgUUID)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        allowOverage = try c.decodeIfPresent(Bool.self, forKey: .allowOverage) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}

/// The account list and routing switch, shared by the app (writes) and the relay (reads).
struct ClaudeAccountsConfig: Codable, Equatable, Sendable {
    var accounts: [ClaudeAccount] = []
    /// Priority order; always contains `.main` exactly once.
    var order: [AccountRef] = [.main]
    /// Keep using Main past its limit when Anthropic would bill extra usage.
    var mainAllowOverage = false
    /// New sessions skip an account once its Session or Weekly use reaches this (0...1); 1 = never.
    var newSessionThreshold = ClaudeAccountsConfig.defaultThreshold
    static let defaultThreshold = 0.85
    /// Claude Code is pointed at the relay (the keys are in `~/.claude/settings.json`).
    var routing = false
    /// When those keys were last written. Only processes started after this trust the relay's CA.
    var routingSince: Date?
    /// The `env` keys Headroom added to `settings.json`, so turning off touches only those.
    var wroteKeys: [String] = []
    /// After turning off, the keys stay as "" until then (so running sessions drop them), then go.
    var cleanupAfter: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([ClaudeAccount].self, forKey: .accounts) ?? []
        order = try c.decodeIfPresent([AccountRef].self, forKey: .order) ?? [.main]
        mainAllowOverage = try c.decodeIfPresent(Bool.self, forKey: .mainAllowOverage) ?? false
        newSessionThreshold = try c.decodeIfPresent(Double.self, forKey: .newSessionThreshold) ?? Self.defaultThreshold
        routing = try c.decodeIfPresent(Bool.self, forKey: .routing) ?? false
        routingSince = try c.decodeIfPresent(Date.self, forKey: .routingSince)
        wroteKeys = try c.decodeIfPresent([String].self, forKey: .wroteKeys) ?? []
        cleanupAfter = try c.decodeIfPresent(Date.self, forKey: .cleanupAfter)
    }

    func account(_ uuid: String) -> ClaudeAccount? { accounts.first { $0.uuid == uuid } }

    /// Keeps `order` consistent with `accounts`: drops unknown entries, appends missing ones, one `.main`.
    mutating func normalize() {
        var seen = Set<AccountRef>()
        order = order.filter { ref in
            guard !seen.contains(ref) else { return false }
            if case .extra(let uuid) = ref, account(uuid) == nil { return false }
            seen.insert(ref)
            return true
        }
        if !seen.contains(.main) { order.append(.main) }
        for a in accounts where !seen.contains(.extra(a.uuid)) { order.insert(.extra(a.uuid), at: 0) }
    }

    static func load() -> ClaudeAccountsConfig {
        guard let data = try? Data(contentsOf: HeadroomPaths.accounts),
              var config = try? JSONDecoder.headroom.decode(ClaudeAccountsConfig.self, from: data) else { return .init() }
        config.normalize()
        return config
    }

    func save() throws {
        HeadroomPaths.ensure(HeadroomPaths.support)
        let data = try JSONEncoder.headroom.encode(self)
        try data.write(to: HeadroomPaths.accounts, options: .atomic)
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
