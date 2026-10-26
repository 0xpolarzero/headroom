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

    func isStale(now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > AppModel.staleAfter
    }
}

@MainActor @Observable
final class AppModel {
    static let refreshInterval: TimeInterval = 5 * 60
    static let retryInterval: TimeInterval = 60
    nonisolated static let staleAfter: TimeInterval = 10 * 60
    /// Opening the panel refreshes providers whose data is older than this.
    static let openThrottle: TimeInterval = 30
    static let alertWindows: Set<String> = ["Session", "Weekly"]
    static let zaiService = "Headroom", zaiAccount = "zai-api-key"
    /// Notifications and login items need a real app bundle, not `swift run`.
    static let isBundled = Bundle.main.bundleIdentifier != nil

    private(set) var states: [ProviderID: ProviderState] = [:]
    var showingSettings = false
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
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginError: String?
    private(set) var hasZAIKey = false

    /// Windows already announced as full; an entry clears once usage drops below 100%.
    private var alerted: Set<String> {
        didSet { defaults.set(Array(alerted), forKey: "alertedLimits") }
    }
    private let defaults = UserDefaults.standard
    private let providers: [ProviderID: any UsageProvider] = [
        .codex: CodexProvider(), .antigravity: AntigravityProvider(), .zai: ZAIProvider(),
    ]
    private var loop: Task<Void, Never>?

    init() {
        let saved = (defaults.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init)
        order = saved + ProviderID.allCases.filter { !saved.contains($0) }
        disabled = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(ProviderID.init))
        notificationsOn = defaults.object(forKey: "notificationsOn") as? Bool ?? true
        alerted = Set(defaults.stringArray(forKey: "alertedLimits") ?? [])
        hasZAIKey = Keychain.readOwn(service: Self.zaiService, account: Self.zaiAccount) != nil
        if Self.isBundled { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Derived

    var enabledProviders: [ProviderID] { order.filter { !disabled.contains($0) } }

    func state(_ id: ProviderID) -> ProviderState { states[id] ?? ProviderState() }

    var lastUpdated: Date? { enabledProviders.compactMap { states[$0]?.lastSuccess }.max() }

    var isRefreshing: Bool { enabledProviders.contains { states[$0]?.isLoading == true } }

    /// The most-used Session window across enabled providers, for the menu bar.
    var menuBarPercent: Double? {
        enabledProviders.compactMap { id in
            states[id]?.snapshot?.windows.first { $0.label == "Session" }?.usedPercent
        }.max()
    }

    // MARK: Refresh

    func start() {
        guard loop == nil else { return }
        if notificationsOn { requestNotificationPermission() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Every 5 minutes, or 60 s after a failure.
    private func refreshDue() async {
        let now = Date()
        await refresh(enabledProviders.filter { id in
            let s = state(id)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (s.error == nil ? Self.refreshInterval : Self.retryInterval)
        })
    }

    func panelOpened() {
        let now = Date()
        let ids = enabledProviders.filter { id in
            let s = state(id)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (s.error == nil ? Self.openThrottle : Self.retryInterval)
        }
        Task { await refresh(ids) }
    }

    func refreshAll() {
        Task { await refresh(enabledProviders) }
    }

    private func refresh(_ ids: [ProviderID]) async {
        let ids = ids.filter { states[$0]?.isLoading != true }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refreshOne(id) } }
        }
    }

    private func refreshOne(_ id: ProviderID) async {
        guard let provider = providers[id] else { return }
        states[id, default: ProviderState()].isLoading = true
        states[id]?.lastAttempt = .now
        do {
            let snapshot = try await provider.fetch()
            states[id]?.snapshot = snapshot   // keep the last good data on failure
            states[id]?.error = nil
            states[id]?.lastSuccess = .now
            checkLimits(id, snapshot)
        } catch {
            states[id]?.error = error.localizedDescription
        }
        states[id]?.isLoading = false
    }

    // MARK: Settings

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

    func saveZAIKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Keychain.writeOwn(service: Self.zaiService, account: Self.zaiAccount, value: key) else { return }
        hasZAIKey = true
        Task { await refresh([.zai]) }
    }

    func removeZAIKey() {
        Keychain.delete(service: Self.zaiService, account: Self.zaiAccount)
        hasZAIKey = false
        states[.zai] = nil
        Task { await refresh([.zai]) }
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

    private func checkLimits(_ id: ProviderID, _ snapshot: UsageSnapshot) {
        for window in snapshot.windows where Self.alertWindows.contains(window.label) {
            guard let used = window.usedPercent else { continue }
            let key = "\(id.rawValue).\(window.label)"
            if used < 100 {
                alerted.remove(key)
            } else if !alerted.contains(key) {
                alerted.insert(key)
                if notificationsOn { notify(id, window) }
            }
        }
    }

    private func notify(_ id: ProviderID, _ window: UsageWindow) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        var text = "\(id.displayName) \(window.label) limit reached"
        if let reset = window.resetsAt { text += " — resets at \(Format.clock(reset))" }
        content.body = text
        let request = UNNotificationRequest(identifier: "\(id.rawValue).\(window.label)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
