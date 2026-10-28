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

    /// Points of usage each subagent already running on an account is expected to take before it ends.
    static let reservedPerAgent = 10.0

    /// The best candidate, or nil when none has room. Unknown usage counts as no room: an account whose
    /// limits can't be read can't be trusted not to be full. The subagents running on an account count
    /// against its room, so a burst of calls doesn't all land on one account's last few points.
    static func pick(_ candidates: [Candidate], sessionThreshold: Double, weeklyThreshold: Double) -> Candidate? {
        func room(_ c: Candidate) -> Double? {
            guard let s = c.sessionUsed, let w = c.weeklyUsed else { return nil }
            let r = min(sessionThreshold * 100 - s, weeklyThreshold * 100 - w) - Double(c.active) * reservedPerAgent
            return r > 0 ? r : nil
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

/// Usage per account: what the Headroom app last read (it refreshes every few minutes), else read now from
/// the account's own Claude Code sign-in. An account that just answered "limit reached" counts as full.
actor SubagentUsage {
    static let shared = SubagentUsage()
    private var cache: [String: (at: Date, sessionUsed: Double?, weeklyUsed: Double?)] = [:]

    struct Status: Codable, Equatable { var session: Double?; var weekly: Double?; var at: Date }

    func usage(_ account: ClaudeAccount) async -> (session: Double?, weekly: Double?) {
        if AgentRegistry.isFull(account.id) { return (100, 100) }
        let saved = Self.readStatus()[account.id]
        if let saved, Date().timeIntervalSince(saved.at) < 360 { return (saved.session, saved.weekly) }
        if let hit = cache[account.id], Date().timeIntervalSince(hit.at) < 120 { return (hit.sessionUsed, hit.weeklyUsed) }
        var snapshot: UsageSnapshot?
        do {
            snapshot = try await ClaudeProvider(configDir: account.cliConfigDir).fetch()
        } catch ProviderError.unauthorized {
            snapshot = await ClaudeSignIn.renew(account)
            if snapshot == nil { SubagentLog.write("the \(account.id) sign-in couldn't be renewed") }
        } catch {
            SubagentLog.write("usage of \(account.id) unreadable: \(error.localizedDescription)")
            // Rate limited, say: an older reading beats none. A full account still answers "limit reached".
            if let saved, Date().timeIntervalSince(saved.at) < 30 * 60 { return (saved.session, saved.weekly) }
            snapshot = nil
        }
        func used(_ label: String) -> Double? { snapshot?.windows.first { $0.label == label }?.usedPercent }
        cache[account.id] = (Date(), used("Session"), used("Weekly"))
        // Shared with the next runners, which are other processes.
        if snapshot != nil {
            var status = Self.readStatus()
            status[account.id] = Status(session: used("Session"), weekly: used("Weekly"), at: Date())
            Self.writeStatus(status)
        }
        return (used("Session"), used("Weekly"))
    }

    /// Full for the next ten minutes, for every runner.
    func markFull(_ account: ClaudeAccount) { AgentRegistry.markFull(account.id) }

    static func readStatus() -> [String: Status] {
        (try? Data(contentsOf: HeadroomPaths.usage)).flatMap { try? JSONDecoder.headroom.decode([String: Status].self, from: $0) } ?? [:]
    }

    static func writeStatus(_ status: [String: Status]) {
        HeadroomPaths.ensure(HeadroomPaths.support)
        try? JSONEncoder.headroom.encode(status).write(to: HeadroomPaths.usage, options: .atomic)
    }
}
