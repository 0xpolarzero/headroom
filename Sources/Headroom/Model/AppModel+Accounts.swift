import AppKit
import Foundation

/// Whether an account works for one feature, as its row shows it.
enum Capability: Equatable, Sendable {
    case ready
    /// Not working, with what to do about it ("Install agy").
    case problem(String)
    /// Not known yet: still loading.
    case pending
}

/// What Headroom found about an account on this Mac, without asking the provider. Slow to work out (it reads
/// the keychain through `security`), so it's refreshed in the background and kept.
struct LocalCheck: Equatable, Sendable {
    var connected: Bool
    var email: String?
    /// Nil when this account doesn't run agents.
    var agents: Capability?
}

/// One account as the panel and Settings show it.
struct AccountInfo: Identifiable {
    var account: Account
    var name: String
    var email: String?
    var plan: String?
    var state: ProviderState
    var limits: Capability
    /// Nil when agents are off or this account doesn't run them.
    var agents: Capability?
    /// A Claude account under both thresholds, so other accounts' sessions can send it subagents.
    var takesSubagents = false
    var id: String { account.id }

    func used(_ label: String) -> Double? { state.snapshot?.windows.first { $0.label == label }?.usedPercent }
}

/// Where adding an account stands.
enum ConnectStatus: Equatable {
    case idle
    /// Waiting for the browser or checking a key; the text says which.
    case working(String)
    case failed(String)
}

extension AppModel {
    // MARK: What to show

    /// The provider's accounts that are connected, or were added: a main account shows once a login is found.
    func accounts(_ provider: ProviderID) -> [AccountInfo] {
        accountsConfig.pool(provider).compactMap { account in
            let s = state(of: account)
            let check = localChecks[account.id]
            let connected = check?.connected ?? (s.snapshot != nil || (s.lastAttempt != nil && !s.notConfigured))
            guard !account.isMain || connected || s.snapshot != nil else { return nil }
            return info(account, state: s, check: check)
        }
    }

    /// Providers with at least one account to show, in the panel's order.
    var connectedProviders: [ProviderID] { order.filter { !accounts($0).isEmpty } }

    var allAccounts: [AccountInfo] { order.flatMap { accounts($0) } }

    private func info(_ account: Account, state s: ProviderState, check: LocalCheck?) -> AccountInfo {
        let plan = s.snapshot?.plan
        var info = AccountInfo(account: account, name: displayName(account, plan: plan), email: check?.email, plan: plan, state: s,
                               limits: limitsCapability(s, connected: check?.connected))
        if features.contains(.agents) { info.agents = check?.agents ?? (check == nil ? .pending : nil) }
        if account.provider == .claude, let session = info.used("Session"), let weekly = info.used("Weekly") {
            info.takesSubagents = session < accountsConfig.sessionThreshold * 100 && weekly < accountsConfig.weeklyThreshold * 100
        }
        return info
    }

    /// Its own name, else its plan's first word for Claude ("Max"), else the plan, else "Main".
    func displayName(_ account: Account, plan: String?) -> String {
        if let name = account.name { return name }
        if account.provider == .claude, let first = plan?.split(separator: " ").first { return String(first) }
        return account.isMain ? (plan ?? "Main") : (plan ?? account.key)
    }

    private func limitsCapability(_ s: ProviderState, connected: Bool?) -> Capability {
        if connected == false && s.snapshot == nil { return .problem("Not signed in") }
        if let error = s.error { return .problem(error) }
        return s.snapshot == nil ? .pending : .ready
    }

    /// Works out every account's local check off the main thread.
    func refreshLocalChecks() {
        let accounts = accountsConfig.accounts
        Task.detached(priority: .utility) {
            var checks: [String: LocalCheck] = [:]
            for account in accounts { checks[account.id] = Self.localCheck(account) }
            await MainActor.run { if checks != self.localChecks { self.localChecks = checks } }
        }
    }

