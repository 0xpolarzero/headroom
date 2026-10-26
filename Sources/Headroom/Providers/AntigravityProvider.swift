import Foundation

/// Antigravity quota via the Google Cloud Code API, using the OAuth token Antigravity keeps in the keychain.
struct AntigravityProvider: UsageProvider {
    var id: ProviderID { .antigravity }

    private static let hosts = ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
    private static let summaryPath = "/v1internal:retrieveUserQuotaSummary"
    private static let loadPath = "/v1internal:loadCodeAssist"
    private static let loadBody: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]

    // MARK: Fetch

    struct KeychainToken { var access: String?; var refresh: String?; var expiry: Date? }

    func fetch() async throws -> UsageSnapshot {
        guard let raw = Keychain.read(service: "gemini", account: "antigravity") else {
            throw ProviderError.notConfigured("Open Antigravity and sign in.")
        }
        guard let stored = Self.parseKeychain(raw) else { throw ProviderError.message("Antigravity credentials are unreadable.") }

        // Read-only: Antigravity refreshes its own login, so an expired token just means "open Antigravity".
        guard let token = stored.access, stored.expiry.map({ $0.timeIntervalSinceNow > 60 }) ?? true else {
            throw ProviderError.unauthorized("Antigravity sign-in expired. Open Antigravity to refresh it.")
        }
        switch await Self.fetchSummaries(token: token) {
        case .authFailed: throw ProviderError.unauthorized("Antigravity sign-in expired. Open Antigravity to refresh it.")
        case .unavailable: throw ProviderError.message("Antigravity quota is temporarily unavailable.")
        case .ok(let bodies):
            let plan = await Self.loadPlan(token: token)
            return UsageSnapshot(title: "Antigravity", plan: plan, windows: Self.windows(fromSummaries: bodies))
        }
    }

    // MARK: Mapping (pure)

    private static let buckets: [(id: String, label: String)] = [
        ("gemini-5h", "Session"), ("gemini-weekly", "Weekly"), ("3p-5h", "Claude"), ("3p-weekly", "Claude Weekly"),
    ]

    /// Merges one or more `retrieveUserQuotaSummary` bodies by bucket id (first usable one wins).
    static func windows(fromSummaries bodies: [[String: Any]]) -> [UsageWindow] {
        var found: [String: UsageWindow] = [:]
        for body in bodies {
            for group in groups(body) where group.string("displayName") != "Gemini 4 Argon" {
                for bucket in group.array("buckets") ?? [] {
                    guard let id = bucket.string("bucketId"), found[id] == nil,
                          let spec = buckets.first(where: { $0.id == id }),
                          let fraction = bucket.double("remainingFraction"), fraction.isFinite else { continue }
                    found[id] = UsageWindow(label: spec.label,
                                            usedPercent: min(max((1 - fraction) * 100, 0), 100),
                                            resetsAt: Dates.iso(bucket.string("resetTime")))
                }
            }
        }
        return buckets.compactMap { found[$0.id] }
    }

    private static func groups(_ body: [String: Any]) -> [[String: Any]] {
        body.dict("response")?.array("groups") ?? body.array("groups") ?? []
    }

    private static func isComplete(_ body: [String: Any]) -> Bool {
        windows(fromSummaries: [body]).count == buckets.count
    }

    /// `paidTier.id` first, then its name, then the current tier's name.
    static func plan(fromLoadCodeAssist body: [String: Any]) -> String? {
        let known = ["g1-pro-tier": "Pro", "g1-ultra-tier": "Ultra", "g1-ultra-lite-tier": "Ultra Lite"]
        if let id = body.dict("paidTier")?.string("id"), let name = known[id] { return name }
        guard let raw = (body.dict("paidTier")?.string("name") ?? body.dict("currentTier")?.string("name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("Google AI ") { return String(raw.dropFirst("Google AI ".count)) }
        for keyword in ["Ultra", "Pro", "Free"] where raw.lowercased().contains(keyword.lowercased()) { return keyword }
        return raw
    }

    // MARK: Keychain value

    /// `go-keyring-base64:` + base64(JSON `{"token": {...}}`); the prefix is optional.
    private static func parseKeychain(_ raw: String) -> KeychainToken? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let data = Data(base64Encoded: String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return token(from: json)
    }

    static func token(from object: [String: Any]) -> KeychainToken? {
        func first(_ d: [String: Any], _ keys: [String]) -> String? {
            for k in keys { if let s = d.string(k)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s } }
            return nil
        }
        let src = object.dict("token") ?? object
        let access = first(src, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let refresh = first(src, ["refresh_token", "refreshToken"])
        if access == nil && refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object.dict(key), let t = token(from: nested) { return t }
            }
            return nil
        }
        return KeychainToken(access: access, refresh: refresh, expiry: parseDate(first(src, ["expiry", "expires_at", "expiresAt"])))
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = Dates.iso(s) { return d }
        // Go emits up to nanosecond precision; trim the fraction to milliseconds.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let frac = String(s[r].prefix(4))
            return Dates.iso(s.replacingCharacters(in: r, with: frac))
        }
        return nil
    }

    // MARK: Network

    private enum Outcome { case ok([[String: Any]]), authFailed, unavailable }

    private static func post(_ host: String, _ path: String, token: String, ua: String, body: [String: Any]) async -> (Int, [String: Any])? {
        let headers = ["Accept": "application/json", "Authorization": "Bearer \(token)", "User-Agent": ua]
        guard let (obj, http) = try? await HTTP.json(HTTP.request(host + path, method: "POST", headers: headers, json: body)) else { return nil }
        return (http.statusCode, obj as? [String: Any] ?? [:])
    }

    /// Asks the production host, and the daily one too when the first lacks any shared bucket.
    private static func fetchSummaries(token: String) async -> Outcome {
        var bodies: [[String: Any]] = []
        var authFailed = false
        for (index, host) in hosts.enumerated() {
            guard let (status, body) = await post(host, summaryPath, token: token, ua: "Headroom", body: [:]) else { continue }
            if status == 401 || status == 403 { authFailed = true; continue }
            guard (200..<300).contains(status) else { continue }
            bodies.append(body)
            if index == 0, isComplete(body) { break }
        }
        if !bodies.isEmpty { return .ok(bodies) }
        return authFailed ? .authFailed : .unavailable
    }

    private static func loadPlan(token: String) async -> String? {
        for host in hosts {
            if let (status, body) = await post(host, loadPath, token: token, ua: "Headroom", body: loadBody),
               (200..<300).contains(status) {
                return plan(fromLoadCodeAssist: body)
            }
        }
        return nil
    }
}
