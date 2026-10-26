import Foundation

/// What one `/v1/messages` response says about the account that served it, from Anthropic's
/// `anthropic-ratelimit-unified-*` headers. Shapes as in Claude Code 2.1.308 (docs/claude-accounts.md, result 4).
struct RateLimitReading: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// Served normally.
        case ok
        /// The limit ran out: refused (429), or served only because extra usage paid for it.
        case limited(until: Date, claim: String?, overage: Bool)
        /// A refusal that says nothing about this account's limits (429 without unified headers, 529, 5xx).
        case other
    }

    var verdict: Verdict
    var status: String?
    var fiveHour: Double?        // 0...1
    var sevenDay: Double?        // 0...1
    var fiveHourReset: Date?
    var sevenDayReset: Date?
    var claim: String?
    /// The model family a claim like `seven_day_opus` applies to; nil for the account-wide windows.
    var scope: String? { RateLimitReading.scope(of: claim) }

    static let prefix = "anthropic-ratelimit-unified-"

    /// `headers` keys must be lowercase.
    static func read(status code: Int, headers: [String: String], now: Date = .now) -> RateLimitReading {
        func h(_ name: String) -> String? { headers[prefix + name] }
        func date(_ name: String) -> Date? { h(name).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
        let status = h("status")
        let overage = h("overage-status")
        let claim = h("representative-claim")
        var reading = RateLimitReading(verdict: .ok, status: status,
                                       fiveHour: h("5h-utilization").flatMap(Double.init),
                                       sevenDay: h("7d-utilization").flatMap(Double.init),
                                       fiveHourReset: date("5h-reset"), sevenDayReset: date("7d-reset"),
                                       claim: claim)
        let overageCovers = overage == "allowed" || overage == "allowed_warning"
        func until() -> Date {
            if let reset = date("reset"), reset > now { return reset }
            if let after = headers["retry-after"].flatMap(Double.init), after > 0 { return now.addingTimeInterval(after) }
            return now.addingTimeInterval(claim == "five_hour" ? 5 * 3600 : 3600)
        }
        if code == 429 {
            reading.verdict = status == "rejected" && !overageCovers ? .limited(until: until(), claim: claim, overage: false) : .other
        } else if (200..<300).contains(code) {
            if status == "rejected" && overageCovers { reading.verdict = .limited(until: until(), claim: claim, overage: true) }
        } else {
            reading.verdict = .other
        }
        return reading
    }

    /// `seven_day_opus` → "opus"; `five_hour`, `seven_day` and unknown shapes → nil (whole account).
    static func scope(of claim: String?) -> String? {
        guard let claim, claim.hasPrefix("seven_day_") else { return nil }
        let family = String(claim.dropFirst("seven_day_".count))
        return family.isEmpty ? nil : family
    }

    /// "claude-opus-5-5" → "opus", "claude-haiku-5-5" → "haiku". Nil when the model is unknown.
    static func family(ofModel model: String?) -> String? {
        guard let model = model?.lowercased() else { return nil }
        for family in ["opus", "sonnet", "haiku", "fable"] where model.contains(family) { return family }
        let parts = model.split(separator: "-")
        return parts.count > 1 && parts[0] == "claude" ? String(parts[1]) : nil
    }
}
