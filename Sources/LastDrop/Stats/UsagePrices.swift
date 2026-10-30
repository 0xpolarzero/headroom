import Foundation

/// What one million tokens of each kind cost on a provider's API, in dollars.
struct UsageRates: Equatable, Sendable {
    var input: Double
    var cacheWrite: Double
    /// Claude's one-hour cache; other providers bill one write rate.
    var cacheWriteLong: Double
    var cacheRead: Double
    var output: Double

    init(input: Double, cacheWrite: Double, cacheWriteLong: Double? = nil, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong ?? cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    func scaled(input scale: Double, output outputScale: Double) -> UsageRates {
        UsageRates(input: input * scale, cacheWrite: cacheWrite * scale, cacheWriteLong: cacheWriteLong * scale,
                   cacheRead: cacheRead * scale, output: output * outputScale)
    }

    func cost(_ t: UsageTokens) -> Double {
        (Double(t.input) * input + Double(t.cacheWrite) * cacheWrite + Double(t.cacheWriteLong) * cacheWriteLong
            + Double(t.cacheRead) * cacheRead + Double(t.output) * output) / 1_000_000
    }
}

/// Official API prices, for showing subscription use in dollars. The index keeps tokens and they're priced when
/// read, so correcting a price here corrects all of history.
///
/// Anthropic: platform.claude.com/docs/en/about-claude/pricing. OpenAI: developers.openai.com/api/docs/pricing.
/// Google: ai.google.dev/gemini-api/docs/pricing. Checked 2026-10-30.
struct UsagePrice: Sendable {
    var rates: UsageRates
    /// Prompts above this many input tokens pay `longRates`.
    var longAbove: Int64?
    var longRates: UsageRates?
    /// The hour (since 1970) a price change takes effect, and the rates from then on.
    var changes: (hour: Int32, rates: UsageRates)?

    /// Where any model's rates change with prompt size. The index keeps each request's class, not whether it was
    /// long, so a model's long rates can be added or corrected later.
    private static let sizeLimits: [Int64] = [100_000, 272_000]

    static func sizeClass(_ promptSize: Int64) -> Int64 {
        Int64(sizeLimits.firstIndex { promptSize <= $0 } ?? sizeLimits.count)
    }

    func rates(sizeClass: Int64, hour: Int32) -> UsageRates {
        if let longAbove, let longRates, sizeClass > Self.sizeClass(longAbove) { return longRates }
        if let changes, hour >= changes.hour { return changes.rates }
        return rates
    }

    private static func claude(_ input: Double, _ read: Double, _ output: Double) -> UsagePrice {
        UsagePrice(rates: UsageRates(input: input, cacheWrite: input * 1.25, cacheWriteLong: input * 2, cacheRead: read, output: output))
    }

    private static func openAI(_ input: Double, _ cached: Double, _ output: Double) -> UsagePrice {
        let rates = UsageRates(input: input, cacheWrite: input * 1.25, cacheRead: cached, output: output)
        return UsagePrice(rates: rates, longAbove: 272_000, longRates: rates.scaled(input: 2, output: 1.5))
    }

    private static func gemini(_ input: Double, _ cached: Double, _ output: Double, doublesAt hour: Int32) -> UsagePrice {
        let rates = UsageRates(input: input, cacheWrite: input, cacheRead: cached, output: output)
        return UsagePrice(rates: rates, changes: (hour, rates.scaled(input: 2, output: 2)))
    }

    /// 2026-12-01 and 2027-01-01, UTC.
    private static let argonChange: Int32 = 498_912, flashChange: Int32 = 499_656

    /// By model name; the first prefix that matches, so "opus-5-5" comes before "opus-5".
    private static let table: [(String, UsagePrice)] = [
        ("claude-fable-5-1", claude(10, 0.25, 50)),
        ("claude-fable-5", claude(10, 1, 50)),
        ("claude-opus-5-5", claude(4, 0.2, 20)),
        ("claude-opus-5", claude(5, 0.5, 25)),
        ("claude-opus-4", claude(5, 0.5, 25)),
        ("claude-sonnet-5-5", claude(2, 0.1, 10)),
        ("claude-sonnet-5", claude(2, 0.2, 10)),
        ("claude-sonnet-4", claude(3, 0.3, 15)),
        ("claude-haiku-5-5", {
            var haiku = claude(0.1, 0.01, 0.5)
            haiku.longAbove = 100_000
            haiku.longRates = haiku.rates.scaled(input: 5, output: 5)
            return haiku
        }()),
        ("claude-haiku-4", claude(1, 0.1, 5)),
        ("gpt-6-astra", openAI(10, 1, 50)),
        ("gpt-6.1-sol", openAI(2, 0.1, 10)),
        ("gpt-6.1-terra", openAI(1, 0.05, 5)),
        ("gpt-6-sol", openAI(2, 0.2, 10)),
        ("gpt-6-luna", openAI(0.1, 0.01, 0.5)),
        ("gemini-4-argon", gemini(2, 0.1, 10, doublesAt: argonChange)),
        ("gemini-3.8-flash", gemini(0.75, 0.075, 3.75, doublesAt: flashChange)),
    ]

    static func of(_ model: String) -> UsagePrice? {
        table.first { model.hasPrefix($0.0) }?.1
    }

    /// The name people know a model by: "claude-opus-5-5" → "Opus 5.5", "gpt-6.1-sol" → "GPT-6.1 Sol".
    static func displayName(_ model: String) -> String {
        if model == "codex-auto-review" { return "Codex review" }
        var parts = model.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        switch parts.first {
        case "claude":
            guard parts.count >= 2 else { return model }
            return parts[1].capitalized + " " + parts.dropFirst(2).joined(separator: ".")
        case "gpt":
            guard parts.count >= 2 else { return model }
            return (["GPT-\(parts[1])"] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
        case "gemini": return parts.map(\.capitalized).joined(separator: " ")
        default: return model.isEmpty ? "Unknown" : model
        }
    }
}
