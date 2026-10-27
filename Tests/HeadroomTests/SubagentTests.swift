import XCTest
@testable import Headroom

final class SubagentTests: XCTestCase {
    private func candidate(_ id: String, _ session: Double?, _ weekly: Double?, active: Int = 0) -> SubagentAccounts.Candidate {
        .init(account: ClaudeAccount(id: id), name: id, sessionUsed: session, weeklyUsed: weekly, active: active)
    }

    // MARK: Choosing an account

    func testPicksTheAccountWithMostRoom() {
        let picked = SubagentAccounts.pick([candidate("A", 60, 20), candidate("B", 10, 30)], sessionThreshold: 0.9, weeklyThreshold: 0.9)
        XCTAssertEqual(picked?.account.id, "B")
    }

    func testSkipsAccountsAtOrOverAThreshold() {
        XCTAssertNil(SubagentAccounts.pick([candidate("A", 90, 10), candidate("B", 10, 95)], sessionThreshold: 0.9, weeklyThreshold: 0.9))
        XCTAssertEqual(SubagentAccounts.pick([candidate("A", 89, 10)], sessionThreshold: 0.9, weeklyThreshold: 0.9)?.account.id, "A")
    }

    func testUnknownUsageIsNoRoom() {
        XCTAssertNil(SubagentAccounts.pick([candidate("A", nil, 10)], sessionThreshold: 0.9, weeklyThreshold: 0.9))
    }

    func testParallelCallsSpreadOverAccounts() {
        let picked = SubagentAccounts.pick([candidate("A", 10, 10, active: 2), candidate("B", 20, 20)], sessionThreshold: 0.9, weeklyThreshold: 0.9)
        XCTAssertEqual(picked?.account.id, "B")
    }

    func testOwnAccountComesFromTheSession() {
        XCTAssertEqual(SubagentAccounts.ownAccountUUID(environment: ["CLAUDE_CODE_ACCOUNT_UUID": "u1"]), "u1")
    }

    // MARK: Running Claude Code

    func testArgumentsMirrorTheBuiltInParameters() {
        let args = SubagentRunner.arguments(.init(prompt: "x", subagentType: "Explore", model: "haiku", effort: "high", worktree: true))
        XCTAssertEqual(args, ["-p", "--output-format", "json", "--permission-mode", "auto", "--agent", "Explore",
                              "--model", "haiku", "--effort", "high", "--worktree"])
        XCTAssertFalse(SubagentRunner.arguments(.init(prompt: "x", subagentType: "general-purpose")).contains("--agent"))
        XCTAssertEqual(SubagentRunner.arguments(.init(prompt: "x", resume: "s1")).suffix(2), ["--resume", "s1"])
    }

    func testEnvironmentDropsTheCallingSessionsIdentity() {
        let base = ["PATH": "/bin", "HOME": "/Users/x", "CLAUDE_CODE_ACCOUNT_UUID": "u1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                    "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/elsewhere", "ANTHROPIC_BASE_URL": "https://api.anthropic.com"]
        let pro = SubagentRunner.environment(for: ClaudeAccount(id: "Pro"), from: base)
        XCTAssertEqual(pro["PATH"], "/bin")
        XCTAssertNil(pro["CLAUDE_CODE_ACCOUNT_UUID"])
        XCTAssertNil(pro["CLAUDECODE"])
        XCTAssertTrue(pro["CLAUDE_CONFIG_DIR"]!.hasSuffix("/.claude-accounts/Pro"))
        XCTAssertEqual(pro[SubagentServer.nestedMarker], "1")
        XCTAssertNil(SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: base)["CLAUDE_CONFIG_DIR"])
    }

    func testParsesClaudeCodesResult() {
        let ok = SubagentRunner.parse(Data(#"{"type":"result","is_error":false,"result":"HELLO","session_id":"s1","num_turns":2,"permission_denials":[]}"#.utf8), stderr: "")
        XCTAssertEqual(ok, .init(text: "HELLO", sessionID: "s1", isError: false, limitReached: false, turns: 2, permissionDenials: 0))
        XCTAssertFalse(ok.modelUnavailable)
        let limit = SubagentRunner.parse(Data(#"{"is_error":true,"result":"Claude AI usage limit reached","api_error_status":429,"num_turns":1}"#.utf8), stderr: "")
        XCTAssertTrue(limit.limitReached)
        let model = SubagentRunner.parse(Data(#"{"is_error":true,"result":"Fable 5.1 requires usage credits. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.","api_error_status":429,"num_turns":1}"#.utf8), stderr: "")
        XCTAssertTrue(model.modelUnavailable)
        XCTAssertFalse(model.limitReached)
        let crash = SubagentRunner.parse(Data(), stderr: "boom")
        XCTAssertEqual(crash.text, "boom")
        XCTAssertTrue(crash.isError)
    }

    func testResultEndsWithTheAgentID() {
        let text = SubagentServer().format(.init(text: "Done.", sessionID: "s1", isError: false, limitReached: false, turns: 3, permissionDenials: 1), account: "Pro")
        XCTAssertTrue(text.hasPrefix("Done."))
        XCTAssertTrue(text.contains("denied 1 action"))
        XCTAssertTrue(text.hasSuffix("agentId: s1 (ran on the Pro account; use SendMessage with this agentId to continue this agent)"))
    }

    // MARK: MCP

    private func exchange(_ message: [String: Any]) async -> [String: Any]? {
        let server = SubagentServer()
        let box = Box()
        server.output = { box.data = $0 }
        await server.handle(message)
        return box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testInitializeCarriesTheInstructions() async {
        let reply = await exchange(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue((result?["instructions"] as? String)?.contains(SubagentServer.noRoom) == true)
    }

    func testListsAgentAndSendMessage() async {
        let reply = await exchange(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["Agent", "SendMessage"])
        let schema = tools?.first?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["description", "prompt"])
    }

    func testUnknownMethodIsAnError() async {
        let reply = await exchange(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }
}

private final class Box: @unchecked Sendable { var data: Data? }
