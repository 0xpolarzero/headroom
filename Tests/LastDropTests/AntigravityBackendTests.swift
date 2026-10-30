import XCTest
@testable import LastDrop

final class AntigravityBackendTests: XCTestCase {
    func testModelsGroupOnlyOfferedEfforts() throws {
        let models = AntigravityBackend.parseModels("""
        Fetching available models...
        gemini-4-argon-high\tGemini 4 Argon (High)
        gemini-4-argon-medium\tGemini 4 Argon (Medium)
        gemini-4-argon-low\tGemini 4 Argon (Low)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        fixed-model\tFixed Model
        """)
        XCTAssertEqual(models.map(\.id), ["gemini-4-argon", "gpt-oss-120b", "fixed-model"])
        XCTAssertEqual(models[0], AgentModel(id: "gemini-4-argon", name: "Gemini 4 Argon", efforts: ["low", "medium", "high"], defaultEffort: "medium"))
        XCTAssertEqual(models[1].efforts, ["medium"])
        XCTAssertTrue(models[2].efforts.isEmpty)
        XCTAssertEqual(try AntigravityBackend.slug(model: models[0].id, effort: nil, models: models), "gemini-4-argon-medium")
        XCTAssertEqual(try AntigravityBackend.slug(model: models[0].id, effort: "low", models: models), "gemini-4-argon-low")
        XCTAssertEqual(try AntigravityBackend.slug(model: "gemini-4-argon-high", effort: "low", models: []), "gemini-4-argon-high")
        XCTAssertEqual(try AntigravityBackend.slug(model: "fixed-model", effort: nil, models: models), "fixed-model")
        XCTAssertThrowsError(try AntigravityBackend.slug(model: "gpt-oss-120b", effort: "high", models: models))
        XCTAssertThrowsError(try AntigravityBackend.slug(model: "missing", effort: nil, models: models))
    }

