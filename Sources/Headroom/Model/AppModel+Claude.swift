import AppKit
import Foundation

/// One Claude account with everything the panel, the menu bar and Settings show about it.
struct ClaudeAccountRow: Identifiable {
    var account: ClaudeAccount
    /// "Max", "Pro": what the menu bar and the panel call it.
    var name: String
    var email: String?
    var plan: String?
    var snapshot: UsageSnapshot?
    var error: String?
    /// The account its Claude window is signed in to; nil when that copy is signed out.
    var appUUID: String?
    /// The account its terminal sign-in (the one Headroom reads usage from) belongs to.
    var cliUUID: String?
    var isRunning: Bool
    /// New sessions should start here.
    var isRecommended = false
    var id: String { account.id }
    var isMain: Bool { account.isMain }

    /// The fuller of Session and Weekly, 0...100; nil without numbers.
    var used: Double? {
        let values = (snapshot?.windows ?? []).filter { $0.label == "Session" || $0.label == "Weekly" }.compactMap(\.usedPercent)
        return values.max()
    }

    /// The window and the terminal are signed in to different accounts.
    var mismatch: Bool { appUUID != nil && cliUUID != nil && appUUID != cliUUID }
}

extension AppModel {
    // MARK: Derived

    /// Several accounts: the Claude card lists them instead of one set of meters.
    var showsClaudeAccounts: Bool { !claudeConfig.accounts.isEmpty }

