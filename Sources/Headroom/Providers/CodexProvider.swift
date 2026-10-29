import CryptoKit
import Foundation

/// Codex (ChatGPT subscription) limits, read with the login the Codex CLI already stored.
struct CodexProvider: UsageProvider {
    var id: ProviderID { .codex }
    /// The account's `CODEX_HOME`; nil finds the Codex CLI's own login as Codex does.
    var home: String?

    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let keychainService = "Codex Auth"
    private static let refreshURL = "https://auth.openai.com/oauth/token"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    // MARK: Credentials

    private enum Source { case file(String), keychain }

    private struct Credentials {
        var source: Source
        var json: [String: Any]
        var tokens: [String: Any] { json.dict("tokens") ?? [:] }
        var accessToken: String? { nonEmpty(tokens.string("access_token")) }
        var refreshToken: String? { nonEmpty(tokens.string("refresh_token")) }
        var accountID: String? { nonEmpty(tokens.string("account_id")) }
        var apiKey: String? { nonEmpty(json.string("OPENAI_API_KEY")) }
    }

    func fetch() async throws -> UsageSnapshot {
        guard let creds = Self.loadCredentials(home: home) else {
            throw ProviderError.notConfigured("Run `codex` to sign in.")
        }
        guard creds.accessToken != nil else {
            if creds.apiKey != nil {
                throw ProviderError.notConfigured("Codex is signed in with an API key; usage needs a ChatGPT login.")
            }
            throw ProviderError.notConfigured("Run `codex` to sign in.")
        }

        var current = creds
        if Self.isExpiring(current.accessToken), let refreshed = try? await Self.refresh(current) {
            current = refreshed
        }
        var (body, http) = try await Self.requestUsage(current)
        if http.statusCode == 401 || http.statusCode == 403, let refreshed = try await Self.refresh(current) {
            (body, http) = try await Self.requestUsage(refreshed)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized("Codex session expired. Run `codex` to sign in again.")
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }

        var snapshot = UsageSnapshot(title: "Codex", plan: Self.planName(root.string("plan_type")),
                                     windows: Self.windows(from: root))
        // The usage body carries the count; the dedicated endpoint adds each credit's expiry.
        let embedded = Self.resetCredits(from: root["rate_limit_reset_credits"])
        let token = current.accessToken ?? "", account = current.accountID
        let listed = await Self.resetCache.value(account ?? "codex") { try await Self.requestResetCredits(token: token, account: account) }
        snapshot.resets = listed ?? embedded
        return snapshot
    }

    private static let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private static let resetCache = HourlyCache<LimitResets>()

