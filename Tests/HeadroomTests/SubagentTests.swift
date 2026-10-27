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

    func testBackgroundAdmissionReadsThePluginProtocol() throws {
        func request(_ fields: String) throws -> AgentRun.Request {
            try JSONDecoder().decode(AgentRun.Request.self, from: Data("{\"prompt\":\"x\",\"cwd\":\"/work\"\(fields)}".utf8))
        }
        XCTAssertNotNil(try request(",\"background\":true,\"interactive\":false").backgroundError)
        XCTAssertNotNil(try request(",\"background\":true").backgroundError)
        XCTAssertNil(try request(",\"background\":true,\"interactive\":true").backgroundError)
        XCTAssertNil(try request(",\"background\":false,\"interactive\":false").backgroundError)
        XCTAssertNil(try request("").backgroundError)
    }

    func testArgumentsMirrorTheBuiltInParameters() {
        let args = SubagentRunner.arguments(.init(prompt: "x", subagentType: "Explore", model: "haiku", effort: "high", worktree: true,
                                                  permissionMode: "acceptEdits", sessionID: "s1", mcpConfig: "/m.json"))
        XCTAssertEqual(args, ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                              "--session-id", "s1", "--agent", "Explore", "--model", "haiku", "--effort", "high", "--worktree",
                              "--mcp-config", "/m.json"])
        XCTAssertFalse(SubagentRunner.arguments(.init(prompt: "x", subagentType: "general-purpose", sessionID: "s")).contains("--agent"))
        XCTAssertTrue(SubagentRunner.arguments(.init(prompt: "x", sessionID: "s1", resume: true)).contains("--resume"))
    }

    func testPermissionModeFollowsTheSession() {
        XCTAssertEqual(AgentRun.mappedPermissionMode("acceptEdits"), "acceptEdits")
        XCTAssertEqual(AgentRun.mappedPermissionMode("plan"), "plan")
        XCTAssertEqual(AgentRun.mappedPermissionMode("default"), "auto")   // a headless run can't ask
        XCTAssertEqual(AgentRun.mappedPermissionMode(nil), "auto")
    }

    func testEnvironmentDropsTheCallingSessionsIdentity() {
        let base = ["PATH": "/bin", "HOME": "/Users/x", "CLAUDE_CODE_ACCOUNT_UUID": "u1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
                    "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/elsewhere", "ANTHROPIC_BASE_URL": "https://api.anthropic.com"]
        let pro = SubagentRunner.environment(for: ClaudeAccount(id: "Pro"), from: base)
        XCTAssertEqual(pro["PATH"], "/bin")
        XCTAssertNil(pro["CLAUDE_CODE_ACCOUNT_UUID"])
        XCTAssertNil(pro["CLAUDECODE"])
        XCTAssertTrue(pro["CLAUDE_CONFIG_DIR"]!.hasSuffix("/.claude-accounts/Pro"))
        XCTAssertEqual(pro[AgentRun.nestedMarker], "1")
        XCTAssertNil(SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: base)["CLAUDE_CONFIG_DIR"])
    }

    func testMCPServersComeFromTheCallersConfig() {
        let root: [String: Any] = [
            "mcpServers": ["lcu": ["command": "lcu"], "headroom": ["command": "Headroom"]],
            "projects": ["/work": ["mcpServers": ["db": ["command": "db"]]], "/other": ["mcpServers": ["x": [:]]]],
        ]
        let servers = SubagentRunner.mcpConfig(from: root, directory: "/work")?["mcpServers"] as? [String: Any]
        XCTAssertEqual(Set(servers?.keys ?? [:].keys), ["lcu", "db"])
        XCTAssertNil(SubagentRunner.mcpConfig(from: [:], directory: "/work"))
    }

    func testParsesClaudeCodesResult() {
        let ok = SubagentRunner.parse(["type": "result", "is_error": false, "result": "HELLO", "num_turns": 2, "permission_denials": [],
                                       "duration_ms": 1200, "usage": ["input_tokens": 10, "output_tokens": 5]])
        XCTAssertEqual(ok.text, "HELLO")
        XCTAssertFalse(ok.isError)
        XCTAssertEqual(ok.durationMs, 1200)
        XCTAssertEqual(ok.outputTokens, 5)
        let limit = SubagentRunner.parse(["is_error": true, "result": "Claude AI usage limit reached", "api_error_status": 429, "num_turns": 1])
        XCTAssertTrue(limit.limitReached)
        let model = SubagentRunner.parse(["is_error": true, "result": "Fable 5.1 requires usage credits. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.", "api_error_status": 429])
        XCTAssertTrue(model.modelUnavailable)
        XCTAssertFalse(model.limitReached)
    }

    func testStepsReadLikeAgentProgress() {
        XCTAssertEqual(SubagentRunner.describe(tool: "Read", input: ["file_path": "/a/b/note.txt"]), "Read: note.txt")
        XCTAssertEqual(SubagentRunner.describe(tool: "Bash", input: ["command": "npm test", "description": "Run the tests"]), "Bash: Run the tests")
        XCTAssertEqual(SubagentRunner.describe(tool: "TodoWrite", input: [:]), "TodoWrite")
    }

    func testAReadyProcessMatchesEverythingButTheSession() {
        let account = ClaudeAccount(id: "Pro")
        let a = SubagentRunner.Request(prompt: "one", model: "sonnet", permissionMode: "auto", sessionID: "s1", mcpConfig: "/m.json")
        var b = a
        b.prompt = "two"
        b.sessionID = "s2"
        let specA = SubagentRunner.warmSpec(a, on: account, in: "/work", environment: [:])
        XCTAssertEqual(specA?.arguments.contains("--session-id"), false)
        XCTAssertTrue(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: ["PATH": "/bin"])!) ?? false)
        // The runner switches these after taking a process over.
        b.model = "haiku"
        b.permissionMode = "plan"
        XCTAssertTrue(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: [:])!) ?? false)
        b.subagentType = "Explore"
        XCTAssertFalse(specA?.matches(SubagentRunner.warmSpec(b, on: account, in: "/work", environment: [:])!) ?? true)
        XCTAssertFalse(specA?.matches(SubagentRunner.warmSpec(a, on: account, in: "/elsewhere", environment: [:])!) ?? true)
        var resumed = a
        resumed.resume = true
        XCTAssertNil(SubagentRunner.warmSpec(resumed, on: account, in: "/work", environment: [:]))
    }

    func testATakenOverProcessIsSwitchedToTheRunsModelAndMode() {
        let switches = WarmPool.switches(model: "haiku", permissionMode: "plan")
        XCTAssertEqual(switches.map(\.id), ["mode", "model"])
        let model = try? JSONSerialization.jsonObject(with: switches[1].data) as? [String: Any]
        XCTAssertEqual(model?["type"] as? String, "control_request")
        XCTAssertEqual(model?["request_id"] as? String, "model")
        XCTAssertEqual((model?["request"] as? [String: Any])?["subtype"] as? String, "set_model")
        XCTAssertEqual((model?["request"] as? [String: Any])?["model"] as? String, "haiku")
        XCTAssertEqual(WarmPool.switches(model: nil, permissionMode: "auto").map(\.id), ["mode"])
    }

    func testPipesTravelOverTheSocket() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let pipe = Pipe()
        WarmPool.reply(pair[0], ["sessionID": "abc"], passing: [pipe.fileHandleForWriting.fileDescriptor])
        var fds: [Int32] = []
        let reply = WarmPool.receive(pair[1], fds: &fds)
        XCTAssertEqual(reply?["sessionID"] as? String, "abc")
        XCTAssertEqual(fds.count, 1)
        let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        handle.write(Data("hi".utf8))
        try handle.close()
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "hi")
        close(pair[0]); close(pair[1])
    }

    func testThePromptIsAStreamJSONUserMessage() throws {
        let line = WarmPool.userMessage("Read note.txt")
        XCTAssertEqual(line.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
        XCTAssertEqual((object?["message"] as? [String: Any])?["content"] as? String, "Read note.txt")
    }

    func testTranscriptEntriesReadLikeTheAgentsRow() {
        XCTAssertEqual(SubagentRunner.transcriptItem(["type": "text", "text": "Done."])?["text"] as? String, "Done.")
        let tool = SubagentRunner.transcriptItem(["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a/note.txt"]])
        XCTAssertEqual(tool?["summary"] as? String, "Read: note.txt")
        XCTAssertEqual(tool?["id"] as? String, "t1")
        XCTAssertTrue((tool?["input"] as? String)?.contains("\"/a/note.txt\"") == true)
        let result = SubagentRunner.transcriptItem(["type": "tool_result", "tool_use_id": "t1",
                                                    "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"]]])
        XCTAssertEqual(result?["text"] as? String, "a\nb")
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertNil(SubagentRunner.transcriptItem(["type": "thinking", "thinking": "…"]))
        XCTAssertEqual((SubagentRunner.transcriptItem(["type": "text", "text": String(repeating: "x", count: 5000)])?["text"] as? String)?.count, 4001)
    }

    func testAFollowUpKeepsTheAgentTypeAndEffort() {
        let args = SubagentRunner.arguments(.init(prompt: "x", subagentType: "Explore", effort: "high", sessionID: "s1", resume: true))
        XCTAssertEqual(Array(args[6...]), ["--resume", "s1", "--agent", "Explore", "--effort", "high"])
    }

    func testClaudeCodesInitIsCheckedBeforeTheAgentCountsAsStarted() {
        let init_: [String: Any] = ["type": "system", "subtype": "init", "session_id": "s", "cwd": "/w/.claude/worktrees/a",
                                    "model": "claude-haiku-5-5", "agents": ["general-purpose", "Explore", "Plan"]]
        XCTAssertNil(SubagentRunner.checkInit(init_, subagentType: "Explore"))
        XCTAssertNil(SubagentRunner.checkInit(init_, subagentType: nil))
        XCTAssertEqual(SubagentRunner.checkInit(init_, subagentType: "Reviewer"), "the Reviewer agent type isn't available")
        var changed = init_
        changed["agents"] = nil
        XCTAssertEqual(SubagentRunner.checkInit(changed, subagentType: nil), "Claude Code's init event has no `agents`")
    }

    func testAUsageLimitReadsFromClaudeCodesApiError() {
        let limit = SubagentRunner.parse(["is_error": true, "result": "You've hit your weekly limit", "api_error": "usage_limit_reached"])
        XCTAssertTrue(limit.limitReached)
    }

    func testAgentsRecordedBeforeTheAgentTypeWasKeptStillLoad() throws {
        let old = #"{"account":"Pro","directory":"/w","sessionID":"s","model":"haiku","at":1793098000}"#
        let entry = try JSONDecoder.headroom.decode(AgentRegistry.Entry.self, from: Data(old.utf8))
        XCTAssertEqual(entry.sessionID, "s")
        XCTAssertNil(entry.subagentType)
        let store = try JSONDecoder.headroom.decode(AgentRegistry.Store.self, from: Data(#"{"agents":{},"lacking":{},"fullUntil":{}}"#.utf8))
        XCTAssertNil(store.processes)
    }
}
