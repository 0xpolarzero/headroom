import Foundation

/// Claude (Pro/Max subscription) limits, read with the OAuth login Claude Code keeps in the keychain.
struct ClaudeProvider: UsageProvider {
    var id: ProviderID { .claude }

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    struct Credentials { var accessToken: String; var expiresAt: Date?; var plan: String? }

    func fetch() async throws -> UsageSnapshot {
        guard let raw = Self.storedCredentials() else {
            throw ProviderError.notConfigured("Run `claude` to sign in.")
        }
        guard let creds = Self.credentials(from: raw) else {
            throw ProviderError.notConfigured("Claude Code is not signed in with a Claude subscription.")
        }

        // Read-only: Claude Code refreshes its own login, so an expired token just means "run claude".
        let expired = "Claude Code sign-in expired. Run `claude` to refresh it."
        if let expiry = creds.expiresAt, expiry.timeIntervalSinceNow < 60 {
            throw ProviderError.unauthorized(expired)
        }
        let headers = ["Authorization": "Bearer \(creds.accessToken)", "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "Headroom"]
        let (body, http) = try await HTTP.json(HTTP.request(Self.usageURL, headers: headers))
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized(expired) }
        if http.statusCode == 429 { throw ProviderError.message("Claude usage is rate limited. Retrying soon.") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }

        return UsageSnapshot(title: "Claude", plan: creds.plan, windows: Self.windows(from: root))
    }

    // MARK: Mapping (pure)

    private static let slots: [(key: String, label: String)] = [
        ("five_hour", "Session"), ("seven_day", "Weekly"),
        ("seven_day_sonnet", "Sonnet Weekly"), ("seven_day_opus", "Opus Weekly"),
    ]

    /// `utilization` is already a 0-100 percentage; model-specific windows are null when unused.
    static func windows(from root: [String: Any]) -> [UsageWindow] {
        slots.compactMap { slot in
            guard let window = root.dict(slot.key), let used = window.double("utilization") else { return nil }
            return UsageWindow(label: slot.label, usedPercent: min(max(used, 0), 100),
                               resetsAt: Dates.iso(window.string("resets_at")))
        }
    }

    /// Parses Claude Code's `{"claudeAiOauth": {...}}` credentials blob.
    static func credentials(from raw: String) -> Credentials? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let oauth = json.dict("claudeAiOauth"),
              let token = oauth.string("accessToken")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return Credentials(accessToken: token, expiresAt: Dates.epoch(oauth.double("expiresAt")),
                           plan: planName(type: oauth.string("subscriptionType"), tier: oauth.string("rateLimitTier")))
    }

    /// "max" + "default_claude_max_20x" → "Max 20x"; "pro" → "Pro".
    static func planName(type: String?, tier: String?) -> String? {
        guard let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
        let name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier, let r = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            return "\(name) \(tier[r])"
        }
        return name
    }

    // MARK: Credential loading

    private static func storedCredentials() -> String? {
        if let raw = Keychain.read(service: "Claude Code-credentials") { return raw }
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
        guard let data = FileManager.default.contents(atPath: dir + "/.credentials.json") else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
