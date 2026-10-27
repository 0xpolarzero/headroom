import Foundation

/// Runs one subagent turn as a headless Claude Code process (`claude -p`) on a given account, reading its
/// stream-json output as it comes.
enum SubagentRunner {
    struct Request: Equatable {
        var prompt: String
        var subagentType: String?
        var model: String?
        var effort: String?
        var worktree = false
        var permissionMode = "auto"
        /// The Claude Code session to start (`--session-id`), or to continue when `resume` is set.
        var sessionID: String
        var resume = false
        /// A `--mcp-config` file with the caller's own MCP servers.
        var mcpConfig: String?
    }

    struct Result: Equatable {
        var text: String
        var isError: Bool
        /// Anthropic refused for usage limits; nothing to gain from retrying on the same account.
        var limitReached: Bool
        /// The account's plan doesn't include the model ("Fable 5.1 requires usage credits"); another model works.
        var modelUnavailable = false
        var turns: Int
        var permissionDenials: Int
        var toolUses = 0
        var durationMs = 0
        var inputTokens = 0
        var outputTokens = 0
        var model: String?
        /// The session it ran as: a ready process comes with its own.
        var sessionID: String?
    }

    /// What a subagent falls back to when the account's plan lacks the model asked for: every paid plan has it.
    static let fallbackModel = "sonnet"

