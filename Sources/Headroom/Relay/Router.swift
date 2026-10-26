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
}

/// Written by the relay every few seconds while it works; read by the app.
struct RelayState: Codable, Equatable, Sendable {
    var updatedAt = Date()
    var pid: Int32 = 0
    var accounts: [String: AccountLimitState] = [:]
    /// The account the last `/v1/messages` request went to.
    var inUse: String?
    var events: [RelayEvent] = []
    var mainEmail: String?
    var mainUUID: String?
    var mainPlan: String?
    var decrypting = false
    var lastError: String?

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
    static func candidates(config: ClaudeAccountsConfig, states: [String: AccountLimitState],
                           model: String?, mainUUID: String?, now: Date = .now) -> [AccountRef] {
        let family = RateLimitReading.family(ofModel: model)
        var seen = Set<AccountRef>()
        let order = config.order.compactMap { ref -> AccountRef? in
            let resolved: AccountRef = ref == .extra(mainUUID ?? "") ? .main : ref
            return seen.insert(resolved).inserted ? resolved : nil
        }
        var result = order.filter { ref in
            let state = states[stateKey(ref, mainUUID: mainUUID)] ?? AccountLimitState()
            switch ref {
            case .main:
                return state.isUsable(family: family, allowOverage: config.mainAllowOverage, now: now)
            case .extra(let uuid):
                guard let account = config.account(uuid) else { return false }
                return state.isUsable(family: family, allowOverage: account.allowOverage, now: now)
            }
        }
        if !result.contains(.main) { result.append(.main) }
        return result
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
