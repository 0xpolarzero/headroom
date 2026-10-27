import Foundation

/// OpenRouter credit balance, plus spend per API key. Listing every key needs a management key;
/// a regular key only reports itself.
struct OpenRouterProvider: UsageProvider {
    var id: ProviderID { .openrouter }

    static let keyService = "Headroom", keyAccount = "openrouter-api-key"
    private static let base = "https://openrouter.ai/api/v1"

    func fetch() async throws -> UsageSnapshot {
        guard let key = Self.apiKey() else { throw ProviderError.notConfigured("Add your OpenRouter API key in Settings.") }
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        func get(_ path: String) async throws -> (Int, [String: Any]) {
            let (object, http) = try await HTTP.json(HTTP.request(Self.base + path, headers: headers))
            return (http.statusCode, object as? [String: Any] ?? [:])
        }

        // Regular inference keys report themselves; /credits and /keys require management access.
        let (status, body) = try await get("/key")
        var keys: [KeyUsage] = []
        var windows: [UsageWindow] = []
        var menuText: String?
        if (200..<300).contains(status), !Self.isManagementKey(body), let one = Self.key(from: body.dict("data") ?? [:]) {
            keys = [one]
            if let remaining = one.limitRemaining {
                menuText = Format.dollars(max(remaining, 0))
                windows.append(UsageWindow(label: "Credits", usedPercent: one.limit.flatMap { $0 > 0 ? min(max(($0 - remaining) / $0 * 100, 0), 100) : nil },
                                           detail: "\(Format.dollars(max(remaining, 0))) left on this key"))
            }
        } else if Self.isManagementKey(body) || status == 401 || status == 403 {
            // A management key can show account balance and all keys, but cannot run an agent.
            let (creditStatus, credits) = try await get("/credits")
            if creditStatus == 401 { throw ProviderError.unauthorized("OpenRouter API key invalid. Check it in Settings.") }
            guard (200..<300).contains(creditStatus) else { throw ProviderError.http(creditStatus) }
            if let balance = Self.balance(from: credits) {
                windows.append(Self.creditsWindow(balance))
                menuText = Format.dollars(max(balance.total - balance.used, 0))
            }
            if let (s, list) = try? await get("/keys"), (200..<300).contains(s) { keys = Self.keys(fromList: list) }
        } else if !(200..<300).contains(status) {
            throw ProviderError.http(status)
        } else {
            throw ProviderError.invalidResponse
        }
        return UsageSnapshot(title: "OpenRouter", plan: nil, windows: windows, keys: keys, menuBarText: menuText)
    }

    // MARK: Mapping (pure)

    static func balance(from root: [String: Any]) -> (total: Double, used: Double)? {
        let data = root.dict("data") ?? root
        guard let used = data.double("total_usage") else { return nil }
        return (max(data.double("total_credits") ?? 0, 0), max(used, 0))
    }

    static func creditsWindow(_ balance: (total: Double, used: Double)) -> UsageWindow {
        let left = max(balance.total - balance.used, 0)
        return UsageWindow(label: "Credits",
                           usedPercent: balance.total > 0 ? min(balance.used / balance.total * 100, 100) : 100,
                           detail: "\(Format.dollars(left)) of \(Format.dollars(balance.total)) left")
    }

    static func keys(fromList root: [String: Any]) -> [KeyUsage] {
        (root.array("data") ?? []).compactMap(key(from:)).sorted { $0.total > $1.total }
    }

    static func key(from d: [String: Any]) -> KeyUsage? {
        guard let usage = d.double("usage") else { return nil }
        let name = [d.string("name"), d.string("label")].compactMap { $0 }.first { !$0.isEmpty } ?? "Key"
        return KeyUsage(name: name, total: usage, today: d.double("usage_daily"), month: d.double("usage_monthly"),
                        limit: d.double("limit"), limitRemaining: d.double("limit_remaining"),
                        disabled: d["disabled"] as? Bool ?? false)
    }

    /// A management key is for provisioning, not model calls. Check the regular-key identity first.
    /// https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key
    static func validateInferenceKey(_ key: String) async throws {
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        let (body, http) = try await HTTP.json(HTTP.request(base + "/key", headers: headers))
        let root = body as? [String: Any] ?? [:]
        if (200..<300).contains(http.statusCode) {
            try checkInferenceKey(root)
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            let (_, credits) = try await HTTP.json(HTTP.request(base + "/credits", headers: headers))
            if (200..<300).contains(credits.statusCode) { throw ProviderError.message(EndpointProfile.missingKey(.openrouter)) }
            throw ProviderError.unauthorized("OpenRouter authentication failed. Check the regular API key in Headroom's Settings.")
        }
        throw ProviderError.http(http.statusCode)
    }

    static func checkInferenceKey(_ root: [String: Any]) throws {
        guard root.dict("data") != nil else { throw ProviderError.invalidResponse }
        if isManagementKey(root) { throw ProviderError.message(EndpointProfile.missingKey(.openrouter)) }
    }

    static func isManagementKey(_ root: [String: Any]) -> Bool {
        let data = root.dict("data") ?? root
        return data["is_management_key"] as? Bool == true || data["is_provisioning_key"] as? Bool == true
    }

    static func apiKey() -> String? {
        if let k = Keychain.readOwn(service: keyService, account: keyAccount), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !k.isEmpty { return k }
        return nil
    }
}
