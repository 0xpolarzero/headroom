import Foundation

/// Agents on Antigravity: not written yet.
enum AntigravityBackend: AgentBackend {
    static func models() async throws -> [AgentModel] { [] }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        await UnavailableBackend.run(job, events)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { nil }
}
