import CryptoKit
import Foundation

/// Claude (Pro/Max subscription) limits, read with the OAuth login Claude Code keeps in the keychain.
struct ClaudeProvider: UsageProvider {
    var id: ProviderID { .claude }
    /// The Claude Code config folder whose sign-in to read (`CLAUDE_CONFIG_DIR`); nil for the default.
    var configDir: String?

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    struct Credentials { var accessToken: String; var expiresAt: Date?; var plan: String? }

    func fetch() async throws -> UsageSnapshot {
        guard let raw = Self.storedCredentials(configDir: configDir) else {
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
        return UsageSnapshot(title: "Claude", plan: creds.plan,
                             windows: try await Self.usageWindows(accessToken: creds.accessToken, expired: expired))
    }

    /// Usage of the account `accessToken` belongs to.
    static func usageWindows(accessToken: String, expired: String) async throws -> [UsageWindow] {
        let headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json",
                       "anthropic-beta": "oauth-2025-04-20", "User-Agent": "Headroom"]
        let (body, http) = try await HTTP.json(HTTP.request(usageURL, headers: headers))
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized(expired) }
        if http.statusCode == 429 { throw ProviderError.rateLimited("Claude usage is rate limited. Retrying in 5 minutes.") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }
        return windows(from: root)
    }

    // MARK: Mapping (pure)

    /// Session and Weekly, then one weekly row per model-scoped limit ("Fable Weekly").
    /// Anthropic moved per-model windows from `seven_day_<model>` into the `limits` array;
    /// the legacy keys are still read when present. `utilization` and `percent` are 0-100.
    static func windows(from root: [String: Any]) -> [UsageWindow] {
        func window(_ label: String, _ used: Double?, _ reset: String?) -> UsageWindow? {
            guard let used else { return nil }
            return UsageWindow(label: label, usedPercent: min(max(used, 0), 100), resetsAt: Dates.iso(reset))
        }
        var windows = [("five_hour", "Session"), ("seven_day", "Weekly")].compactMap { key, label in
            window(label, root.dict(key)?.double("utilization"), root.dict(key)?.string("resets_at"))
        }
        for limit in root.array("limits") ?? [] where limit.string("kind") == "weekly_scoped" {
            guard let name = limit.dict("scope")?.dict("model")?.string("display_name"), !name.isEmpty,
                  let w = window("\(name) Weekly", limit.double("percent"), limit.string("resets_at")),
                  !windows.contains(where: { $0.label == w.label }) else { continue }
            windows.append(w)
        }
        for (key, label) in [("seven_day_sonnet", "Sonnet Weekly"), ("seven_day_opus", "Opus Weekly")]
        where !windows.contains(where: { $0.label == label }) {
            if let w = window(label, root.dict(key)?.double("utilization"), root.dict(key)?.string("resets_at")) {
                windows.append(w)
            }
        }
        return windows
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

    private static func storedCredentials(configDir: String?) -> String? {
        if let raw = Keychain.read(service: keychainService(configDir: configDir)) { return raw }
        let dir = configDir ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
        guard let data = FileManager.default.contents(atPath: dir + "/.credentials.json") else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Claude Code's keychain item for a config folder: `Claude Code-credentials`, plus the first 8 hex
    /// digits of the SHA-256 of the folder path when `CLAUDE_CONFIG_DIR` is set (Claude Code 2.1.310).
    static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// The account a Claude Code config folder is signed in to: `oauthAccount` in its `.claude.json`
    /// (`~/.claude.json` for the default folder).
    static func signedInAccount(configDir: String?) -> (uuid: String?, email: String?) {
        let path = configDir.map { $0 + "/.claude.json" } ?? NSHomeDirectory() + "/.claude.json"
        let account = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.dict("oauthAccount")
        return (account?.string("accountUuid"), account?.string("emailAddress"))
    }
}
