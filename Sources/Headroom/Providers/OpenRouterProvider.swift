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

        let (status, credits) = try await get("/credits")
        if status == 401 { throw ProviderError.unauthorized("OpenRouter API key invalid. Check it in Settings.") }
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        let balance = Self.balance(from: credits)

        // Management keys list every key; anything else falls back to the key's own record.
        var keys: [KeyUsage] = []
        if let (s, body) = try? await get("/keys"), (200..<300).contains(s) {
            keys = Self.keys(fromList: body)
        } else if let (s, body) = try? await get("/key"), (200..<300).contains(s), let one = Self.key(from: body.dict("data") ?? [:]) {
            keys = [one]
        }

        var windows: [UsageWindow] = []
        var menuText: String?
        if let balance {
            windows.append(Self.creditsWindow(balance))
            menuText = Format.dollars(balance.total - balance.used)
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

    private static func apiKey() -> String? {
        if let k = Keychain.readOwn(service: keyService, account: keyAccount), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !k.isEmpty { return k }
        return nil
    }
}
