import Foundation

/// What the relay knows about one account's limits, from the responses it forwarded.
struct AccountLimitState: Codable, Equatable, Sendable {
    var status: String?
    var fiveHour: Double?          // 0...1
    var sevenDay: Double?
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    /// The account ran out until then (or, with `overage`, is being billed extra usage until then).
    var limitedUntil: Date?
    var limitedClaim: String?
    var overage = false
    /// Model-family limits (`seven_day_opus` → "opus") that ran out, with their resets.
    var scoped: [String: Date] = [:]
    var lastUsed: Date?
    var signInNeeded = false
    var lastError: String?

    mutating func apply(_ reading: RateLimitReading, now: Date) {
        if reading.status != nil { status = reading.status }
        if let v = reading.fiveHour { fiveHour = v }
        if let v = reading.sevenDay { sevenDay = v }
        if let v = reading.fiveHourReset { fiveHourReset = v }
        if let v = reading.sevenDayReset { sevenDayReset = v }
        switch reading.verdict {
        case .ok:
            // A request the limiter let through means the account-wide limit is not in force.
            if limitedUntil != nil, reading.status != "rejected" { limitedUntil = nil; limitedClaim = nil; overage = false }
        case .limited(let until, let claim, let overage):
            if let scope = reading.scope {
                scoped[scope] = until
            } else {
                limitedUntil = until
                limitedClaim = claim
                self.overage = overage
            }
        case .other:
            break
        }
        scoped = scoped.filter { $0.value > now }
    }

    /// Whether a request for `family` should go to this account now.
    func isUsable(family: String?, allowOverage: Bool, now: Date) -> Bool {
        if signInNeeded { return false }
        if let until = limitedUntil, until > now, !(overage && allowOverage) { return false }
        if let family, let until = scoped[family], until > now { return false }
        return true
    }
}

struct RelayEvent: Codable, Equatable, Sendable {
    var at: Date
    var from: String?      // AccountRef key
    var to: String
    var reason: String
    /// "moved": a running session had to move. Nil: new sessions start on `to` from now on.
    var kind: String?
}

/// Which account a Claude Code session is on, so it stays there while its prompt cache is warm:
/// moving a warm session makes the new account read the whole conversation again at full price.
struct SessionPin: Codable, Equatable, Sendable {
    /// `AccountRef.key`: "main" or an account UUID.
    var account: String
    var lastUsed: Date
    /// When the session's last cached prefix expires: the latest request time plus that request's
    /// cache lifetime (1 h for Claude Code's main loop, 5 min for subagents).
    var warmUntil: Date

    func isWarm(_ now: Date) -> Bool { warmUntil > now }
}

/// Written by the relay every few seconds while it works; read by the app.
struct RelayState: Codable, Equatable, Sendable {
    var updatedAt = Date()
    var pid: Int32 = 0
    var accounts: [String: AccountLimitState] = [:]
    /// Where new sessions start now (an `AccountRef.key`).
    var inUse: String?
    /// Sessions by `x-claude-code-session-id`.
    var pins: [String: SessionPin] = [:]
    var events: [RelayEvent] = []
    var mainEmail: String?
    var mainUUID: String?
    var mainPlan: String?
    var decrypting = false
    var lastError: String?

    init() {}

    // Missing keys take their defaults, so a state file from an older relay still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        accounts = try c.decodeIfPresent([String: AccountLimitState].self, forKey: .accounts) ?? [:]
        inUse = try c.decodeIfPresent(String.self, forKey: .inUse)
        pins = try c.decodeIfPresent([String: SessionPin].self, forKey: .pins) ?? [:]
        events = try c.decodeIfPresent([RelayEvent].self, forKey: .events) ?? []
        mainEmail = try c.decodeIfPresent(String.self, forKey: .mainEmail)
        mainUUID = try c.decodeIfPresent(String.self, forKey: .mainUUID)
        mainPlan = try c.decodeIfPresent(String.self, forKey: .mainPlan)
        decrypting = try c.decodeIfPresent(Bool.self, forKey: .decrypting) ?? false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    /// Sessions per account (`AccountRef.key`) whose cache is still warm.
    func activeSessions(now: Date = .now) -> [String: Int] {
        pins.values.filter { $0.isWarm(now) }.reduce(into: [:]) { $0[$1.account, default: 0] += 1 }
    }

    static func load() -> RelayState? {
        guard let data = try? Data(contentsOf: HeadroomPaths.relayState) else { return nil }
        return try? JSONDecoder.headroom.decode(RelayState.self, from: data)
    }

    func save() {
        HeadroomPaths.ensure(HeadroomPaths.support)
        guard let data = try? JSONEncoder.headroom.encode(self) else { return }
        try? data.write(to: HeadroomPaths.relayState, options: .atomic)
    }
}

