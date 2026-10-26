import Foundation

/// One limit window, e.g. "Session" (5h) or "Weekly".
struct UsageWindow: Hashable, Sendable, Codable {
    var label: String
    /// 0...100, share of the window already used. Nil when the provider returned no number.
    var usedPercent: Double?
    var resetsAt: Date?
    /// Optional count-style value shown instead of a percent ("75 / 100 left").
    var detail: String?

    var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
}

/// Spend on one API key (OpenRouter), in dollars.
struct KeyUsage: Hashable, Sendable, Codable {
    var name: String
    var total: Double
    var today: Double?
    var month: Double?
    var limit: Double?
    var limitRemaining: Double?
    var disabled = false
}

/// Everything a provider (or one account of a provider) reports in one refresh.
struct UsageSnapshot: Hashable, Sendable, Codable {
    var title: String           // "Claude", "Codex", "Antigravity", "Z.ai", "OpenRouter"
    var plan: String?           // "Max 5x", "Pro", "GLM Coding Max"
    var windows: [UsageWindow]
    /// Per-key spend, shown when the provider section is expanded.
    var keys: [KeyUsage] = []
    /// Replaces the Session/Weekly percentages in the menu bar ("$37.66").
    var menuBarText: String?
    var fetchedAt: Date = .now
}

enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, antigravity, zai, openrouter
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .zai: "Z.ai"
        case .openrouter: "OpenRouter"
        }
    }
}

enum ProviderError: LocalizedError, Sendable {
    case notConfigured(String)      // e.g. "Run `codex` to sign in."; hides the menu bar item
    case unauthorized(String)
    case http(Int)
    case rateLimited(String)        // retried on the normal schedule, not the fast one
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s), .unauthorized(let s), .message(let s), .rateLimited(let s): s
        case .http(let code): "Request failed (HTTP \(code))."
        case .invalidResponse: "Unexpected response."
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageSnapshot
}
