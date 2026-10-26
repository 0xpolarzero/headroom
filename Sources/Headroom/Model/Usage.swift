import Foundation

/// One limit window, e.g. "Session" (5h) or "Weekly".
struct UsageWindow: Hashable, Sendable, Codable {
    var label: String
    /// 0...100, share of the window already used. Nil when the provider returned no number.
    var usedPercent: Double?
    var resetsAt: Date?
    /// Optional count-style value shown instead of a percent ("12 / 100 searches").
    var detail: String?
}

/// Everything a provider (or one account of a provider) reports in one refresh.
struct UsageSnapshot: Hashable, Sendable, Codable {
    var title: String           // "Codex", "Antigravity", "Z.ai"
    var plan: String?           // "Max 5x", "Pro", "GLM Coding Max"
    var windows: [UsageWindow]
    var fetchedAt: Date = .now
}

enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, antigravity, zai
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .zai: "Z.ai"
        }
    }
}

enum ProviderError: LocalizedError, Sendable {
    case notConfigured(String)      // e.g. "Run `codex` to sign in."
    case unauthorized(String)
    case http(Int)
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s), .unauthorized(let s), .message(let s): s
        case .http(let code): "Request failed (HTTP \(code))."
        case .invalidResponse: "Unexpected response."
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageSnapshot
}
