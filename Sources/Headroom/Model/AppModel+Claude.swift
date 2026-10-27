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
    /// The account its Claude Code sign-in belongs to; nil when not signed in yet.
    var cliUUID: String?
    /// Below both thresholds, so it can take subagents from sessions on other accounts.
    var takesSubagents = false
    var id: String { account.id }
    var isMain: Bool { account.isMain }

    func used(_ label: String) -> Double? { snapshot?.windows.first { $0.label == label }?.usedPercent }
}

extension AppModel {
    // MARK: Derived

    /// Several accounts: the Claude card lists them instead of one set of meters.
    var showsClaudeAccounts: Bool { !claudeConfig.accounts.isEmpty }

    var claudeRows: [ClaudeAccountRow] {
        claudeConfig.ordered.map { account -> ClaudeAccountRow in
            let s = account.isMain ? state(.claude) : claudeAccountStates[account.id] ?? ProviderState()
            let cli = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir)
            let plan = s.snapshot?.plan
            let name = account.isMain ? plan.map { String($0.split(separator: " ")[0]) } ?? "Main" : account.id
            var row = ClaudeAccountRow(account: account, name: name, email: cli.email, plan: plan, snapshot: s.snapshot,
                                       error: s.error, cliUUID: cli.uuid)
            if let session = row.used("Session"), let weekly = row.used("Weekly") {
                row.takesSubagents = session < claudeConfig.sessionThreshold * 100 && weekly < claudeConfig.weeklyThreshold * 100
            }
            return row
        }
    }

    // MARK: Ticks

    /// Every 15 s and when the panel opens: the account list, whether the server is registered, due usage.
    func claudeTick(panelOpened: Bool = false) async {
        let fresh = ClaudeAccountsConfig.load()
        if fresh != claudeConfig { claudeConfig = fresh }
        let installed = SubagentInstaller.isInstalled()
        if installed != subagentsInstalled { subagentsInstalled = installed }
        await refreshClaudeAccounts(force: false, throttle: panelOpened ? Self.openThrottle : nil)
        writeUsageStatus()
    }

    /// Each account's latest usage for the subagent runner, so it needn't ask Anthropic on every run.
    private func writeUsageStatus() {
        var status: [String: SubagentUsage.Status] = [:]
        for row in claudeRows {
            let s = row.isMain ? state(.claude) : claudeAccountStates[row.id] ?? ProviderState()
            // Kept through errors (rate limited, say): when it was read goes with it.
            guard let at = s.lastSuccess, s.snapshot != nil else { continue }
            status[row.id] = .init(session: row.used("Session"), weekly: row.used("Weekly"), at: at)
        }
        let saved = SubagentUsage.readStatus()
        // A runner may have read an account more recently than the app.
        for (id, entry) in saved where (status[id]?.at ?? .distantPast) < entry.at { status[id] = entry }
        if status != saved { SubagentUsage.writeStatus(status) }
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

    /// Adds an account and opens Terminal, where Claude Code signs it in.
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
        signInTerminal(id)
    }

    func signInTerminal(_ id: String) {
        guard let row = claudeRows.first(where: { $0.id == id }) else { return }
        do {
            try ClaudeSignIn.openTerminalSignIn(row.account, name: row.name)
        } catch {
            claudeError = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    /// Forgets the account in Headroom. Its Claude Code folder stays on disk.
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

    func setThresholds(session: Double? = nil, weekly: Double? = nil) {
        updateConfig { config in
            if let session { config.sessionThreshold = session }
            if let weekly { config.weeklyThreshold = weekly }
        }
    }

    func setSubagentsInstalled(_ on: Bool) {
        claudeError = nil
        Task {
            do {
                try await on ? SubagentInstaller.install() : SubagentInstaller.uninstall()
            } catch {
                claudeError = error.localizedDescription
            }
            subagentsInstalled = SubagentInstaller.isInstalled()
        }
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