    nonisolated static func localCheck(_ account: Account) -> LocalCheck {
        let connected = account.hasCredentials
        var check = LocalCheck(connected: connected)
        switch account.provider {
        case .claude:
            check.email = ClaudeProvider.signedInAccount(configDir: account.folder).email
            check.agents = connected ? .ready : .problem("Not signed in")
        case .antigravity:
            let raw = Keychain.readOwn(service: AntigravityProvider.loginService, account: account.keychainItem(AntigravityProvider.loginAccount))
            check.email = raw.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?.string("email")
            // Agents run through `agy`, whose own login is one per Mac: the main account's.
            if account.isMain { check.agents = AntigravityBackend.executable() == nil ? .problem("Install agy") : .ready }
        case .codex:
            if account.isMain { check.agents = CodexBackend.executable() == nil ? .problem("Install the Codex CLI") : connected ? .ready : .problem("Not signed in") }
        case .zai:
            if account.isMain { check.agents = ZAIProvider.apiKey() == nil ? .problem("Add a Coding Plan key") : .ready }
        case .openrouter:
            if account.isMain { check.agents = connected ? .ready : .problem("Add an API key") }
        }
        return check
    }

    // MARK: Adding

    /// What adding an account of `provider` signs in: its main account while that has no login, else a new one.
    func connectTarget(_ provider: ProviderID) -> Account {
        let main = Account.main(provider)
        if localChecks[main.id]?.connected == false || accounts(provider).isEmpty { return main }
        return Account(provider: provider, key: accountsConfig.newKey(provider))
    }

    /// Signs in through the browser: Claude and Codex through their CLIs, Antigravity with Google.
    func connectInBrowser(_ provider: ProviderID) {
        let account = connectTarget(provider)
        run(connect: account, status: "Finish signing in in your browser.") {
            switch provider {
            case .claude:
                try await ClaudeSignIn.browserSignIn(ClaudeAccount(id: account.key))
            case .codex:
                guard let codex = CodexBackend.executable() else { throw ProviderError.message("The Codex CLI (`codex`) was not found on this Mac.") }
                var environment = ProcessInfo.processInfo.environment
                if let home = account.folder {
                    HeadroomPaths.ensure(URL(fileURLWithPath: home))
                    environment["CODEX_HOME"] = home
                }
                try await CLILogin.run(codex, ["login"], environment: environment)
                guard CodexProvider.hasCredentials(home: account.folder) else { throw ProviderError.message("The sign-in didn't finish. Try again.") }
            case .antigravity:
                let (refreshToken, email) = try await GoogleOAuth.signIn()
                var login: [String: Any] = ["refresh_token": refreshToken]
                login["email"] = email
                let data = try JSONSerialization.data(withJSONObject: login)
                guard Keychain.writeOwn(service: AntigravityProvider.loginService, account: account.keychainItem(AntigravityProvider.loginAccount),
                                        value: String(decoding: data, as: UTF8.self)) else {
                    throw ProviderError.message("Couldn't save the sign-in to the keychain.")
                }
            case .zai, .openrouter:
                throw ProviderError.message("\(provider.displayName) connects with an API key.")
            }
        }
    }

    /// Saves an API key (Z.ai, OpenRouter) once the provider accepts it.
    func connect(_ provider: ProviderID, key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let account = connectTarget(provider)
        let item = account.keychainItem(provider == .zai ? ZAIProvider.keyAccount : OpenRouterProvider.keyAccount)
        let service = provider == .zai ? ZAIProvider.service : OpenRouterProvider.keyService
        run(connect: account, status: "Checking the key…") {
            let previous = Keychain.readOwn(service: service, account: item)
            guard Keychain.writeOwn(service: service, account: item, value: key) else { throw ProviderError.message("Couldn't save the key to the keychain.") }
            do {
                _ = try await account.usageProvider.fetch()
            } catch {
                // Put back what was there, so a typo doesn't sign the account out.
                if let previous { _ = Keychain.writeOwn(service: service, account: item, value: previous) } else { Keychain.delete(service: service, account: item) }
                throw ProviderError.message("\(provider.displayName) didn't accept the key: \(error.localizedDescription)")
            }
        }
    }