    private static func requestResetCredits(token: String, account: String?) async throws -> LimitResets? {
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "Headroom"]
        if let account { headers["ChatGPT-Account-Id"] = account }
        let (body, http) = try await HTTP.json(HTTP.request(resetCreditsURL, headers: headers))
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        return resetCredits(from: body)
    }

    /// `{"available_count": 2, "credits": [{"status": "available", "expires_at": …}]}`, from either the
    /// dedicated endpoint or the usage body's `rate_limit_reset_credits` (count only). A credit without a
    /// status counts as available; `expires_at` is ISO 8601 or epoch seconds.
    static func resetCredits(from value: Any?) -> LimitResets? {
        guard let object = value as? [String: Any], let count = object.double("available_count"), count >= 0 else { return nil }
        let expiries = (object.array("credits") ?? [])
            .filter { ($0.string("status") ?? "available") == "available" }
            .compactMap { credit -> Date? in Dates.iso(credit.string("expires_at")) ?? Dates.epoch(credit.double("expires_at")) }
        return LimitResets(count: Int(count), expiries: expiries.sorted())
    }

    private static func requestUsage(_ creds: Credentials) async throws -> (Any, HTTPURLResponse) {
        var headers = ["Authorization": "Bearer \(creds.accessToken ?? "")",
                       "Accept": "application/json", "User-Agent": "Headroom"]
        if let account = creds.accountID { headers["ChatGPT-Account-Id"] = account }
        return try await HTTP.json(HTTP.request(usageURL, headers: headers))
    }

    // MARK: Token refresh

    /// True when the access token's JWT `exp` is less than a minute away.
    static func isExpiring(_ token: String?, now: Date = .now) -> Bool {
        guard let payload = token?.split(separator: ".").dropFirst().first else { return false }
        var b64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = claims.double("exp") else { return false }
        return exp < now.timeIntervalSince1970 + 60
    }

    /// Refreshes the login the way the Codex CLI does and writes the new tokens back to `auth.json`.
    /// Only file-based logins are refreshed: the refresh token rotates, so a token we could not
    /// store would sign Codex out. Returns nil when there is nothing to refresh with.
    private static func refresh(_ creds: Credentials) async throws -> Credentials? {
        guard case .file(let path) = creds.source else { return nil }
        // Codex may have refreshed since we read the file; use its tokens instead of rotating again.
        if let latest = readJSON(path: path), let fresh = Credentials(source: creds.source, json: latest).accessToken,
           fresh != creds.accessToken, !isExpiring(fresh) {
            return Credentials(source: creds.source, json: latest)
        }
        guard let refreshToken = creds.refreshToken else { return nil }

        let body: [String: Any] = ["client_id": clientID, "grant_type": "refresh_token",
                                   "refresh_token": refreshToken, "scope": "openid profile email"]
        let (object, http) = try await HTTP.json(HTTP.request(refreshURL, method: "POST", json: body))
        guard (200..<300).contains(http.statusCode), let res = object as? [String: Any],
              let access = nonEmpty(res.string("access_token")) else {
            throw ProviderError.unauthorized("Codex session expired. Run `codex` to sign in again.")
        }

        // Merge into the file as it is now, touching only the token fields.
        var json = readJSON(path: path) ?? creds.json
        var tokens = json.dict("tokens") ?? [:]
        tokens["access_token"] = access
        if let r = nonEmpty(res.string("refresh_token")) { tokens["refresh_token"] = r }
        if let id = nonEmpty(res.string("id_token")) { tokens["id_token"] = id }
        json["tokens"] = tokens
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        json["last_refresh"] = f.string(from: .now)
        try writeJSON(json, path: path)
        return Credentials(source: creds.source, json: json)
    }

    /// Atomic write that keeps the file private (0600), like the Codex CLI.
    private static func writeJSON(_ json: [String: Any], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
        let tmp = path + ".headroom-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ProviderError.message("Could not save the refreshed Codex login.")
        }
        guard rename(tmp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw ProviderError.message("Could not save the refreshed Codex login.")
        }
    }

    // MARK: Mapping (pure)

    /// Session (18000 s) and Weekly (604800 s) windows, classified by length with slot order as fallback.
    static func windows(from root: [String: Any], now: Date = .now) -> [UsageWindow] {
        let rate = root.dict("rate_limit")
        // (window, label the slot would get when its length is unknown)
        let slots: [([String: Any]?, String)] = [(rate?.dict("primary_window"), "Session"),
                                                 (rate?.dict("secondary_window"), "Weekly")]
        func exactLabel(_ w: [String: Any]) -> String? {
            switch w.double("limit_window_seconds") {
            case 18000: "Session"
            case 604800: "Weekly"
            default: nil
            }
        }
        let present = slots.compactMap { slot -> ([String: Any], String)? in
            slot.0.map { ($0, slot.1) }
        }
        return ["Session", "Weekly"].compactMap { label in
            let match = present.first { exactLabel($0.0) == label }
                ?? present.first { exactLabel($0.0) == nil && $0.1 == label }
            guard let window = match?.0, let used = window.double("used_percent") else { return nil }
            var reset: Date?
            if let at = window.double("reset_at") {
                reset = Date(timeIntervalSince1970: at)
            } else if let after = window.double("reset_after_seconds") {
                reset = now.addingTimeInterval(after)
            }
            return UsageWindow(label: label, usedPercent: min(max(used, 0), 100), resetsAt: reset)
        }
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default:
            return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    // MARK: Credential loading

    static func hasCredentials(home: String?) -> Bool { loadCredentials(home: home) != nil }

    private static func codexHome() -> String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.codex"
    }

    private static func authPaths() -> [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty {
            paths.append((env as NSString).expandingTildeInPath + "/auth.json")
        }
        paths.append(NSHomeDirectory() + "/.config/codex/auth.json")
        paths.append(NSHomeDirectory() + "/.codex/auth.json")
        return paths
    }

    private static func loadCredentials(home given: String?) -> Credentials? {
        for path in given.map({ [$0 + "/auth.json"] }) ?? authPaths() {
            if let json = readJSON(path: path), hasAuth(json) {
                return Credentials(source: .file(path), json: json)
            }
        }
        // Keychain item: account "cli|" + first 16 hex of sha256(realpath(home)).
        let home = given ?? codexHome()
        let real = home.withCString { p -> String in
            guard let r = realpath(p, nil) else { return home }
            defer { free(r) }
            return String(cString: r)
        }
        let hash = SHA256.hash(data: Data(real.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let raw = Keychain.read(service: keychainService, account: "cli|" + hash),
           let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any], hasAuth(json) {
            return Credentials(source: .keychain, json: json)
        }
        return nil
    }

    private static func hasAuth(_ json: [String: Any]) -> Bool {
        nonEmpty(json.dict("tokens")?.string("access_token")) != nil || nonEmpty(json.string("OPENAI_API_KEY")) != nil
    }

    private static func readJSON(path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}
