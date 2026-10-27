import Foundation

/// `Headroom --mcp`: an MCP server (stdio) whose `Agent` and `SendMessage` tools work like Claude Code's
/// built-in ones, except that each subagent runs as plain Claude Code on another of your Claude accounts,
/// one with room left under its limits. When no account has room, `Agent` says so in one line and Claude
/// carries on with its built-in subagents.
final class SubagentServer: @unchecked Sendable {
    /// Set in a subagent's environment, so a subagent never starts subagents on yet another account.
    static let nestedMarker = "HEADROOM_SUBAGENT"
    static let noRoom = "No other Claude account has room right now. Use built-in subagents."

    static let instructions = """
        Headroom runs subagents on your other Claude accounts, the ones with spare usage limits. Its Agent and \
        SendMessage tools take the same parameters and return the same kind of result as the built-in ones. \
        Whenever you would start a subagent, use this server's Agent tool instead of the built-in one; continue \
        such an agent with this server's SendMessage. The subagent starts fresh, without this conversation, \
        exactly like a built-in subagent, so give it a complete brief. It runs in auto permission mode and can't \
        ask questions. Several calls in one message run in parallel. If Agent answers "\(noRoom)", use the \
        built-in Agent tool for the rest of this session.
        """

    private let lock = NSLock()
    /// Where responses go: stdout, one JSON message per line. Replaced in tests.
    var output: @Sendable (Data) -> Void = { FileHandle.standardOutput.write($0) }
    private var running: [String: Process] = [:]      // MCP request id → subagent process
    private var active: [String: Int] = [:]           // account id → subagents running on it
    private var lacksDefaultModel: Set<String> = []   // accounts whose plan doesn't include the default model

    static func run() -> Never {
        let server = SubagentServer()
        Task.detached { await server.serve() }
        dispatchMain()
    }