    /// The z.ai website sign-in, for the main account: it reads limits only.
    func connectZAIWebsite() {
        connectStatus = .idle
        ZAISignInWindow.present { [weak self] success in
            guard let self, success else { return }
            self.finishConnect(.main(.zai))
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connectStatus = .idle
    }

    private func run(connect account: Account, status: String, _ body: @escaping @MainActor () async throws -> Void) {
        connectTask?.cancel()
        connectStatus = .working(status)
        connectTask = Task {
            do {
                try await body()
                finishConnect(account)
            } catch is CancellationError {
                connectStatus = .idle
            } catch {
                if !Task.isCancelled { connectStatus = .failed(error.localizedDescription) }
            }
            NSApp.activate()
        }
    }

    /// Adds a new account to its pool once signed in, named after its plan, and reads its usage.
    private func finishConnect(_ account: Account) {
        if !account.isMain, accountsConfig.account(account.id) == nil {
            updateAccounts { $0.append(account) }
        }
        connectStatus = .idle
        lastConnected = account.id
        forgetUsage(account)
        refreshLocalChecks()
        Task {
            await refresh([account])
            // Two accounts on one plan would read the same: number the newer one.
            guard !account.isMain, accountsConfig.account(account.id)?.name == nil, let plan = state(of: account).snapshot?.plan else { return }
            let base = account.provider == .claude ? String(plan.split(separator: " ").first ?? "") : plan
            let taken = Set(accounts(account.provider).filter { $0.id != account.id }.map(\.name))
            let name = ([base] + (2...9).map { "\(base) \($0)" }).first { !taken.contains($0) } ?? base
            updateAccounts { $0.rename(account.id, to: name) }
        }
    }

    // MARK: Changing

    func rename(_ id: String, to name: String) { updateAccounts { $0.rename(id, to: name) } }

    func moveAccount(_ id: String, by offset: Int) { updateAccounts { $0.move(id, by: offset) } }

    /// A main account of a CLI login (Claude, Codex) stays: signing out is the CLI's business.
    func canRemove(_ account: Account) -> Bool { !account.isMain || ![.claude, .codex].contains(account.provider) }

    /// Forgets an account and the keys Headroom kept for it. An added account's CLI folder stays on disk.
    /// A main account only loses Headroom's own sign-in.
    func remove(_ account: Account) {
        for (service, item) in [(AntigravityProvider.loginService, AntigravityProvider.loginAccount),
                                (ZAIProvider.service, ZAIProvider.sessionAccount), (ZAIProvider.service, ZAIProvider.keyAccount),
                                (OpenRouterProvider.keyService, OpenRouterProvider.keyAccount)] {
            Keychain.delete(service: service, account: account.keychainItem(item))
        }
        if !account.isMain { updateAccounts { $0.remove(account.id) } }
        forgetUsage(account)
        refreshLocalChecks()
        if account.isMain { Task { await refresh([account]) } }
    }

    /// Opens Terminal on `claude` for the account, when the browser sign-in can't be used.
    func signInInTerminal(_ account: Account) {
        do {
            try ClaudeSignIn.openTerminalSignIn(ClaudeAccount(id: account.key), name: displayName(account, plan: state(of: account).snapshot?.plan))
        } catch {
            connectStatus = .failed("Couldn't open Terminal: \(error.localizedDescription)")
        }
    }

    func setThresholds(session: Double? = nil, weekly: Double? = nil) {
        updateAccounts { config in
            if let session { config.sessionThreshold = session }
            if let weekly { config.weeklyThreshold = weekly }
        }
    }

    /// Changes the saved account list, which agent runners read too.
    func updateAccounts(_ change: (inout AccountsConfig) -> Void) {
        var config = AccountsConfig.load()
        change(&config)
        do {
            try config.save()
            accountsConfig = config
        } catch {
            connectStatus = .failed("Couldn't save the account list: \(error.localizedDescription)")
        }
    }
}
