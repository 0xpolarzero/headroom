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
            let s = state(of: Account(provider: .claude, key: account.id))
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

    /// Every 15 s and when the panel opens: the account list, whether the plugin is installed, and the
    /// Claude accounts' usage for the subagent runner.
    func claudeTick() async {
        let fresh = AccountsConfig.load()
        if fresh != accountsConfig { accountsConfig = fresh }
        syncPlugin()
        writeUsageStatus()
    }

    /// Each account's latest usage for the subagent runner, so it needn't ask Anthropic on every run.
    private func writeUsageStatus() {
        var status: [String: SubagentUsage.Status] = [:]
        for row in claudeRows {
            let s = state(of: Account(provider: .claude, key: row.id))
            // Kept through errors (rate limited, say): when it was read goes with it.
            guard let at = s.lastSuccess, s.snapshot != nil else { continue }
            status[row.id] = .init(session: row.used("Session"), weekly: row.used("Weekly"), at: at)
        }
        let saved = SubagentUsage.readStatus()
        // A runner may have read an account more recently than the app.
        for (id, entry) in saved where (status[id]?.at ?? .distantPast) < entry.at { status[id] = entry }
        if status != saved { SubagentUsage.writeStatus(status) }
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
        forgetUsage(Account(provider: .claude, key: id))
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

    func setSubagentsInstalled(_ on: Bool) { setFeature(.agents, on) }

    private func updateConfig(_ change: (inout ClaudeAccountsConfig) -> Void) {
        var config = ClaudeAccountsConfig.load()
        change(&config)
        do {
            try config.save()
            accountsConfig = AccountsConfig.load()
        } catch {
            claudeError = "Could not save the account list: \(error.localizedDescription)"
        }
    }
}