    private func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                Task { await self.handle(message) }
            }
        } catch {}
        exit(0)   // the client closed stdin
    }

    // MARK: JSON-RPC

    func handle(_ message: [String: Any]) async {
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            respond(id, [
                "protocolVersion": params.string("protocolVersion") ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "headroom", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": Self.instructions,
            ])
        case "tools/list":
            respond(id, ["tools": Self.tools])
        case "tools/call":
            let (text, isError) = await call(params.string("name") ?? "", params.dict("arguments") ?? [:], requestID: key(id))
            respond(id, ["content": [["type": "text", "text": text]], "isError": isError])
        case "notifications/cancelled":
            let process = lock.withLock { running[key(params["requestId"])] }
            process?.terminate()
        case "ping":
            respond(id, [:])
        default:
            if id != nil { send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found"]]) }
        }
    }

    private func key(_ id: Any?) -> String { id.map { "\($0)" } ?? "" }

    private func respond(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.withLock { output(data) }
    }

    // MARK: Tools

    /// The built-in tools' parameters, described for this server.
    static let tools: [[String: Any]] = [
        [
            "name": "Agent",
            "description": """
                Launch a new agent to handle a task autonomously, on another of your Claude accounts that has \
                usage left. Same parameters and result as the built-in Agent tool. The agent starts fresh, with \
                no access to this conversation, so the prompt must be a complete, self-contained brief. It works \
                in the current folder, in auto permission mode, and can't ask questions. Returns the agent's \
                final answer and its agentId, which SendMessage takes to continue it. When no account has \
                room, returns "\(noRoom)"
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "description": ["type": "string", "description": "A short (3-5 word) description of the task"],
                    "prompt": ["type": "string", "description": "The task for the agent to perform"],
                    "subagent_type": ["type": "string", "description": "The type of agent to use (Explore, Plan, general-purpose, or one from ~/.claude/agents)"],
                    "model": ["type": "string", "enum": ["sonnet", "opus", "haiku", "fable"], "description": "Optional model override"],
                    "effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh", "max"], "description": "Optional reasoning effort"],
                    "isolation": ["type": "string", "enum": ["worktree"], "description": "\"worktree\" gives the agent its own git worktree"],
                ],
                "required": ["description", "prompt"],
            ],
        ],
        [
            "name": "SendMessage",
            "description": "Send a follow-up message to an agent this server started, by its agentId. It continues where it left off, on the same account, and returns its answer.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "The agentId returned by Agent"],
                    "message": ["type": "string", "description": "The message for the agent"],
                    "summary": ["type": "string", "description": "A 5-10 word label for this message"],
                ],
                "required": ["to", "message"],
            ],
        ],
    ]

    private func call(_ name: String, _ args: [String: Any], requestID: String) async -> (String, Bool) {
        if ProcessInfo.processInfo.environment[Self.nestedMarker] != nil {
            Self.log("called from a subagent; not nesting")
            return (Self.noRoom, true)
        }
        let directory = FileManager.default.currentDirectoryPath
        switch name {
        case "Agent":
            guard let prompt = args.string("prompt"), !prompt.isEmpty else { return ("Agent needs a prompt.", true) }
            let request = SubagentRunner.Request(prompt: prompt, subagentType: args.string("subagent_type"),
                                                 model: args.string("model"), effort: args.string("effort"),
                                                 worktree: args.string("isolation") == "worktree")
            return await start(request, in: directory, requestID: requestID)
        case "SendMessage":
            guard let to = args.string("to"), let text = args.string("message") else { return ("SendMessage needs to and message.", true) }
            guard let entry = SubagentRegistry.lookup(to),
                  let account = ClaudeAccountsConfig.load().ordered.first(where: { $0.id == entry.account }) else {
                return ("No agent \(to) was started by this server. Use the built-in SendMessage for built-in agents.", true)
            }
            let result = await runTracked(SubagentRunner.Request(prompt: text, resume: to), on: account,
                                          in: entry.directory, requestID: requestID)
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            return (format(result, account: account.id), result.isError)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Picks an account and runs; if Anthropic refuses on the first turn for limits, tries the next one.
    private func start(_ request: SubagentRunner.Request, in directory: String, requestID: String) async -> (String, Bool) {
        let config = ClaudeAccountsConfig.load()
        let own = SubagentAccounts.ownAccountUUID()
        var tried = Set<String>()
        for _ in 0..<3 {
            var candidates: [SubagentAccounts.Candidate] = []
            for account in config.ordered where !tried.contains(account.id) {
                let signedIn = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).uuid
                guard let signedIn, signedIn != own else { continue }
                let usage = await SubagentUsage.shared.usage(account)
                candidates.append(.init(account: account, name: account.id, sessionUsed: usage.session, weeklyUsed: usage.weekly,
                                        active: lock.withLock { active[account.id] ?? 0 }))
            }
            let choice = SubagentAccounts.pick(candidates, sessionThreshold: config.sessionThreshold,
                                               weeklyThreshold: config.weeklyThreshold)
            Self.log("own \(own?.prefix(8) ?? "?"); " + candidates.map { c in
                "\(c.name) session \(c.sessionUsed.map { "\(Int($0))%" } ?? "?") weekly \(c.weeklyUsed.map { "\(Int($0))%" } ?? "?")"
            }.joined(separator: ", ") + " → \(choice?.name ?? "none")")
            guard let choice else { return (Self.noRoom, true) }
            var request = request
            let knownLacking = request.model == nil && lock.withLock { lacksDefaultModel.contains(choice.account.id) }
            if knownLacking { request.model = SubagentRunner.fallbackModel }
            var result = await runTracked(request, on: choice.account, in: directory, requestID: requestID)
            if result.isError { Self.log("\(choice.name) failed after \(result.turns) turns: \(result.text.prefix(300))") }
            // Plans differ in models (Pro has no Fable): run it again on the same account with one it has.
            if result.modelUnavailable, request.model != SubagentRunner.fallbackModel {
                if request.model == nil { lock.withLock { _ = lacksDefaultModel.insert(choice.account.id) } }
                var retry = request
                retry.model = SubagentRunner.fallbackModel
                result = await runTracked(retry, on: choice.account, in: directory, requestID: requestID)
                if !result.isError {
                    result.text = "(Ran with Sonnet: the \(choice.name) plan doesn't include \(request.model ?? "the default model").)\n\n" + result.text
                }
            }
            if result.limitReached {
                await SubagentUsage.shared.markFull(choice.account)
                tried.insert(choice.account.id)
                if result.turns <= 1 { continue }   // nothing done yet: another account can take it whole
            }
            if knownLacking, !result.isError {
                result.text = "(Ran with Sonnet: the \(choice.name) plan doesn't include the default model.)\n\n" + result.text
            }
            if let id = result.sessionID { SubagentRegistry.remember(id, account: choice.account.id, directory: directory) }
            return (format(result, account: choice.account.id), result.isError)
        }
        return (Self.noRoom, true)
    }

    private func runTracked(_ request: SubagentRunner.Request, on account: ClaudeAccount, in directory: String,
                            requestID: String) async -> SubagentRunner.Result {
        lock.withLock { active[account.id, default: 0] += 1 }
        defer { lock.withLock { active[account.id, default: 1] -= 1; running[requestID] = nil } }
        return await SubagentRunner.run(request, on: account, in: directory) { [weak self] process in
            self?.lock.withLock { self?.running[requestID] = process }
        }
    }

    /// One line per decision in ~/Library/Logs/Headroom/subagents.log, to see why an account was or wasn't used.
    static func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Headroom/subagents.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }

    /// The agent's answer, then where it ran and how to continue it, as the built-in tool ends its result.
    func format(_ result: SubagentRunner.Result, account: String) -> String {
        var text = result.text.isEmpty ? "(The agent returned no text.)" : result.text
        if result.limitReached { text += "\n\nThe \(account) account reached its usage limit. \(Self.noRoom)" }
        if result.permissionDenials > 0 {
            text += "\n\nAuto mode denied \(result.permissionDenials) action\(result.permissionDenials == 1 ? "" : "s") the agent tried."
        }
        if let id = result.sessionID {
            text += "\n\nagentId: \(id) (ran on the \(account) account; use SendMessage with this agentId to continue this agent)"
        }
        return text
    }
}

/// Which account and folder each agent ran in, so SendMessage resumes it there.
enum SubagentRegistry {
    struct Entry: Codable { var account: String; var directory: String; var at: Date }
    private static let lock = NSLock()

    static func remember(_ id: String, account: String, directory: String) {
        lock.withLock {
            var all = load()
            all[id] = Entry(account: account, directory: directory, at: Date())
            if all.count > 500 {
                all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value.at > $1.value.at }.prefix(400).map { ($0.key, $0.value) })
            }
            HeadroomPaths.ensure(HeadroomPaths.support)
            try? JSONEncoder.headroom.encode(all).write(to: HeadroomPaths.agents, options: .atomic)
        }
    }

    static func lookup(_ id: String) -> Entry? { lock.withLock { load()[id] } }

    private static func load() -> [String: Entry] {
        (try? Data(contentsOf: HeadroomPaths.agents)).flatMap { try? JSONDecoder.headroom.decode([String: Entry].self, from: $0) } ?? [:]
    }
}
