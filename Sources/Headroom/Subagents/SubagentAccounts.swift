import Foundation

/// Which Claude account a subagent runs on: never the calling session's own account, only accounts
/// below both thresholds, and among those the one with the most room left.
enum SubagentAccounts {
    struct Candidate: Equatable, Sendable {
        var account: ClaudeAccount
        var name: String
        var sessionUsed: Double?   // 0...100
        var weeklyUsed: Double?
        /// Subagents this server is running on it right now; spreads parallel calls over accounts.
        var active = 0
    }

    /// The best candidate, or nil when none has room. Unknown usage counts as no room: an account whose
    /// limits can't be read can't be trusted not to be full.
    static func pick(_ candidates: [Candidate], sessionThreshold: Double, weeklyThreshold: Double) -> Candidate? {
        func room(_ c: Candidate) -> Double? {
            guard let s = c.sessionUsed, let w = c.weeklyUsed,
                  s < sessionThreshold * 100, w < weeklyThreshold * 100 else { return nil }
            return min(sessionThreshold * 100 - s, weeklyThreshold * 100 - w) - Double(c.active) * 10
        }
        var best: (Candidate, Double)?
        for c in candidates {
            guard let r = room(c) else { continue }
            if best == nil || r > best!.1 { best = (c, r) }   // ties keep the earlier one in the order
        }
        return best?.0
    }

    /// The account the calling session runs as: the Claude app passes it to its Code-tab sessions; a
    /// terminal session is the one its config folder is signed in to.
    static func ownAccountUUID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let uuid = environment["CLAUDE_CODE_ACCOUNT_UUID"], !uuid.isEmpty { return uuid }
        let dir = environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
        return ClaudeProvider.signedInAccount(configDir: dir).uuid
    }
}

/// Usage per account, read from each account's own Claude Code sign-in, kept for two minutes.
actor SubagentUsage {
    static let shared = SubagentUsage()
    private var cache: [String: (at: Date, sessionUsed: Double?, weeklyUsed: Double?)] = [:]

    func usage(_ account: ClaudeAccount) async -> (session: Double?, weekly: Double?) {
        if let hit = cache[account.id], Date().timeIntervalSince(hit.at) < 120 { return (hit.sessionUsed, hit.weeklyUsed) }
        let snapshot = try? await ClaudeProvider(configDir: account.cliConfigDir).fetch()
        func used(_ label: String) -> Double? { snapshot?.windows.first { $0.label == label }?.usedPercent }
        cache[account.id] = (Date(), used("Session"), used("Weekly"))
        return (used("Session"), used("Weekly"))
    }

    /// An account that just answered "limit reached" counts as full for the next ten minutes.
    func markFull(_ account: ClaudeAccount) {
        cache[account.id] = (Date().addingTimeInterval(480), 100, 100)
    }
}
