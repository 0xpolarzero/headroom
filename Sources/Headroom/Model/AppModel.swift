import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// The latest state of one provider section.
struct ProviderState: Sendable {
    var snapshot: UsageSnapshot?
    var error: String?
    var isLoading = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// The provider has no login or key at all; its menu bar item is hidden.
    var notConfigured = false
    /// The last failure was a 429, so retrying sooner would only extend it.
    var rateLimited = false

    var retryDelay: TimeInterval {
        error == nil || rateLimited ? AppModel.refreshInterval : AppModel.retryInterval
    }

    func isStale(now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > AppModel.staleAfter
    }
}

/// Which window the menu bar items show.
enum MenuBarMode: String, CaseIterable, Identifiable {
    case session, weekly, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .both: "Both"
        }
    }
}

@MainActor @Observable
final class AppModel {
    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    nonisolated static let retryInterval: TimeInterval = 60
    nonisolated static let staleAfter: TimeInterval = 10 * 60
    /// Opening the panel refreshes providers whose data is older than this.
    static let openThrottle: TimeInterval = 30
    static let alertWindows: Set<String> = ["Session", "Weekly"]
    /// Notifications and login items need a real app bundle, not `swift run`.
    static let isBundled = Bundle.main.bundleIdentifier != nil

    /// Each account's latest usage, by `Account.id`.
    private(set) var states: [String: ProviderState] = [:]
    /// What Headroom does; see `Feature`.
    private(set) var features: Set<Feature> {
        didSet { defaults.set(features.map(\.rawValue).sorted(), forKey: "features") }
    }
    var showingSettings = false
    var settingsTab = SettingsTab.general
    var order: [ProviderID] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "providerOrder") }
    }
    /// Stored as the disabled set so providers added later start enabled.
    private(set) var disabled: Set<ProviderID> {
        didSet { defaults.set(disabled.map(\.rawValue), forKey: "disabledProviders") }
    }
    var notificationsOn: Bool {
        didSet {
            defaults.set(notificationsOn, forKey: "notificationsOn")
            if notificationsOn { requestNotificationPermission() }
        }
    }
    var menuBarMode: MenuBarMode {
        didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginError: String?
    // Accounts
    private(set) var antigravityEmail: String?
    private(set) var antigravitySignedIn = false
    private(set) var antigravitySigningIn = false
    private(set) var accountError: String?
    private(set) var zaiSignedIn = false
    private(set) var hasOpenRouterKey = false
    private(set) var hasZAIKey = false
    private var signInTask: Task<Void, Never>?
    /// Every provider's accounts, as saved; reloaded on each tick, since agent runners read it too.
    var accountsConfig = AccountsConfig.load()
    // Claude accounts (AppModel+Claude.swift)
    var claudeConfig: ClaudeAccountsConfig { ClaudeAccountsConfig(accountsConfig) }
    /// Headroom's Claude Code plugin is installed and enabled (`~/.claude/settings.json`).
    var subagentsInstalled = false
    var claudeError: String?
    /// When Headroom last started Claude Code to renew an account's expired sign-in.
    @ObservationIgnored var renewedAt: [String: Date] = [:]
    /// The plugin is being installed or removed; until it's done, its state says nothing about the feature.
    @ObservationIgnored private var changingPlugin = false

    /// Windows already announced as full; an entry clears once usage drops below 100%.
    private var alerted: Set<String> {
        didSet { defaults.set(Array(alerted), forKey: "alertedLimits") }
    }
    let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?

    init() {
        let saved = (defaults.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init)
        order = saved + ProviderID.allCases.filter { !saved.contains($0) }
        disabled = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(ProviderID.init))
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .session
        notificationsOn = defaults.object(forKey: "notificationsOn") as? Bool ?? true
        alerted = Set(defaults.stringArray(forKey: "alertedLimits") ?? [])
        if let saved = defaults.stringArray(forKey: "features") {
            features = Set(saved.compactMap(Feature.init))
        } else {
            features = Feature.initial(pluginInstalled: SubagentInstaller.isInstalled())
            defaults.set(features.map(\.rawValue).sorted(), forKey: "features")
        }
        loadAccounts()
        if Self.isBundled { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Derived

    var enabledProviders: [ProviderID] { order.filter { !disabled.contains($0) } }

    /// The provider's main account's usage.
    func state(_ id: ProviderID) -> ProviderState { state(of: .main(id)) }

    func state(of account: Account) -> ProviderState { states[account.id] ?? ProviderState() }

    /// Every account of the enabled providers, which are the ones Headroom reads.
    var enabledAccounts: [Account] { enabledProviders.flatMap { accountsConfig.pool($0) } }

    var lastUpdated: Date? { enabledAccounts.compactMap { states[$0.id]?.lastSuccess }.max() }

    var isRefreshing: Bool { enabledAccounts.contains { states[$0.id]?.isLoading == true } }

    /// Enabled providers that get a menu bar item: all but those with nothing to show yet, and none
    /// without the limits feature, which leaves the plain gauge.
    var menuBarProviders: [ProviderID] {
        guard features.contains(.limits) else { return [] }
        return enabledProviders.filter { id in
            let s = state(id)
            return s.snapshot != nil || !s.notConfigured
        }
    }

    // MARK: Refresh

    func start() {
        guard loop == nil else { return }
        if notificationsOn { requestNotificationPermission() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                await self?.claudeTick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Every 5 minutes, or 60 s after a failure.
    private func refreshDue() async {
        let now = Date()
        await refresh(enabledAccounts.filter { account in
            let s = state(of: account)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= s.retryDelay
        })
    }

    func panelOpened() {
        let now = Date()
        let due = enabledAccounts.filter { account in
            let s = state(of: account)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (s.error == nil ? Self.openThrottle : s.retryDelay)
        }
        Task { await refresh(due) }
        Task { await claudeTick() }
    }

    func refreshAll() {
        Task { await refresh(enabledAccounts) }
    }

    /// Every account of these providers.
    func refresh(_ ids: [ProviderID]) async {
        await refresh(ids.flatMap { accountsConfig.pool($0) })
    }

    func refresh(_ accounts: [Account]) async {
        let accounts = accounts.filter { states[$0.id]?.isLoading != true }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts { group.addTask { await self.refreshOne(account) } }
        }
    }

    private func refreshOne(_ account: Account) async {
        let id = account.id
        states[id, default: ProviderState()].isLoading = true
        states[id]?.lastAttempt = .now
        do {
            let snapshot = try await fetch(account)
            states[id]?.snapshot = snapshot   // keep the last good data on failure
            states[id]?.error = nil
            states[id]?.notConfigured = false
            states[id]?.rateLimited = false
            states[id]?.lastSuccess = .now
            checkLimits(account.provider, snapshot, account: account.isMain ? nil : account.key)
        } catch {
            states[id]?.error = error.localizedDescription
            if case ProviderError.notConfigured = error { states[id]?.notConfigured = true }
            if case ProviderError.rateLimited = error { states[id]?.rateLimited = true }
        }
        states[id]?.isLoading = false
    }

    private func fetch(_ account: Account) async throws -> UsageSnapshot {
        do {
            return try await account.usageProvider.fetch()
        } catch ProviderError.unauthorized where account.provider == .claude && !account.isMain
                    && Date().timeIntervalSince(renewedAt[account.key] ?? .distantPast) > 600 {
            // Unused for a while: Claude Code renews the sign-in when started.
            renewedAt[account.key] = Date()
            guard let renewed = await ClaudeSignIn.renew(ClaudeAccount(id: account.key)) else {
                throw ProviderError.unauthorized("Claude Code sign-in expired. Run `claude` to refresh it.")
            }
            return renewed
        }
    }

    // MARK: Settings

    /// Turning agents on installs Headroom's Claude Code plugin; turning them off removes it.
    func setFeature(_ feature: Feature, _ on: Bool) {
        if on { features.insert(feature) } else { features.remove(feature) }
        guard feature == .agents else { return }
        claudeError = nil
        changingPlugin = true
        Task {
            do {
                try await on ? SubagentInstaller.install() : SubagentInstaller.uninstall()
            } catch {
                claudeError = error.localizedDescription
            }
            changingPlugin = false
            syncPlugin()
        }
    }

    /// The plugin is what makes agents work, so the feature follows it, also when it was changed in Claude Code.
    func syncPlugin() {
        guard !changingPlugin else { return }
        let installed = SubagentInstaller.isInstalled()
        if installed != subagentsInstalled { subagentsInstalled = installed }
        if installed != features.contains(.agents) {
            if installed { features.insert(.agents) } else { features.remove(.agents) }
        }
    }

    func isEnabled(_ id: ProviderID) -> Bool { !disabled.contains(id) }

    func setEnabled(_ id: ProviderID, _ on: Bool) {
        if on {
            disabled.remove(id)
            Task { await refresh([id]) }
        } else {
            disabled.insert(id)
        }
    }

    func move(_ id: ProviderID, by offset: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
    }

    // MARK: Accounts

    private func loadAccounts() {
        let login = Keychain.readOwn(service: AntigravityProvider.loginService, account: AntigravityProvider.loginAccount)
        antigravitySignedIn = login != nil
        antigravityEmail = login.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?.string("email")
        zaiSignedIn = Keychain.readOwn(service: ZAIProvider.service, account: ZAIProvider.sessionAccount) != nil
            || Keychain.readOwn(service: ZAIProvider.service, account: ZAIProvider.keyAccount) != nil
        hasZAIKey = Keychain.readOwn(service: ZAIProvider.service, account: ZAIProvider.keyAccount) != nil
        hasOpenRouterKey = Keychain.readOwn(service: OpenRouterProvider.keyService, account: OpenRouterProvider.keyAccount) != nil
    }

    func signInAntigravity() {
        guard !antigravitySigningIn else { return }
        antigravitySigningIn = true
        accountError = nil
        signInTask = Task {
            do {
                let (refreshToken, email) = try await GoogleOAuth.signIn()
                var login: [String: Any] = ["refresh_token": refreshToken]
                login["email"] = email
                let data = try JSONSerialization.data(withJSONObject: login)
                guard Keychain.writeOwn(service: AntigravityProvider.loginService, account: AntigravityProvider.loginAccount,
                                        value: String(decoding: data, as: UTF8.self)) else {
                    throw ProviderError.message("Could not save the login to the Keychain.")
                }
                loadAccounts()
                await refresh([.antigravity])
            } catch is CancellationError {
            } catch {
                accountError = error.localizedDescription
            }
            antigravitySigningIn = false
            NSApp.activate()
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func signOutAntigravity() {
        Keychain.delete(service: AntigravityProvider.loginService, account: AntigravityProvider.loginAccount)
        loadAccounts()
        reset(.antigravity)
    }

    func signInZAI() {
        accountError = nil
        ZAISignInWindow.present { [weak self] success in
            guard let self else { return }
            self.loadAccounts()
            if success { self.reset(.zai) }
        }
    }

    func signOutZAI() {
        Keychain.delete(service: ZAIProvider.service, account: ZAIProvider.sessionAccount)
        Keychain.delete(service: ZAIProvider.service, account: ZAIProvider.keyAccount)
        loadAccounts()
        reset(.zai)
    }

    func saveZAIKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard Keychain.writeOwn(service: ZAIProvider.service, account: ZAIProvider.keyAccount, value: key) else {
            accountError = "Could not save the Coding Plan API key to the Keychain."
            return
        }
        accountError = nil
        loadAccounts()
        reset(.zai)
    }

    func removeZAIKey() {
        Keychain.delete(service: ZAIProvider.service, account: ZAIProvider.keyAccount)
        loadAccounts()
        reset(.zai)
    }

    func saveOpenRouterKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              Keychain.writeOwn(service: OpenRouterProvider.keyService, account: OpenRouterProvider.keyAccount, value: key) else { return }
        loadAccounts()
        reset(.openrouter)
    }

    func removeOpenRouterKey() {
        Keychain.delete(service: OpenRouterProvider.keyService, account: OpenRouterProvider.keyAccount)
        loadAccounts()
        reset(.openrouter)
    }

    /// Drops what a removed account showed.
    func forgetUsage(_ account: Account) { states[account.id] = nil }

    /// Drops what a provider's main account showed and fetches it again with the new credentials.
    private func reset(_ id: ProviderID) {
        states[Account.main(id).id] = nil
        Task { await refresh([Account.main(id)]) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard Self.isBundled else { return }
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Notifications

    func checkLimits(_ id: ProviderID, _ snapshot: UsageSnapshot, account: String? = nil) {
        for window in snapshot.windows where Self.alertWindows.contains(window.label) {
            guard let used = window.usedPercent else { continue }
            let key = "\(id.rawValue)\(account.map { ".\($0)" } ?? "").\(window.label)"
            if used < 100 {
                alerted.remove(key)
            } else if !alerted.contains(key) {
                alerted.insert(key)
                if notificationsOn { notify(id, window, account: account) }
            }
        }
    }

    private func notify(_ id: ProviderID, _ window: UsageWindow, account: String? = nil) {
        var text = "\(id.displayName)\(account.map { " (\($0))" } ?? "") \(window.label) limit reached"
        if let reset = window.resetsAt { text += " — resets at \(Format.clock(reset))" }
        post(text, id: "\(id.rawValue).\(account ?? "").\(window.label)")
    }

    func post(_ text: String, id: String) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func requestNotificationPermission() {
        guard Self.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationPresenter.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

/// Shows banners even while the panel is open and the app is active.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