    var claudeRows: [ClaudeAccountRow] {
        var rows = claudeConfig.ordered.map { account -> ClaudeAccountRow in
            let s = account.isMain ? state(.claude) : claudeAccountStates[account.id] ?? ProviderState()
            let cli = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir)
            let plan = s.snapshot?.plan
            let name = account.isMain ? plan.map { String($0.split(separator: " ")[0]) } ?? "Main" : account.id
            return ClaudeAccountRow(account: account, name: name, email: cli.email, plan: plan, snapshot: s.snapshot,
                                    error: s.error, appUUID: claudeAppAccounts[account.id], cliUUID: cli.uuid,
                                    isRunning: claudeRunning.contains(account.id))
        }
        if let i = Self.recommended(rows.map(\.used), threshold: claudeConfig.newSessionThreshold * 100) {
            rows[i].isRecommended = true
        }
        return rows
    }

    /// Where new sessions should start: the first account in the order below the threshold; if every
    /// account is above it, the least used one that isn't full; nil when all are full or unknown.
    nonisolated static func recommended(_ used: [Double?], threshold: Double) -> Int? {
        if let first = used.firstIndex(where: { ($0 ?? 100) < threshold }) { return first }
        let open = used.enumerated().compactMap { i, u in u.flatMap { $0 < 100 ? (i, $0) : nil } }
        return open.min { $0.1 < $1.1 }?.0
    }

    // MARK: Ticks

    /// Every 15 s and when the panel opens: who runs and is signed in where, presets, due usage.
    func claudeTick(panelOpened: Bool = false) async {
        let fresh = ClaudeAccountsConfig.load()
        if fresh != claudeConfig { claudeConfig = fresh }
        let accounts = claudeConfig.ordered
        let running = Set(accounts.filter(ClaudeApps.isRunning).map(\.id))
        if running != claudeRunning { claudeRunning = running }
        var signedIn: [String: String] = [:]
        for account in accounts { signedIn[account.id] = ClaudeApps.appAccountUUID(account) }
        if signedIn != claudeAppAccounts { claudeAppAccounts = signedIn }
        if accounts.count > 1 { SessionPresets.sync(accounts) { ClaudeApps.runningApp($0)?.launchDate } }
        await refreshClaudeAccounts(force: false, throttle: panelOpened ? Self.openThrottle : nil)
        announceRecommendation()
    }

    /// One notification when new sessions should move to another account.
    private func announceRecommendation() {
        guard showsClaudeAccounts, let row = claudeRows.first(where: \.isRecommended) else { return }
        defer { lastRecommended = row.id }
        guard let previous = lastRecommended, previous != row.id, notificationsOn else { return }
        let from = claudeRows.first { $0.id == previous }
        let why = from?.used.map { " \(from!.name) is at \(Int($0.rounded()))%." } ?? ""
        post("Use \(row.name) for new Claude sessions.\(why)", id: "claude.recommend.\(row.id)")
    }

    func refreshClaudeAccounts(force: Bool, throttle: TimeInterval? = nil) async {
        guard isEnabled(.claude) else { return }
        let now = Date()
        let due = claudeConfig.accounts.filter { account in
            let s = claudeAccountStates[account.id] ?? ProviderState()
            guard !s.isLoading else { return false }
            guard !force, let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (throttle.map { s.error == nil ? $0 : s.retryDelay } ?? s.retryDelay)
        }
        await withTaskGroup(of: Void.self) { group in
            for account in due { group.addTask { await self.refreshClaudeAccount(account) } }
        }
    }

    private func refreshClaudeAccount(_ account: ClaudeAccount) async {
        let id = account.id
        claudeAccountStates[id, default: ProviderState()].isLoading = true
        claudeAccountStates[id]?.lastAttempt = .now
        do {
            let snapshot = try await ClaudeProvider(configDir: account.cliConfigDir).fetch()
            claudeAccountStates[id]?.snapshot = snapshot
            claudeAccountStates[id]?.error = nil
            claudeAccountStates[id]?.notConfigured = false
            claudeAccountStates[id]?.rateLimited = false
            claudeAccountStates[id]?.lastSuccess = .now
            checkLimits(.claude, snapshot, account: id)
        } catch {
            claudeAccountStates[id]?.error = error.localizedDescription
            if case ProviderError.notConfigured = error { claudeAccountStates[id]?.notConfigured = true }
            if case ProviderError.rateLimited = error { claudeAccountStates[id]?.rateLimited = true }
        }
        claudeAccountStates[id]?.isLoading = false
    }

    // MARK: Accounts

    /// Adds an account and opens its Claude window, where it signs in.
    func addClaudeAccount(name: String) {
        let id = ClaudeAccount.slug(name)
        claudeError = nil
        guard !id.isEmpty, id.lowercased() != ClaudeAccount.mainID else {
            claudeError = "Pick a name made of letters or digits, other than \"main\"."
            return
        }
        guard !claudeConfig.accounts.contains(where: { $0.id.lowercased() == id.lowercased() }) else {
            claudeError = "There is already an account called \(id)."
            return
        }
        updateConfig { config in
            config.accounts.append(ClaudeAccount(id: id))
            config.normalize()
        }
        openClaudeWindow(id)
    }

    func openClaudeWindow(_ id: String) {
        guard let account = claudeConfig.ordered.first(where: { $0.id == id }) else { return }
        ClaudeApps.open(account)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await claudeTick()
        }
    }

    func signInTerminal(_ id: String) {
        guard let row = claudeRows.first(where: { $0.id == id }) else { return }
        do {
            try ClaudeApps.openTerminalSignIn(row.account, name: row.name)
        } catch {
            claudeError = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    /// Forgets the account in Headroom. Its app folder and Claude Code folder stay on disk.
    func removeClaudeAccount(_ id: String) {
        updateConfig { config in
            config.accounts.removeAll { $0.id == id }
            config.normalize()
        }
        claudeAccountStates[id] = nil
    }

    func moveClaudeAccount(_ id: String, by offset: Int) {
        updateConfig { config in
            guard let i = config.order.firstIndex(of: id), config.order.indices.contains(i + offset) else { return }
            config.order.swapAt(i, i + offset)
        }
    }

    func setNewSessionThreshold(_ value: Double) {
        updateConfig { $0.newSessionThreshold = value }
    }

    private func updateConfig(_ change: (inout ClaudeAccountsConfig) -> Void) {
        var config = ClaudeAccountsConfig.load()
        change(&config)
        do {
            try config.save()
            claudeConfig = config
        } catch {
            claudeError = "Could not save the account list: \(error.localizedDescription)"
        }
    }
}
