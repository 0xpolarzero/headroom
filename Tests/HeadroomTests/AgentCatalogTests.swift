import XCTest
@testable import Headroom

final class AgentCatalogTests: XCTestCase {
    private func agent(_ name: String, enabled: Bool = true) -> AgentDefinition {
        AgentDefinition(name: name, description: "Second opinion on hard bugs.", provider: .codex, model: "gpt-6.1-sol", effort: "high", enabled: enabled)
    }

    func testFindsEnabledAgentsByTypeOrName() {
        let catalog = AgentCatalog(agents: [agent("codex-deep"), agent("off", enabled: false)])
        XCTAssertEqual(catalog.agent("headroom:codex-deep")?.name, "codex-deep")
        XCTAssertEqual(catalog.agent("codex-deep")?.name, "codex-deep")
        XCTAssertNil(catalog.agent("headroom:off"))
        XCTAssertNil(catalog.agent("other:codex-deep"))
    }

    func testNamesAreAgentTypeSlugs() {
        XCTAssertEqual(AgentDefinition.slug("Codex Deep!"), "codex-deep")
        let catalog = AgentCatalog(agents: [agent("codex-deep")])
        XCTAssertEqual(catalog.problem(with: agent("codex-deep")), "Another agent is named codex-deep.")
        XCTAssertEqual(catalog.problem(with: agent("Codex Deep")), "Names use lowercase letters, digits, - and _.")
        XCTAssertNil(catalog.problem(with: agent("glm")))
        var blank = agent("glm")
        blank.description = " "
        XCTAssertNotNil(catalog.problem(with: blank))
    }

    func testSavingBumpsTheRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentCatalog(agents: [agent("codex-deep")]).save(to: url)
        let saved = AgentCatalog.load(from: url)
        XCTAssertEqual(saved.revision, 1)
        try saved.save(to: url)
        XCTAssertEqual(AgentCatalog.load(from: url).revision, 2)
    }

    func testThePluginGetsEnabledAgentsWithWhereTheyRun() {
        let json = AgentCatalog(agents: [agent("codex-deep"), agent("off", enabled: false)], revision: 4).pluginJSON()
        XCTAssertEqual(json["revision"] as? Int, 4)
        XCTAssertEqual(json["nativeTasks"] as? Bool, true)
        let agents = json["agents"] as? [[String: Any]] ?? []
        XCTAssertEqual(agents.map { $0["name"] as? String }, ["codex-deep"])
        XCTAssertEqual(agents.first?["summary"] as? String, "Codex · gpt-6.1-sol · high")
        XCTAssertTrue((agents.first?["prompt"] as? String ?? "").contains("Second opinion on hard bugs."))
    }

    func testAClaudeAgentGetsItsRoleInTheSystemPrompt() {
        let args = SubagentRunner.arguments(.init(prompt: "x", model: "opus", sessionID: "s1", systemPrompt: "You are reviewer."))
        XCTAssertEqual(Array(args.suffix(2)), ["--append-system-prompt", "You are reviewer."])
        XCTAssertFalse(args.contains("--agent"))
    }

    func testOlderCatalogsDefaultUsageSavingOff() throws {
        let data = Data("""
        {"revision":101,"agents":[{"id":"122651C3-88A7-4BF2-B4B0-2C3B5ADE7404","name":"worker",
        "description":"Explore code.","provider":"codex","model":"gpt-6-luna","enabled":true}]}
        """.utf8)
        let catalog = try JSONDecoder.headroom.decode(AgentCatalog.self, from: data)
        XCTAssertFalse(catalog.saveClaude)
    }

    func testUsageSavingPersistsAndReachesThePlugin() throws {
        let worker = agent("worker")
        let catalog = AgentCatalog(agents: [worker, agent("off", enabled: false)], revision: 4, saveClaude: true)
        let data = try JSONEncoder.headroom.encode(catalog)
        XCTAssertEqual(try JSONDecoder.headroom.decode(AgentCatalog.self, from: data), catalog)
        let json = catalog.pluginJSON()
        XCTAssertEqual(json["saveClaude"] as? Bool, true)
        let agents = try XCTUnwrap(json["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(AgentCatalog().pluginJSON()["saveClaude"] as? Bool, false)
    }
}
