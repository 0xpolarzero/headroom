import AppKit
import Foundation

/// One row of the Claude priority list, with everything the panel and Settings show about it.
struct ClaudeAccountRow: Identifiable {
    var ref: AccountRef
    var name: String
    var plan: String?
    var snapshot: UsageSnapshot?
    var error: String?
    var limits: AccountLimitState?
    /// New Claude Code sessions start on this account now.
    var inUse: Bool
    /// Claude Code sessions on this account whose cache is still warm.
    var activeSessions: Int
    var isMain: Bool { ref == .main }
    var allowOverage: Bool
    var id: String { ref.key }
}

extension AppModel {
    // MARK: Derived

    /// Several accounts or routing: the Claude card lists accounts instead of one set of meters.
    var showsClaudeAccounts: Bool { !claudeConfig.accounts.isEmpty || claudeConfig.routing }

    var mainUUID: String? { relayState?.mainUUID ?? signedIn.appUUID ?? signedIn.cliUUID }

    var claudeRows: [ClaudeAccountRow] {
        let inUse = relayState?.inUse
        let active = relayState?.activeSessions() ?? [:]
        return claudeConfig.order.compactMap { ref in
            switch ref {
            case .main:
                let key = mainUUID ?? "main"
                let email = relayState?.mainEmail ?? (signedIn.cliUUID == mainUUID ? signedIn.cliEmail : nil)
                return ClaudeAccountRow(ref: .main, name: email ?? "Claude app account",
                                        plan: relayState?.mainPlan ?? state(.claude).snapshot?.plan,
                                        snapshot: state(.claude).snapshot, error: state(.claude).error,
                                        limits: relayState?.accounts[key], inUse: claudeConfig.routing && inUse == "main",
                                        activeSessions: claudeConfig.routing ? active["main", default: 0] : 0,
                                        allowOverage: claudeConfig.mainAllowOverage)
            case .extra(let uuid):
                guard let account = claudeConfig.account(uuid) else { return nil }
                let s = claudeAccountStates[uuid]
                let limits = relayState?.accounts[uuid]
                return ClaudeAccountRow(ref: ref, name: account.email ?? "Account \(uuid.prefix(8))",
                                        plan: s?.snapshot?.plan ?? account.plan, snapshot: s?.snapshot,
                                        error: limits?.signInNeeded == true ? "Sign in again." : s?.error,
                                        limits: limits, inUse: claudeConfig.routing && inUse == uuid,
                                        activeSessions: claudeConfig.routing ? active[uuid, default: 0] : 0,
                                        allowOverage: account.allowOverage)
            }
        }
    }

    /// The snapshot the Claude menu bar item shows: the account Claude Code is using now.
    var claudeMenuBarSnapshot: UsageSnapshot? {
        if claudeConfig.routing, let row = claudeRows.first(where: \.inUse), let snapshot = row.snapshot { return snapshot }
        return state(.claude).snapshot
    }

    /// "Back to Pro at 17:40" when Claude Code is not on its first choice.
    var claudeReturnNote: String? {
        let rows = claudeRows
        guard claudeConfig.routing, let used = rows.firstIndex(where: \.inUse), used > 0 else { return nil }
        let first = rows[0]
        guard let until = first.limits?.limitedUntil, until > .now else { return nil }
        return "Back to \(first.name) at \(Format.clock(until))"
    }

    // MARK: Ticks

    func startClaude() {
        signedIn = ClaudeProvider.signedInAccounts()
        Task {
            if claudeConfig.routing {
                relayHealthy = await RelayInstaller.isHealthy()
                // Restart a relay that died while routing is on: without it Claude Code can't connect.
                if !relayHealthy { try? await RelayInstaller.ensureAgent(); relayHealthy = await RelayInstaller.isHealthy() }
            }
        }
    }

    /// Every 15 s: relay state, health, delayed cleanup, and the accounts' usage when due.
    func claudeTick(panelOpened: Bool = false) async {
        RelayInstaller.finishCleanup()
        let fresh = ClaudeAccountsConfig.load()
        if fresh != claudeConfig { claudeConfig = fresh }
        loadRelayState()
        if claudeConfig.routing { relayHealthy = await RelayInstaller.isHealthy() }
        if panelOpened { signedIn = ClaudeProvider.signedInAccounts() }
        await refreshClaudeAccounts(force: false, throttle: panelOpened ? Self.openThrottle : nil)
    }

    func loadRelayState() {
        guard let state = RelayState.load() else { return }
        if state != relayState { relayState = state }
        announceSwitches(state)
    }

    /// One notification per switch the relay made since the last one announced.
    private func announceSwitches(_ state: RelayState) {
        let fresh = state.events.filter { $0.at > (lastAnnouncedSwitch ?? .distantPast) && $0.from != nil }
        guard let newest = state.events.last?.at else { return }
        defer { lastAnnouncedSwitch = max(newest, lastAnnouncedSwitch ?? .distantPast) }
        // The first time, only remember where the history ends.
        guard lastAnnouncedSwitch != nil, notificationsOn, claudeConfig.routing else { return }
        for event in fresh.suffix(2) {
            post(Self.describe(event, name: name(forKey:)), id: "claude.switch.\(event.at.timeIntervalSince1970)")
        }
    }

