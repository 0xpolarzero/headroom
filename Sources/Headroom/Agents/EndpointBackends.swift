import Foundation

/// Agents on Z.ai: not written yet.
enum ZAIBackend: AgentBackend {
    static func models() async throws -> [AgentModel] { [] }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        await UnavailableBackend.run(job, events)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}

/// Agents on OpenRouter: not written yet.
enum OpenRouterBackend: AgentBackend {
    static func models() async throws -> [AgentModel] { [] }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        await UnavailableBackend.run(job, events)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}
