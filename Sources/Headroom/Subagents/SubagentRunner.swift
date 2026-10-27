import Foundation

/// Runs one subagent turn as a headless Claude Code process (`claude -p`) on a given account.
enum SubagentRunner {
    struct Request: Equatable {
        var prompt: String
        var subagentType: String?
        var model: String?
        var effort: String?
        var worktree = false
        /// Continue this Claude Code session instead of starting one.
        var resume: String?
    }

    struct Result: Equatable {
        var text: String
        var sessionID: String?
        var isError: Bool
        /// Anthropic refused for usage limits; nothing to gain from retrying on the same account.
        var limitReached: Bool
        /// The account's plan doesn't include the model ("Fable 5.1 requires usage credits"); another model works.
        var modelUnavailable = false
        var turns: Int
        var permissionDenials: Int
    }

    /// `claude -p` reads the prompt from stdin, so its length never meets the argument limit.
    static func arguments(_ request: Request) -> [String] {
        var args = ["-p", "--output-format", "json", "--permission-mode", "auto"]
        if let resume = request.resume { args += ["--resume", resume] }
        // "general-purpose" is the plain session; any other type is an agent Claude Code knows
        // (Explore, Plan, or one from ~/.claude/agents, which every account's folder links to).
        if let type = request.subagentType, !type.isEmpty, type != "general-purpose" { args += ["--agent", type] }
        if let model = request.model, !model.isEmpty { args += ["--model", model] }
        if let effort = request.effort, !effort.isEmpty { args += ["--effort", effort] }
        if request.worktree { args.append("--worktree") }
        return args
    }

    /// The calling session's environment, minus everything that ties it to that session and account.
    static func environment(for account: ClaudeAccount, from base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in
            !(key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_") || key == "CLAUDECODE"
              || key == "CLAUDE_CONFIG_DIR" || key == "CLAUDE_EFFORT" || key == "CLAUDE_PID" || key == "ANTHROPIC_BASE_URL")
        }
        if let dir = account.cliConfigDir { env["CLAUDE_CONFIG_DIR"] = dir }
        env[SubagentServer.nestedMarker] = "1"
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

    /// Runs to completion. `onStart` hands back the process so the caller can stop it.
    static func run(_ request: Request, on account: ClaudeAccount, in directory: String,
                    onStart: @Sendable (Process) -> Void = { _ in }) async -> Result {
        guard let claude = executable() else {
            return Result(text: "Claude Code (`claude`) was not found on this Mac.", sessionID: nil, isError: true,
                          limitReached: false, turns: 0, permissionDenials: 0)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments(request)
        process.environment = environment(for: account, from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (out, err): (Data, Data) = await withCheckedContinuation { cont in
            // Read both pipes while the process runs, so a large answer can't fill a pipe and stall it.
            let group = DispatchGroup()
            var outData = Data(), errData = Data()
            group.enter()
            DispatchQueue.global().async { outData = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            do {
                try process.run()
            } catch {
                cont.resume(returning: (Data(), Data(error.localizedDescription.utf8)))
                return
            }
            onStart(process)
            stdin.fileHandleForWriting.write(Data(request.prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            group.notify(queue: .global()) {
                process.waitUntilExit()
                cont.resume(returning: (outData, errData))
            }
        }
        return parse(out, stderr: String(decoding: err, as: UTF8.self))
    }

    /// Claude Code's `--output-format json` result object.
    static func parse(_ data: Data, stderr: String) -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(text: message.isEmpty ? "The subagent stopped without an answer." : String(message.suffix(2000)),
                          sessionID: nil, isError: true, limitReached: Self.mentionsLimit(message), turns: 0, permissionDenials: 0)
        }
        let text = root.string("result") ?? ""
        let isError = root["is_error"] as? Bool ?? false
        let status = root.double("api_error_status").map(Int.init)
        let modelUnavailable = isError && Self.modelUnavailable(text)
        return Result(text: text, sessionID: root.string("session_id"), isError: isError,
                      limitReached: isError && !modelUnavailable && (status == 429 || mentionsLimit(text)),
                      modelUnavailable: modelUnavailable,
                      turns: Int(root.double("num_turns") ?? 0),
                      permissionDenials: (root["permission_denials"] as? [Any])?.count ?? 0)
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("switch to another model") || t.contains("requires usage credits") || t.contains("not available on your plan")
    }

    /// What a subagent falls back to when the account's plan lacks the model asked for: every paid plan has it.
    static let fallbackModel = "sonnet"

    static func mentionsLimit(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("usage limit") || t.contains("limit reached") || t.contains("rate limit") || t.contains("hit your limit")
    }
}