    /// `claude -p` reads the prompt from stdin, so its length never meets the argument limit.
    static func arguments(_ request: Request) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", request.permissionMode]
        args += request.resume ? ["--resume", request.sessionID] : ["--session-id", request.sessionID]
        // "general-purpose" is the plain session; any other type is an agent Claude Code knows
        // (Explore, Plan, or one from ~/.claude/agents, which every account's folder links to).
        if let type = request.subagentType, !type.isEmpty, type != "general-purpose" { args += ["--agent", type] }
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, !effort.isEmpty { args += ["--effort", effort] }
        if request.worktree { args.append("--worktree") }
        if let mcp = request.mcpConfig { args += ["--mcp-config", mcp] }
        return args
    }

    /// What a ready process must have been started with to take this run; nil for a follow-up.
    static func warmSpec(_ request: Request, on account: ClaudeAccount, in directory: String,
                         environment base: [String: String]) -> WarmPool.Spec? {
        guard !request.resume else { return nil }
        var args = arguments(request)
        if let i = args.firstIndex(of: "--session-id") { args.removeSubrange(i...i + 1) }
        return WarmPool.Spec(account: account.id, directory: directory, arguments: args,
                             environment: environment(for: account, from: base))
    }

    /// The calling session's environment, minus everything that ties it to that session and account.
    static func environment(for account: ClaudeAccount, from base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in
            !(key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_") || key == "CLAUDECODE"
              || key == "CLAUDE_CONFIG_DIR" || key == "CLAUDE_EFFORT" || key == "CLAUDE_PID" || key == "ANTHROPIC_BASE_URL")
        }
        if let dir = account.cliConfigDir { env["CLAUDE_CONFIG_DIR"] = dir }
        env[AgentRun.nestedMarker] = "1"
        return env
    }

    /// The native install first (it updates itself), then the `claude` on PATH.
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        var candidates = [NSHomeDirectory() + "/.local/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        if let exec = environment["CLAUDE_CODE_EXECPATH"] { candidates.append(exec) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The caller's MCP servers for `--mcp-config`: its user servers and the ones it set for this folder,
    /// from `~/.claude.json` (an account's own folder has neither). Headroom's own entry is left out.
    static func mcpConfig(from claudeJSON: [String: Any], directory: String) -> [String: Any]? {
        var servers = claudeJSON.dict("mcpServers") ?? [:]
        for (key, value) in claudeJSON.dict("projects")?.dict(directory)?.dict("mcpServers") ?? [:] { servers[key] = value }
        servers["headroom"] = nil
        return servers.isEmpty ? nil : ["mcpServers": servers]
    }

    /// Runs to completion, calling `onStep` for each step the agent takes ("Read: note.txt").
    static func run(_ request: Request, on account: ClaudeAccount, in directory: String,
                    onStep: @escaping @Sendable (String) -> Void,
                    onItem: @escaping @Sendable ([String: Any]) -> Void = { _ in }) async -> Result {
        let base = ProcessInfo.processInfo.environment
        let output: FileHandle, errors: FileHandle
        var process: Process?
        var sessionID = request.sessionID
        if let spec = warmSpec(request, on: account, in: directory, environment: base), let ready = WarmPool.claim(spec) {
            // Already started: it only needs the prompt.
            sessionID = ready.sessionID
            ready.input.write(WarmPool.userMessage(request.prompt))
            try? ready.input.close()
            output = ready.output
            errors = ready.errors
        } else {
            guard let claude = executable() else {
                return Result(text: "Claude Code (`claude`) was not found on this Mac.", isError: true, limitReached: false,
                              turns: 0, permissionDenials: 0)
            }
            let started = Process()
            started.executableURL = URL(fileURLWithPath: claude)
            started.arguments = arguments(request)
            started.environment = environment(for: account, from: base)
            started.currentDirectoryURL = URL(fileURLWithPath: directory)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            started.standardInput = stdin
            started.standardOutput = stdout
            started.standardError = stderr
            do { try started.run() } catch {
                return Result(text: error.localizedDescription, isError: true, limitReached: false, turns: 0, permissionDenials: 0)
            }
            stdin.fileHandleForWriting.write(Data(request.prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            output = stdout.fileHandleForReading
            errors = stderr.fileHandleForReading
            process = started
        }
        let errText = Task.detached { String(decoding: errors.readDataToEndOfFile(), as: UTF8.self) }

        var final: [String: Any]?
        var toolUses = 0
        do {
            for try await line in output.bytes.lines {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                switch event.string("type") {
                case "assistant":
                    for block in event.dict("message")?.array("content") ?? [] {
                        if block.string("type") == "tool_use" {
                            toolUses += 1
                            onStep(describe(tool: block.string("name") ?? "tool", input: block.dict("input") ?? [:]))
                        }
                        if let item = transcriptItem(block) { onItem(item) }
                    }
                case "user":
                    for block in event.dict("message")?.array("content") ?? [] {
                        if let item = transcriptItem(block) { onItem(item) }
                    }
                case "result":
                    final = event
                default:
                    break
                }
            }
        } catch {}
        process?.waitUntilExit()
        let stderrText = await errText.value
        guard let final else {
            let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(text: message.isEmpty ? "The subagent stopped without an answer." : String(message.suffix(2000)),
                          isError: true, limitReached: mentionsLimit(message), turns: 0, permissionDenials: 0, sessionID: sessionID)
        }
        var result = parse(final)
        result.toolUses = toolUses
        result.sessionID = sessionID
        return result
    }

    /// One entry of the agent's transcript, as its row in the session shows it: what it said, each tool call
    /// with its input, each result. Long texts are cut; the whole session stays in the account's folder.
    static func transcriptItem(_ block: [String: Any]) -> [String: Any]? {
        func cut(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        switch block.string("type") {
        case "text":
            guard let text = block.string("text"), !text.isEmpty else { return nil }
            return ["kind": "text", "text": cut(text, 4000)]
        case "tool_use":
            let input = block.dict("input") ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return ["kind": "tool", "id": block.string("id") ?? "", "summary": describe(tool: block.string("name") ?? "tool", input: input),
                    "input": cut(json, 2000)]
        case "tool_result":
            let text: String
            if let s = block["content"] as? String { text = s }
            else { text = (block.array("content") ?? []).compactMap { $0.string("text") }.joined(separator: "\n") }
            return ["kind": "result", "id": block.string("tool_use_id") ?? "", "text": cut(text, 2000),
                    "isError": block["is_error"] as? Bool ?? false]
        default:
            return nil
        }
    }

    /// Claude Code's result event (`--output-format json`, or the last stream-json line).
    static func parse(_ root: [String: Any]) -> Result {
        let text = root.string("result") ?? ""
        let isError = root["is_error"] as? Bool ?? false
        let status = root.double("api_error_status").map(Int.init)
        let modelUnavailable = isError && Self.modelUnavailable(text)
        let usage = root.dict("usage")
        return Result(text: text, isError: isError,
                      limitReached: isError && !modelUnavailable && (status == 429 || mentionsLimit(text)),
                      modelUnavailable: modelUnavailable,
                      turns: Int(root.double("num_turns") ?? 0),
                      permissionDenials: (root["permission_denials"] as? [Any])?.count ?? 0,
                      durationMs: Int(root.double("duration_ms") ?? 0),
                      inputTokens: Int((usage?.double("input_tokens") ?? 0) + (usage?.double("cache_read_input_tokens") ?? 0)
                                       + (usage?.double("cache_creation_input_tokens") ?? 0)),
                      outputTokens: Int(usage?.double("output_tokens") ?? 0),
                      model: root.dict("modelUsage")?.keys.sorted().first)
    }

    static func mentionsLimit(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("usage limit") || t.contains("limit reached") || t.contains("rate limit") || t.contains("hit your limit")
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("switch to another model") || t.contains("requires usage credits") || t.contains("not available on your plan")
    }

    /// One short line for a step, as a built-in agent's progress reads: "Read: note.txt", "Bash: Run the tests".
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String? { input.string(key).map { ($0 as NSString).lastPathComponent } }
        let detail: String?
        switch tool {
        case "Read", "Edit", "Write", "NotebookEdit": detail = file("file_path") ?? file("notebook_path")
        case "Bash": detail = input.string("description") ?? input.string("command")
        case "Grep", "Glob": detail = input.string("pattern")
        case "WebFetch": detail = input.string("url")
        case "WebSearch": detail = input.string("query")
        case "Agent", "Task": detail = input.string("description")
        default: detail = nil
        }
        guard let detail, !detail.isEmpty else { return tool }
        let line = detail.replacingOccurrences(of: "\n", with: " ")
        return line.count > 80 ? "\(tool): \(line.prefix(79))…" : "\(tool): \(line)"
    }
}
