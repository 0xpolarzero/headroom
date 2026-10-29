import Foundation

/// Agents setup offers for the plans someone has connected: a starting point, added one at a time.
enum AgentSuggestions {
    static let all: [AgentDefinition] = [
        AgentDefinition(name: "sol", description: "Reviews: code, plans and diffs that need strong coding reasoning.",
                        provider: .codex, model: "gpt-6.1-sol", effort: "high"),
        AgentDefinition(name: "argon", description: "Advisor: opinions, trade-offs and recommendations that need deep reasoning.",
                        provider: .antigravity, model: "gemini-4-argon", effort: "high"),
        AgentDefinition(name: "gemini", description: "Implementation and exploration on a cheaper model, at low thinking.",
                        provider: .antigravity, model: "gemini-3.8-flash", effort: "low"),
        AgentDefinition(name: "flash", description: "Implementation and exploration on a cheaper model.",
                        provider: .zai, model: "glm-5.3-flash"),
        AgentDefinition(name: "terra-cu", description: "Computer use: operating macOS app windows.",
                        provider: .codex, model: "gpt-6.1-terra", effort: "low"),
    ]

    /// The suggestions not in the list yet whose plan can run them.
    static func available(catalog: AgentCatalog, canRun: (AgentProvider) -> Bool) -> [AgentDefinition] {
        all.filter { suggestion in canRun(suggestion.provider) && !catalog.agents.contains { $0.name == suggestion.name } }
    }
}