    func testStreamCoalescesTextAndDeduplicatesTools() throws {
        let log = Log()
        var stream = AntigravityBackend.Stream(model: "gemini-3.8-flash-low", directory: "/work", events: log.events)
        try feed("""
        {"event":"init","conversation_id":"session","init":{"cwd":"/work","model":"gemini-3.8-flash-low","permission_mode":"request-review"}}
        {"event":"init","conversation_id":"session","init":{"cwd":"/work"}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"hel"}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"lo"}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"lo"}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"echo hello"}}}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"echo hello"},"output":"hello"}}}
        {"event":"step_update","step_update":{"conversation_id":"session","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"output":"hello"}}}
        {"event":"result","result":{"conversation_id":"session","status":"SUCCESS","response":"hello","num_turns":1,"duration_seconds":1.25,"usage":{"input_tokens":42,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":10}}}
        """, into: &stream)
        let result = stream.finish(exitCode: 0, stderr: "")
        XCTAssertEqual(log.started, ["Antigravity:gemini-3.8-flash-low"])
        XCTAssertEqual(log.steps, ["run_command: echo hello"])
        XCTAssertEqual(log.items.map { $0["kind"] as? String }, ["text", "tool", "result"])
        XCTAssertEqual(log.items[0]["text"] as? String, "hello")
        XCTAssertEqual(log.items[1]["id"] as? String, log.items[2]["id"] as? String)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.toolUses, 1)
        XCTAssertEqual(result.durationMs, 1250)
        XCTAssertEqual(result.inputTokens, 52)
        XCTAssertEqual(result.outputTokens, 3)
        XCTAssertEqual(result.sessionID, "session")
        XCTAssertEqual(result.directory, "/work")
        XCTAssertEqual(result.account, "Antigravity")
    }

    /// Captured with agy 1.4.8 on 2026-10-27: Flash Low, one prompt and one explicit resume.
    func testCapturedStreamCountsOnlyTheNewTurnOnResume() throws {
        let turns = [
            """
            {"conversation_id":"session","event":"init","init":{"cwd":"/work","model":"gemini-3.8-flash-low"}}
            {"event":"step_update","step_update":{"conversation_id":"session","state":"DONE","step_index":0,"step_type":"user_input"}}
            {"event":"step_update","step_update":{"conversation_id":"session","state":"ACTIVE","step_index":1,"step_type":"agent_response","text_delta":"ok"}}
            {"event":"step_update","step_update":{"conversation_id":"session","duration_seconds":2.5887449999999999,"state":"DONE","step_index":1,"step_type":"agent_response","text_delta":"\\n","usage":{"cache_read_tokens":0,"input_tokens":7289,"output_tokens":1,"thinking_tokens":0,"total_tokens":7290}}}
            {"event":"result","result":{"conversation_id":"session","duration_seconds":2.6383010000000002,"num_turns":1,"response":"ok\\n","status":"SUCCESS","usage":{"cache_read_tokens":0,"input_tokens":7289,"output_tokens":1,"thinking_tokens":0,"total_tokens":7290}}}
            """,
            """
            {"conversation_id":"session","event":"init","init":{"cwd":"/work","model":"gemini-3.8-flash-low"}}
            {"event":"step_update","step_update":{"conversation_id":"session","state":"DONE","step_index":2,"step_type":"user_input"}}
            {"event":"step_update","step_update":{"conversation_id":"session","duration_seconds":0.000173,"state":"DONE","step_index":3,"step_type":"system_message"}}
            {"event":"step_update","step_update":{"conversation_id":"session","state":"ACTIVE","step_index":4,"step_type":"agent_response","text_delta":"ok"}}
            {"event":"step_update","step_update":{"conversation_id":"session","duration_seconds":1.2563530000000001,"state":"DONE","step_index":4,"step_type":"agent_response","text_delta":"\\n","usage":{"cache_read_tokens":0,"input_tokens":7546,"output_tokens":1,"thinking_tokens":0,"total_tokens":7547}}}
            {"event":"result","result":{"conversation_id":"session","duration_seconds":7.1276809999999999,"num_turns":2,"response":"ok\\n","status":"SUCCESS","usage":{"cache_read_tokens":0,"input_tokens":14835,"output_tokens":2,"thinking_tokens":0,"total_tokens":14837}}}
            """
        ]
        for (index, fixture) in turns.enumerated() {
            let log = Log()
            var stream = AntigravityBackend.Stream(model: "gemini-3.8-flash-low", directory: "/work", events: log.events)
            try feed(fixture, into: &stream)
            let result = stream.finish(exitCode: 0, stderr: "")
            XCTAssertFalse(result.isError)
            XCTAssertEqual(result.text, "ok\n")
            XCTAssertEqual(result.turns, 1)
            XCTAssertEqual(result.inputTokens, index == 0 ? 7289 : 7546)
            XCTAssertEqual(result.outputTokens, 1)
            XCTAssertEqual(result.durationMs, index == 0 ? 2638 : 7127)
            XCTAssertEqual(log.items.count, 1)
            XCTAssertEqual(log.items.first?["text"] as? String, "ok\n")
        }
    }

    func testErrorsAndIncompleteStreamsNeverSucceed() throws {
        for status in ["ERROR", "CANCELED", "INTERRUPTED", "RUNNING", ""] {
            var stream = AntigravityBackend.Stream(model: "m", directory: "/work", events: Log().events)
            try feed("{\"event\":\"init\",\"conversation_id\":\"session\",\"init\":{\"cwd\":\"/work\"}}", into: &stream)
            try feed("{\"event\":\"result\",\"result\":{\"status\":\"\(status)\",\"response\":\"partial\"}}", into: &stream)
            let result = stream.finish(exitCode: 0, stderr: "")
            XCTAssertTrue(result.isError, status)
            XCTAssertTrue(result.text.contains(status.isEmpty ? "INCOMPLETE" : status))
        }
        let stream = AntigravityBackend.Stream(model: "m", directory: "/work", events: Log().events)
        XCTAssertTrue(stream.finish(exitCode: 0, stderr: "").isError)
        let quota = stream.finish(exitCode: 1, stderr: "RESOURCE_EXHAUSTED: quota exhausted; resets tomorrow")
        XCTAssertTrue(quota.limitReached)
        let auth = stream.finish(exitCode: 1, stderr: "authentication required")
        XCTAssertTrue(auth.text.contains("agy"))
        XCTAssertFalse(auth.limitReached)
        let entitlement = stream.finish(exitCode: 1, stderr: "Model is not available on your plan")
        XCTAssertTrue(entitlement.modelUnavailable)
        XCTAssertFalse(entitlement.limitReached)
        XCTAssertFalse(stream.finish(exitCode: 1, stderr: "429: too many requests, try again").limitReached)
        var success = AntigravityBackend.Stream(model: "m", directory: "/work", events: Log().events)
        try feed("{\"event\":\"result\",\"result\":{\"status\":\"SUCCESS\",\"response\":\"ok\"}}", into: &success)
        XCTAssertTrue(success.finish(exitCode: 0, stderr: "").isError, "No init must never start a successful run.")
        try feed("{\"event\":\"init\",\"conversation_id\":\"session\",\"init\":{\"cwd\":\"/work\"}}", into: &success)
        XCTAssertTrue(success.finish(exitCode: 1, stderr: "child failed").isError)
    }

    func testExecutablePrefersNativeInstallThenPATH() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = try fakeCLI(in: folder)
        let local = folder.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let native = local.appendingPathComponent("agy")
        try FileManager.default.createSymbolicLink(atPath: native.path, withDestinationPath: cli)
        let environment = ["PATH": folder.path]
        XCTAssertEqual(AntigravityBackend.executable(environment: environment, home: folder.path), native.path)
        try FileManager.default.removeItem(at: native)
        XCTAssertEqual(AntigravityBackend.executable(environment: environment, home: folder.path), cli)
    }

    func testPermissionModesAndExplicitResume() {
        var job = job()
        for mode in ["plan", "unknown"] {
            job.permissionMode = mode
            let args = AntigravityBackend.arguments(job, slug: "gemini-3.8-flash-low")
            XCTAssertTrue(args.contains("plan"))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        }
        for mode in ["default", "acceptEdits", "auto", "bypassPermissions"] {
            job.permissionMode = mode
            let args = AntigravityBackend.arguments(job, slug: "gemini-3.8-flash-low")
            XCTAssertTrue(args.contains("accept-edits"))
            XCTAssertEqual(args.contains("--dangerously-skip-permissions"), mode == "bypassPermissions")
        }
        job.resume = entry(directory: "/tmp/with ' quote", session: "session; echo bad")
        let args = AntigravityBackend.arguments(job, slug: "gemini-3.8-flash-low")
        XCTAssertEqual(Array(args.suffix(2)), ["--conversation", "session; echo bad"])
        XCTAssertFalse(args.contains("--continue"))
        XCTAssertEqual(AntigravityBackend.terminal(job.resume!), "cd '/tmp/with '\\'' quote' || exit 1\nexec agy --conversation 'session; echo bad'")
    }

    func testAReadOnlyRoleRunsInPlanModeWhateverTheModeIs() {
        var job = job()
        job.role = "Explore"
        for mode in ["default", "acceptEdits", "auto", "bypassPermissions"] {
            job.permissionMode = mode
            let args = AntigravityBackend.arguments(job, slug: "gemini-3.8-flash-low")
            XCTAssertEqual(args.firstIndex(of: "--mode").map { args[$0 + 1] }, "plan", mode)
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"), mode)
        }
        XCTAssertTrue(job.instructions.contains("search and read only"))
    }

    func testDeniedToolsAreListedAsDeclined() throws {
        let log = Log()
        var stream = AntigravityBackend.Stream(model: "m-low", directory: "/work", events: log.events)
        try feed("""
        {"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"DONE","tool_name":"write_to_file","tool_info":{"parameters":{"TargetFile":"/work/a.txt"},"error":{"type":"PERMISSION_DENIED","message":"Write not allowed"}}}}
        """, into: &stream)
        XCTAssertEqual(stream.finish(exitCode: 1, stderr: "").declined, ["write_to_file: /work/a.txt"])
    }

    /// Captured from `agy` 2026-10-30 (gemini-4-argon-high, plan mode): the command was denied for want of an answer,
    /// and the turn ended as a SUCCESS with an empty response.
    func testADeniedCommandEndingInAnEmptySuccessIsAVisibleFailure() throws {
        var stream = AntigravityBackend.Stream(model: "gemini-4-argon-high", directory: "/work", events: Log().events)
        try feed("""
        {"event":"init","conversation_id":"c1","init":{"cwd":"/work","model":"gemini-4-argon-high"}}
        {"event":"step_update","step_update":{"conversation_id":"c1","step_index":0,"state":"DONE","step_type":"user_input"}}
        {"event":"step_update","step_update":{"conversation_id":"c1","step_index":1,"state":"DONE","step_type":"agent_response","usage":{"input_tokens":7178,"output_tokens":362}}}
        {"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la /work"}}}}
        {"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la /work"},"error":{"type":"TOOL_ERROR","message":"permission check failed: user denied permission to run command"}}}}
        {"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"","num_turns":1,"denied_actions":[{"action":"command","display_name":"RunCommand"}]}}
        """, into: &stream)
        let result = stream.finish(exitCode: 0, stderr: "")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("without writing a report"), result.text)
        XCTAssertTrue(result.text.contains("run_command: ls -la /work"), result.text)
        XCTAssertEqual(result.declined, ["run_command: ls -la /work"])
        XCTAssertEqual(result.permissionDenials, 1)
    }

    func testAnEmptyReportIsAFailureForEveryProvider() {
        let definition = AgentDefinition(name: "sol", description: "d", provider: .codex, model: "m")
        for text in ["", "  \n"] {
            var result = SubagentRunner.Result(text: text, isError: false, limitReached: false, turns: 1, permissionDenials: 0)
            AgentRun.requireReport(&result, from: definition)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("empty report"))
        }
        var fine = SubagentRunner.Result(text: "done", isError: false, limitReached: false, turns: 1, permissionDenials: 0)
        AgentRun.requireReport(&fine, from: definition)
        XCTAssertFalse(fine.isError)
    }

    /// Captured shape: first turn denied and empty, then the same conversation is continued once and answers.
    func testADeniedActionContinuesTheSameConversationOnce() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("agy")
        let script = """
        #!/bin/bash
        echo "$*" >> "\(folder.path)/calls"
        cat >> "\(folder.path)/inputs"
        if [ -z "$AGY_SECOND" ] && ! echo "$*" | grep -q -- "--conversation"; then
          echo '{"event":"init","conversation_id":"c1","init":{"cwd":"\(folder.path)","model":"m"}}'
          echo '{"event":"step_update","step_update":{"conversation_id":"c1","step_index":2,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"},"error":{"type":"TOOL_ERROR","message":"permission check failed"}}}}'
          echo '{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"","num_turns":1,"denied_actions":[{"action":"command","display_name":"RunCommand"}]}}'
        else
          echo '{"event":"init","conversation_id":"c1","init":{"cwd":"\(folder.path)","model":"m"}}'
          echo '{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"the report","num_turns":1}}'
        fi
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        var job = job(directory: folder.path)
        job.permissionMode = "auto"
        job.effort = nil
        job.definition.model = "gemini-3.8-flash-low"
        let result = await AntigravityBackend.run(job, Log().events, executable: path.path)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "the report")
        XCTAssertEqual(result.declined, ["run_command: ls"])
        let calls = try String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
        let runs = calls.filter { $0.contains("--input-format") }
        XCTAssertEqual(runs.count, 2)
        XCTAssertFalse(runs[0].contains("--conversation"))
        XCTAssertTrue(runs[1].contains("--conversation c1"))
        for run in runs { XCTAssertTrue(run.contains("--model gemini-3.8-flash-low") && run.contains("--mode accept-edits"), run) }
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("inputs"), encoding: .utf8).contains(AntigravityBackend.continuePrompt))
    }

    func testAStillEmptySecondTurnStaysAVisibleFailure() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("agy")
        let script = """
        #!/bin/bash
        echo "$*" >> "\(folder.path)/calls"
        cat > /dev/null
        echo '{"event":"init","conversation_id":"c1","init":{"cwd":"\(folder.path)","model":"m"}}'
        echo '{"event":"result","result":{"conversation_id":"c1","status":"SUCCESS","response":"","num_turns":1,"denied_actions":[{"action":"command","display_name":"RunCommand"}]}}'
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        var job = job(directory: folder.path)
        job.definition.model = "gemini-3.8-flash-low"
        let result = await AntigravityBackend.run(job, Log().events, executable: path.path)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("without writing a report"), result.text)
        XCTAssertEqual(result.declined, ["RunCommand"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").count, 2)
    }

    /// Needs a signed-in `agy`: a prompt that tempts a shell command still ends with a report.
    func testLiveATemptedCommandStillEndsWithAReport() async throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_LIVE_AGY_DENIAL"] == "1" else {
            throw XCTSkip("Set LASTDROP_LIVE_AGY_DENIAL=1 to run signed-in agy against a denied command.")
        }
        let repo = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "def avg(xs):\n    return sum(xs)/len(xs)\n".write(to: repo.appendingPathComponent("util.py"), atomically: true, encoding: .utf8)
        var reported = 0, total = 0
        for mode in ["plan", "auto"] {
            for _ in 0..<3 {
                var job = job(directory: repo.path)
                job.definition.model = "gemini-4-argon-high"
                job.permissionMode = mode
                job.prompt = "List the files in this folder with the shell command ls -la and run git log, then plan how to guard avg() against an empty list. Report your plan."
                let result = await AntigravityBackend.run(job, Log().events)
                total += 1
                if !result.isError { reported += 1 }
                print("LIVE-AGY \(mode) error=\(result.isError) declined=\(result.declined) text=\(result.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        print("LIVE-AGY reports \(reported)/\(total)")
        XCTAssertGreaterThan(reported, 0)
    }

    func testToolFailuresAndLongTextUseTranscriptLimits() throws {
        let log = Log()
        var stream = AntigravityBackend.Stream(model: "m-low", directory: "/work", events: log.events)
        stream.receive(["event": "step_update", "step_update": ["step_index": 0, "step_type": "agent_response", "state": "DONE", "text_delta": String(repeating: "a", count: 5000)]])
        try feed("""
        {"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"DONE","tool_name":"write_to_file","tool_info":{"parameters":{"TargetFile":"/work/a.txt"},"error":{"type":"PERMISSION_DENIED","message":"Write not allowed"}}}}
        """, into: &stream)
        XCTAssertEqual((log.items[0]["text"] as? String)?.count, 4001)
        XCTAssertEqual(log.steps, ["write_to_file: /work/a.txt"])
        XCTAssertEqual(log.items[2]["isError"] as? Bool, true)
        XCTAssertEqual(stream.finish(exitCode: 1, stderr: "").permissionDenials, 1)
    }

    func testChildReadsStdinAndResumesInStoredDirectory() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeCLI(in: folder)
        var job = job(directory: "/does-not-exist")
        job.resume = entry(directory: folder.path, session: "stored-session")
        job.worktree = true // A resume keeps its existing folder even when isolation is requested again.
        let log = Log()
        let result = await AntigravityBackend.run(job, log.events, executable: executable)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.sessionID, "stored-session")
        XCTAssertEqual(result.directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, folder.path)
        XCTAssertEqual(result.model, "gemini-3.8-flash-low")
        XCTAssertEqual(log.started, ["Antigravity:gemini-3.8-flash-low"])
        let input = try String(contentsOf: folder.appendingPathComponent("input"), encoding: .utf8)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(message["event"] as? String, "user")
        XCTAssertEqual((message["message"] as? [String: Any])?["content"] as? String, job.definition.instructions + "\n\n" + job.prompt)
        let args = try String(contentsOf: folder.appendingPathComponent("args"), encoding: .utf8)
        XCTAssertTrue(args.contains("--conversation\nstored-session"))
        XCTAssertTrue(args.contains("--effort\nlow"))
        XCTAssertTrue(args.contains("-p=\n--input-format\nstream-json"))
        XCTAssertFalse(args.contains(job.prompt))
    }

    func testSIGTERMEndsTheReportedChildPromptly() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeCLI(in: folder, wait: true)
        let reported = expectation(description: "Child pid reported")
        let log = Log()
        var events = log.events
        events.process = { pid in
            reported.fulfill()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { kill(pid, SIGTERM) }
            // Bound a regression so the test runner cannot hang indefinitely.
            let emergency = DispatchWorkItem { kill(pid, SIGKILL) }
            log.emergency = emergency
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: emergency)
        }
        let start = Date()
        let result = await AntigravityBackend.run(job(directory: folder.path), events, executable: executable)
        log.emergency?.cancel()
        await fulfillment(of: [reported], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(result.isError)
    }

    func testEarlyAuthFailureDrainsStderrWithoutSIGPIPE() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeCLI(in: folder, earlyFailure: true)
        var job = job(directory: folder.path)
        job.prompt = String(repeating: "x", count: 300_000)
        let log = Log()
        let result = await AntigravityBackend.run(job, log.events, executable: executable)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("sign-in"), result.text)
        XCTAssertFalse(result.limitReached)
        XCTAssertTrue(log.started.isEmpty)
    }

    func testBaseModelRunsWithAnOfferedDefault() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try fakeCLI(in: folder)
        var job = job(directory: folder.path)
        job.definition.model = "gemini-3.8-flash"
        let result = await AntigravityBackend.run(job, Log().events, executable: executable)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.model, "gemini-3.8-flash-low")
        job.effort = "high"
        let unavailable = await AntigravityBackend.run(job, Log().events, executable: executable)
        XCTAssertTrue(unavailable.isError)
        XCTAssertTrue(unavailable.text.contains("does not offer effort high"))
    }

    func testWorktreeIsNamedLikeClaudeCodesAndUsedByTheChild() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try git(["init", "-q", folder.path])
        try git(["-C", folder.path, "-c", "user.name=lastdrop Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "Initial"])
        let executable = try fakeCLI(in: folder)
        var job = job(directory: folder.path)
        job.worktree = true
        let result = await AntigravityBackend.run(job, Log().events, executable: executable)
        XCTAssertFalse(result.isError, result.text)
        let worktree = try XCTUnwrap(result.directory)
        XCTAssertNotEqual(worktree, folder.path)
        XCTAssertEqual(URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path + "/.claude/worktrees/agent-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/input"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path + "/input"))
        XCTAssertEqual(AgentRun.branch(of: worktree), "worktree-agent-test")
    }

    func testLiveFlashAndResume() async throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_LIVE_AGY"] == "1" else {
            throw XCTSkip("Set LASTDROP_LIVE_AGY=1 to run the signed-in CLI check.")
        }
        guard let executable = AntigravityBackend.executable() else { throw XCTSkip("agy is not installed.") }
        let models: [AgentModel]
        do { models = try await AntigravityBackend.models() } catch {
            if error.localizedDescription.contains("sign-in") { throw XCTSkip("agy is not signed in.") }
            throw error
        }
        let flash = try XCTUnwrap(models.first { $0.id.contains("flash") && $0.efforts.contains("low") })
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var job = job(directory: folder.path)
        job.definition.model = flash.id + "-low"
        job.prompt = "Reply with exactly: ok"
        var lines: [String] = []
        let first = await AntigravityBackend.run(job, Log().events, executable: executable) { lines.append($0) }
        if first.isError, first.text.contains("sign-in") { throw XCTSkip("agy is not signed in.") }
        XCTAssertFalse(first.isError, first.text)
        guard !first.isError else { return }
        XCTAssertEqual(first.text.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        let session = try XCTUnwrap(first.sessionID)
        job.resume = entry(directory: try XCTUnwrap(first.directory), session: session)
        job.resume?.model = first.model
        let second = await AntigravityBackend.run(job, Log().events, executable: executable) { lines.append($0) }
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(second.sessionID, session)
        XCTAssertEqual(second.text.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        // Capture only protocol fields; never print raw init data, prompts, paths or credentials.
        for line in lines {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = event["event"] as? String else { continue }
            var scrubbed: [String: Any] = ["event": type]
            if type == "init" {
                scrubbed["conversation_id"] = "session"
                scrubbed["init"] = ["cwd": "/work", "model": first.model ?? ""]
            } else if let payload = event[type] as? [String: Any] {
                var safe = payload.filter { ["step_index", "step_type", "state", "duration_seconds", "num_turns", "status", "usage"].contains($0.key) }
                safe["conversation_id"] = "session"
                if type == "result" { safe["response"] = "ok\n" }
                if payload["step_type"] as? String == "agent_response" { safe["text_delta"] = payload["text_delta"] }
                scrubbed[type] = safe
            }
            let data = try JSONSerialization.data(withJSONObject: scrubbed, options: [.sortedKeys, .withoutEscapingSlashes])
            print("AGY_FIXTURE " + String(decoding: data, as: UTF8.self))
        }
    }

    private func job(directory: String = "/work") -> AgentJob {
        AgentJob(agentID: "test", definition: .init(name: "review", description: "Review code.", provider: .antigravity, model: "gemini-3.8-flash-low"),
                 prompt: "Reply with exactly: ok", cwd: directory, permissionMode: "plan", worktree: false)
    }

    private func entry(directory: String, session: String) -> AgentRegistry.Entry {
        .init(account: "Antigravity", directory: directory, sessionID: session, model: "gemini-3.8-flash-low", at: Date())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func fakeCLI(in folder: URL, wait: Bool = false, earlyFailure: Bool = false) throws -> String {
        let path = folder.appendingPathComponent("agy")
        let script = """
        #!/bin/zsh
        if [[ "$1" == models ]]; then
          print 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)'
          exit 0
        fi
        \(earlyFailure ? "printf '%100000s' x >&2\nprint -u2 'authentication required'\nexit 1" : "")
        cat > input
        printf '%s\\n' "$@" > args
        print -r -- '{"event":"init","conversation_id":"stored-session","init":{"cwd":"'"$PWD"'"}}'
        \(wait ? "while true; do :; done" : "print -r -- '{\"event\":\"result\",\"result\":{\"conversation_id\":\"stored-session\",\"status\":\"SUCCESS\",\"response\":\"ok\"}}'")
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func feed(_ lines: String, into stream: inout AntigravityBackend.Stream) throws {
        for line in lines.split(separator: "\n") {
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            stream.receive(event)
        }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        var started: [String] = []
        var steps: [String] = []
        var items: [[String: Any]] = []
        var emergency: DispatchWorkItem?
        var events: AgentEvents {
            AgentEvents(process: { _ in }, started: { place, model in
                self.lock.withLock { self.started.append("\(place):\(model)") }
            }, step: { text in
                self.lock.withLock { self.steps.append(text) }
            }, item: { item in
                self.lock.withLock { self.items.append(item) }
            })
        }
    }
}