    /// "A running session moved to Max: session limit on Pro." / "New sessions start on Max: Pro is over 85%."
    static func describe(_ event: RelayEvent, name: (String) -> String) -> String {
        let to = name(event.to)
        let from = event.from.map(name) ?? ""
        if event.kind == "moved" { return "A running session moved to \(to): \(event.reason.lowercased()) on \(from)." }
        if event.reason.hasPrefix("Over") { return "New sessions start on \(to): \(from) is \(event.reason.lowercased())." }
        if event.reason == "Available again" { return "New sessions start on \(to) again." }
        return "New sessions start on \(to): \(event.reason.lowercased()) on \(from)."
    }

    func setNewSessionThreshold(_ value: Double) {
        updateConfig { $0.newSessionThreshold = value }
    }

    func name(forKey key: String) -> String {
        if key == "main" || key == mainUUID { return claudeRows.first(where: \.isMain)?.name ?? "the main account" }
        return claudeConfig.account(key)?.email ?? "another account"
    }

    func refreshClaudeAccounts(force: Bool, throttle: TimeInterval? = nil) async {
        guard isEnabled(.claude) else { return }
        let now = Date()
        let due = claudeConfig.accounts.filter { account in
            let s = claudeAccountStates[account.uuid] ?? ProviderState()
            guard !s.isLoading else { return false }
            guard !force, let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (throttle.map { s.error == nil ? $0 : s.retryDelay } ?? s.retryDelay)
        }
        await withTaskGroup(of: Void.self) { group in
            for account in due { group.addTask { await self.refreshClaudeAccount(account) } }
        }
    }

    private func refreshClaudeAccount(_ account: ClaudeAccount) async {
        let uuid = account.uuid
        claudeAccountStates[uuid, default: ProviderState()].isLoading = true
        claudeAccountStates[uuid]?.lastAttempt = .now
        do {
            let token = try await ClaudeTokens.shared.accessToken(uuid)
            let windows = try await ClaudeProvider.usageWindows(accessToken: token, expired: "This account's sign-in has ended. Sign in again.")
            let snapshot = UsageSnapshot(title: "Claude", plan: account.plan, windows: windows)
            claudeAccountStates[uuid]?.snapshot = snapshot
            claudeAccountStates[uuid]?.error = nil
            claudeAccountStates[uuid]?.rateLimited = false
            claudeAccountStates[uuid]?.lastSuccess = .now
            checkLimits(.claude, snapshot, account: uuid)
        } catch {
            claudeAccountStates[uuid]?.error = error.localizedDescription
            if case ProviderError.rateLimited = error { claudeAccountStates[uuid]?.rateLimited = true }
        }
        claudeAccountStates[uuid]?.isLoading = false
    }

    // MARK: Accounts

    func addClaudeAccount(loginHint: String) {
        guard !claudeSigningIn else { return }
        claudeSigningIn = true
        claudeError = nil
        claudeSignInTask = Task {
            do {
                let (login, profile) = try await ClaudeOAuth.signIn(loginHint: loginHint)
                if profile.uuid == mainUUID || profile.uuid == signedIn.cliUUID {
                    throw ProviderError.message("That is the account Claude is already signed in to. It is in the list as Main.")
                }
                guard await ClaudeTokens.shared.save(profile.uuid, login) else {
                    throw ProviderError.message("Could not save the sign-in to the Keychain.")
                }
                updateConfig { config in
                    if let i = config.accounts.firstIndex(where: { $0.uuid == profile.uuid }) {
                        config.accounts[i].email = profile.email
                        config.accounts[i].plan = profile.plan
                        config.accounts[i].orgUUID = profile.orgUUID
                    } else {
                        config.accounts.append(ClaudeAccount(uuid: profile.uuid, email: profile.email,
                                                             orgUUID: profile.orgUUID, plan: profile.plan))
                    }
                    config.normalize()
                }
                claudeAccountStates[profile.uuid] = nil
                await refreshClaudeAccounts(force: true)
            } catch is CancellationError {
            } catch {
                claudeError = error.localizedDescription
            }
            claudeSigningIn = false
            NSApp.activate()
        }
    }

    func cancelClaudeSignIn() { claudeSignInTask?.cancel() }

    func removeClaudeAccount(_ uuid: String) {
        Task { await ClaudeTokens.shared.forget(uuid) }
        updateConfig { config in
            config.accounts.removeAll { $0.uuid == uuid }
            config.normalize()
        }
        claudeAccountStates[uuid] = nil
    }

    func moveClaudeAccount(_ ref: AccountRef, by offset: Int) {
        updateConfig { config in
            guard let i = config.order.firstIndex(of: ref), config.order.indices.contains(i + offset) else { return }
            config.order.swapAt(i, i + offset)
        }
    }

    func setAllowOverage(_ ref: AccountRef, _ on: Bool) {
        updateConfig { config in
            switch ref {
            case .main: config.mainAllowOverage = on
            case .extra(let uuid):
                if let i = config.accounts.firstIndex(where: { $0.uuid == uuid }) { config.accounts[i].allowOverage = on }
            }
        }
    }

    /// Re-reads the file first: the installer may have changed routing fields since.
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

    // MARK: Routing

    func setRouting(_ on: Bool) {
        guard !routingBusy else { return }
        routingBusy = true
        claudeError = nil
        Task {
            do {
                if on { try await RelayInstaller.enable() } else { try RelayInstaller.disable() }
            } catch {
                claudeError = error.localizedDescription
            }
            claudeConfig = ClaudeAccountsConfig.load()
            relayHealthy = await RelayInstaller.isHealthy()
            routingBusy = false
        }
    }
}
