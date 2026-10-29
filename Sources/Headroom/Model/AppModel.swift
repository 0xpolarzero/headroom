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
enum MenuBarMode: String, CaseIterable, Identifiable, Codable, Sendable {
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
    /// Agents in Claude Code: Headroom's plugin, subagents on other Claude accounts, and `headroom:` agents.
    /// Follows whether the plugin is installed.
    private(set) var agentsEnabled: Bool {
        didSet { defaults.set(agentsEnabled, forKey: "agentsEnabled") }
    }
    /// The panel's tab while agents are on.
    var panelTab = PanelTab.limits
    var settingsPage = SettingsPage.accounts
    var order: [ProviderID] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "providerOrder") }
    }
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginError: String?
    // Accounts (AppModel+Accounts.swift)
    var localChecks: [String: LocalCheck] = [:]
    var connectStatus = ConnectStatus.idle
    /// The account added last, which the add-account sheet shows once it's done.
    var lastConnected: String?
    @ObservationIgnored var connectTask: Task<Void, Never>?
    /// Every provider's accounts, as saved; reloaded on each tick, since agent runners read it too.
    var accountsConfig = AccountsConfig.load()
    // Claude accounts (AppModel+Claude.swift)
    var claudeConfig: ClaudeAccountsConfig { ClaudeAccountsConfig(accountsConfig) }
    /// Headroom's Claude Code plugin is installed and enabled (`~/.claude/settings.json`).
    var subagentsInstalled = false
    var claudeError: String?
    /// When Headroom last started Claude Code to renew an account's expired sign-in.
    @ObservationIgnored var renewedAt: [String: Date] = [:]
    /// Plugin installs or removals still to finish; until then, its state says nothing about the feature.
    @ObservationIgnored private var pluginChanges = 0
    @ObservationIgnored private var pluginTask: Task<Void, Never>?

    /// Windows already announced; an entry clears once usage drops below the account's level.
    private var alerted: Set<String> {
        didSet { defaults.set(Array(alerted), forKey: "alertedLimits") }
    }
    let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    /// Nothing from an earlier run, judged before this run writes anything: first-launch setup shows.
    let isFreshInstall: Bool

    init() {
        // Any saved setting (older versions saved some only when changed) or file means it ran before.
        let earlier = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "Headroom") ?? [:]
        isFreshInstall = earlier.isEmpty
            && !FileManager.default.fileExists(atPath: HeadroomPaths.accounts.path)
            && !FileManager.default.fileExists(atPath: HeadroomPaths.accountsConfig.path)
        let saved = (defaults.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init)
        order = saved + ProviderID.allCases.filter { !saved.contains($0) }
        alerted = Set(defaults.stringArray(forKey: "alertedLimits") ?? [])
        agentsEnabled = SubagentInstaller.isInstalled()
        if Self.isBundled { launchAtLogin = SMAppService.mainApp.status == .enabled }
        migrateAccountSettings()
    }

    /// Before each account had its own, the menu bar and notifications had one setting each: carry them over
    /// once, so an existing install looks as it did. A new install shows the icon alone and notifies at 100%.
    private func migrateAccountSettings() {
        guard !defaults.bool(forKey: "accountSettingsMigrated") else { return }
        let existing = !isFreshInstall
        let hidden = Set(defaults.stringArray(forKey: "disabledProviders") ?? [])
        let mode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .session
        let modes = defaults.dictionary(forKey: "menuBarModes") as? [String: String] ?? [:]
        let notify = defaults.object(forKey: "notificationsOn") as? Bool ?? true
        updateAccounts { config in
            for account in config.accounts {
                config.update(account.id) { account in
                    // The menu bar showed each provider's main account, and every Claude account.
                    let shown = existing && !hidden.contains(account.provider.rawValue) && (account.isMain || account.provider == .claude)
                    account.menuBar = shown ? MenuBarMode(rawValue: modes[account.provider.rawValue] ?? "") ?? mode : nil
                    account.notifyAt = notify ? 1 : nil
                }
            }
        }
        defaults.set(true, forKey: "accountSettingsMigrated")
    }

    // MARK: Derived

    /// Whether the panel and Settings show anything about agents.
    var showsAgents: Bool { agentsEnabled }

    /// The provider's main account's usage.
    func state(_ id: ProviderID) -> ProviderState { state(of: .main(id)) }

    func state(of account: Account) -> ProviderState { states[account.id] ?? ProviderState() }

    /// Every account Headroom reads: all of them, since agents need the limits even when the menu bar doesn't show them.
    var enabledAccounts: [Account] { order.flatMap { accountsConfig.pool($0) } }

    var lastUpdated: Date? { enabledAccounts.compactMap { states[$0.id]?.lastSuccess }.max() }

    var isRefreshing: Bool { enabledAccounts.contains { states[$0.id]?.isLoading == true } }

    /// The accounts the menu bar shows, by provider in the panel's order: those set to show something and
    /// with usage to show. Empty leaves the icon alone.
    var menuBarGroups: [MenuBarGroup] {
        connectedProviders.compactMap { provider in
            let shown = accounts(provider).filter { $0.account.menuBar != nil && $0.state.snapshot != nil }
            guard !shown.isEmpty else { return nil }
            return MenuBarGroup(provider: provider, entries: shown.map {
                MenuBarEntry(name: shown.count > 1 ? $0.name : nil, snapshot: $0.state.snapshot, mode: $0.account.menuBar ?? .session)
            })
        }
    }

    // MARK: Refresh

    func start() {
        guard loop == nil else { return }
        if accountsConfig.accounts.contains(where: { $0.notifyAt != nil }) { requestNotificationPermission() }
        refreshLocalChecks()
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
        refreshLocalChecks()
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
            checkLimits(account, snapshot)
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
    func setAgents(_ on: Bool) {
        agentsEnabled = on
        claudeError = nil
        pluginChanges += 1
        // One install or removal at a time, each toward the latest choice, so quick toggles end where they stopped.
        let previous = pluginTask
        pluginTask = Task {
            await previous?.value
            let want = agentsEnabled
            if want != SubagentInstaller.isInstalled() {
                do {
                    try await want ? SubagentInstaller.install() : SubagentInstaller.uninstall()
                } catch {
                    claudeError = error.localizedDescription
                }
            }
            pluginChanges -= 1
            syncPlugin()
        }
    }

    /// The plugin is what makes agents work, so the feature follows it, also when it was changed in Claude Code.
    func syncPlugin() {
        guard pluginChanges == 0 else { return }
        let installed = SubagentInstaller.isInstalled()
        if installed != subagentsInstalled { subagentsInstalled = installed }
        if installed != agentsEnabled { agentsEnabled = installed }
    }

    /// Something Headroom can fix itself: the plugin failed to install or update.
    var needsRepair: Bool { claudeError != nil }

    /// Installs the plugin again, from this copy of the app.
    func repair() {
        claudeError = nil
        pluginChanges += 1
        let previous = pluginTask
        pluginTask = Task {
            await previous?.value
            do {
                try await SubagentInstaller.install()
                agentsEnabled = true
            } catch {
                claudeError = error.localizedDescription
            }
            pluginChanges -= 1
            syncPlugin()
        }
    }

    func setMenuBar(_ id: String, _ mode: MenuBarMode?) { updateAccounts { $0.update(id) { $0.menuBar = mode } } }

    func setNotify(_ id: String, _ level: Double?) {
        updateAccounts { $0.update(id) { $0.notifyAt = level } }
        if level != nil { requestNotificationPermission() }
    }

    func move(_ id: ProviderID, by offset: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
    }

    /// Drops what a removed account showed.
    func forgetUsage(_ account: Account) { states[account.id] = nil }

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

    /// One notification each time a Session or Weekly limit crosses the account's level.
    func checkLimits(_ account: Account, _ snapshot: UsageSnapshot) {
        let saved = accountsConfig.account(account.id) ?? account
        for window in snapshot.windows where Self.alertWindows.contains(window.label) {
            guard let used = window.usedPercent else { continue }
            let key = "\(account.provider.rawValue)\(account.isMain ? "" : ".\(account.key)").\(window.label)"
            guard let level = saved.notifyAt, used >= level * 100 else { alerted.remove(key); continue }
            if alerted.insert(key).inserted {
                let name = displayName(saved, plan: snapshot.plan)
                notify(Self.alertText(provider: account.provider, name: account.isMain ? nil : name, window: window, used: used), id: key)
            }
        }
    }

    /// "Codex Session limit reached, resets at 14:00", or "Claude (Pro) Weekly: 10% left, resets …".
    static func alertText(provider: ProviderID, name: String?, window: UsageWindow, used: Double) -> String {
        var text = "\(provider.displayName)\(name.map { " (\($0))" } ?? "") \(window.label)"
        text += used >= 100 ? " limit reached" : ": \(Int((100 - used).rounded()))% left"
        if let reset = window.resetsAt { text += ", resets at \(Format.clock(reset))" }
        return text
    }

    private func notify(_ text: String, id: String) { post(text, id: id) }

    func post(_ text: String, id: String) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func requestNotificationPermission() {
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

/// One provider in the menu bar: its logo, then each shown account's numbers.
struct MenuBarGroup {
    var provider: ProviderID
    var entries: [MenuBarEntry]
}

struct MenuBarEntry {
    /// Set when the provider shows several accounts, to tell them apart.
    var name: String?
    var snapshot: UsageSnapshot?
    var mode: MenuBarMode
}