enum Router {
    /// The key an account's limits are kept under: its UUID, or "main" while Main's is unknown.
    static func stateKey(_ ref: AccountRef, mainUUID: String?) -> String {
        switch ref {
        case .main: mainUUID ?? "main"
        case .extra(let uuid): uuid
        }
    }

    /// Accounts to try for one request, best first. Ends with Main as the last resort, so that when
    /// every account is out, Claude Code still gets Anthropic's own answer with the real reset time.
    /// `mainUUID` is the account the request's own token belongs to; a connected account that is the
    /// same one is used through Main, with Claude Code's own token.
    ///
    /// A session whose cache is warm stays on its account while that account has room (`pin`). A new
    /// session, or one whose cache has expired, starts on the first account in the order that is below
    /// `config.newSessionThreshold`, so an account close to its limit is kept for the sessions already
    /// on it. If every account is above the threshold, the first one with room is used.
    static func candidates(config: ClaudeAccountsConfig, states: [String: AccountLimitState],
                           model: String?, mainUUID: String?, pin: SessionPin? = nil, now: Date = .now) -> [AccountRef] {
        let family = RateLimitReading.family(ofModel: model)
        var seen = Set<AccountRef>()
        let order = config.order.compactMap { ref -> AccountRef? in
            let resolved: AccountRef = ref == .extra(mainUUID ?? "") ? .main : ref
            return seen.insert(resolved).inserted ? resolved : nil
        }
        let usable = order.filter { ref in
            let state = states[stateKey(ref, mainUUID: mainUUID)] ?? AccountLimitState()
            switch ref {
            case .main:
                return state.isUsable(family: family, allowOverage: config.mainAllowOverage, now: now)
            case .extra(let uuid):
                guard let account = config.account(uuid) else { return false }
                return state.isUsable(family: family, allowOverage: account.allowOverage, now: now)
            }
        }
        let first: AccountRef?
        if let pin, pin.isWarm(now), let pinned = usable.first(where: { $0.key == pin.account }) {
            first = pinned
        } else {
            first = usable.first { load(states[stateKey($0, mainUUID: mainUUID)], now: now) < config.newSessionThreshold }
                ?? usable.first
        }
        var result = first.map { [$0] } ?? []
        result += usable.filter { $0 != first }
        if !result.contains(.main) { result.append(.main) }
        return result
    }

    /// How full an account is: the fuller of its Session and Weekly windows, 0...1. A window whose
    /// reset has passed counts as empty; an account never seen counts as empty.
    static func load(_ state: AccountLimitState?, now: Date) -> Double {
        guard let state else { return 0 }
        let five = (state.fiveHourReset.map { $0 > now } ?? true) ? (state.fiveHour ?? 0) : 0
        let seven = (state.sevenDayReset.map { $0 > now } ?? true) ? (state.sevenDay ?? 0) : 0
        return max(five, seven)
    }

    /// The longest cache lifetime a request asks for (`cache_control.ttl`, "5m" when absent).
    static func cacheLifetime(_ json: Any?) -> TimeInterval {
        var longest: TimeInterval = 0
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let cc = dict["cache_control"] as? [String: Any] {
                    longest = max(longest, (cc["ttl"] as? String) == "1h" ? 3600 : 300)
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        if let json { walk(json) }
        return longest
    }

    /// Puts `account` in place of the account UUID in the body's `metadata.user_id`, so the body names
    /// the account whose token goes with it. Only the last `"metadata"` object is touched, and the
    /// UUID keeps its length, so the body is otherwise byte for byte the same.
    static func rewriteAccount(in body: Data, to account: String) -> Data {
        guard account.count == 36, let text = String(data: body, encoding: .utf8),
              let meta = text.range(of: "\"metadata\"", options: .backwards) else { return body }
        let pattern = #"(\\"account_uuid\\"\s*:\s*\\")([0-9a-fA-F-]{36})(\\")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(meta.lowerBound..., in: text)),
              let uuid = Range(match.range(at: 2), in: text) else { return body }
        var out = text
        out.replaceSubrange(uuid, with: account)
        return Data(out.utf8)
    }

    /// "Session limit", "Weekly limit", "Opus weekly limit", "Extra usage".
    static func reason(_ state: AccountLimitState) -> String {
        if state.overage { return "Extra usage" }
        switch state.limitedClaim {
        case "five_hour": return "Session limit"
        case "seven_day": return "Weekly limit"
        case let claim?:
            if let scope = RateLimitReading.scope(of: claim) { return "\(scope.prefix(1).uppercased() + scope.dropFirst()) weekly limit" }
            return "Limit reached"
        case nil: return "Limit reached"
        }
    }
}
