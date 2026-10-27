import Foundation

/// Runs the official Antigravity CLI, leaving authentication and sessions with `agy`.
/// Stream fields: https://www.antigravity.google/docs/cli/headless/
/// Flags and effort: https://www.antigravity.google/docs/cli/reference/
enum AntigravityBackend: AgentBackend {
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> String? {
        let candidates = [home + "/.local/bin/agy"]
            + (environment["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }.map { $0 + "/agy" }
            + ["/opt/homebrew/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func models() async throws -> [AgentModel] {
        guard let executable = executable() else { throw Failure("Antigravity (`agy`) was not found on this Mac.") }
        return try await models(executable: executable)
    }

    private static func models(executable: String) async throws -> [AgentModel] {
        var output = ""
        let command = try await execute(executable, ["models"], directory: nil) { output += $0 + "\n" }
        guard command.status == 0 else { throw Failure(message(command.stderr.isEmpty ? output : command.stderr)) }
        let models = parseModels(output)
        guard !models.isEmpty else { throw Failure("Antigravity returned no models. Run `agy models` in Terminal to check access.") }
        return models
    }

    /// `agy models` has no JSON flag: each model is a tab-separated slug and display name.
    static func parseModels(_ text: String) -> [AgentModel] {
        var models: [AgentModel] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let slug = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let name = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, !name.isEmpty else { continue }
            let effort = suffix(slug)
            let base = effort.map { String(slug.dropLast($0.count + 1)) } ?? slug
            let label = effort.map { " (\($0.capitalized))" }
            let display = label.flatMap { name.hasSuffix($0) ? String(name.dropLast($0.count)) : nil } ?? name
            if let index = models.firstIndex(where: { $0.id == base }) {
                if let effort, !models[index].efforts.contains(effort) { models[index].efforts.append(effort) }
            } else {
                models.append(AgentModel(id: base, name: display, efforts: effort.map { [$0] } ?? [], defaultEffort: nil))
            }
        }
        for index in models.indices {
            models[index].efforts = efforts.filter { models[index].efforts.contains($0) }
            models[index].defaultEffort = models[index].efforts.contains("medium") ? "medium" : models[index].efforts.first
        }
        return models
    }

    private static func suffix(_ model: String) -> String? {
        efforts.first { model.hasSuffix("-" + $0) }
    }

    static func slug(model: String, effort: String?, models: [AgentModel]) throws -> String {
        if suffix(model) != nil { return model }
        guard let offered = models.first(where: { $0.id == model }) else {
            throw Failure("Antigravity does not offer model \(model). Run `agy models` to check access.")
        }
        guard !offered.efforts.isEmpty else {
            if let effort { throw Failure("Antigravity model \(model) does not offer effort \(effort).") }
            return model
        }
        let selected = effort ?? offered.defaultEffort ?? "medium"
        guard offered.efforts.contains(selected) else {
            throw Failure("Antigravity model \(model) does not offer effort \(selected) (available: \(offered.efforts.joined(separator: ", "))).")
        }
        return model + "-" + selected
    }

    /// Set the mode explicitly so a saved CLI preference cannot broaden the caller's permissions.
    static func arguments(_ job: AgentJob, slug: String) -> [String] {
        // `-p` takes a string, even before another flag. An empty value leaves prompts to stdin.
        var args = ["-p=", "--input-format", "stream-json", "--output-format", "stream-json", "--model", slug, "--disable-slash-commands"]
        // The documented flag overrides effort for this invocation without changing the CLI's settings.
        if let effort = suffix(slug) { args += ["--effort", effort] }
        switch job.permissionMode {
        case "bypassPermissions": args += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
        case "acceptEdits", "auto": args += ["--mode", "accept-edits"]
        default: args += ["--mode", "plan"]
        }
        if let resume = job.resume { args += ["--conversation", resume.sessionID] }
        return args
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        guard let executable = executable() else {
            return failure("Antigravity (`agy`) was not found on this Mac.", directory: job.cwd)
        }
        return await run(job, events, executable: executable)
    }

    /// The executable seam lets tests exercise pipes, resume and signals without a signed-in CLI.
    static func run(_ job: AgentJob, _ events: AgentEvents, executable: String,
                    onLine: (String) -> Void = { _ in }) async -> SubagentRunner.Result {
        var directory = job.resume?.directory ?? job.cwd
        do {
            let model = job.resume?.model ?? job.definition.model
            let offered = suffix(model) == nil ? try await models(executable: executable) : []
            let selected = try slug(model: model, effort: job.resume?.effort ?? job.effort, models: offered)
            if job.resume == nil, job.worktree { directory = try await worktree(in: directory) }
            var stream = Stream(model: selected, directory: directory, events: events)
            let prompt = job.definition.instructions + "\n\n" + job.prompt
            var input = try JSONSerialization.data(withJSONObject: ["event": "user", "message": ["content": prompt]])
            input.append(0x0A)
            let command = try await execute(executable, arguments(job, slug: selected), directory: directory,
                                            input: input, onProcess: events.process) { line in
                onLine(line)
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
                stream.receive(event)
            }
            return stream.finish(exitCode: command.status, stderr: command.stderr)
        } catch {
            return failure(error.localizedDescription, directory: directory)
        }
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? {
        guard !entry.sessionID.isEmpty else { return nil }
        return "cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1\nexec agy --conversation \(ClaudeSignIn.shellQuote(entry.sessionID))"
    }

    /// Kept under git's common directory so it survives a follow-up without dirtying the checkout.
    static func worktree(in directory: String) async throws -> String {
        var common = ""
        let lookup = try await execute("/usr/bin/git", ["-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                       directory: nil) { common += $0 }
        guard lookup.status == 0, !common.isEmpty else { throw Failure("Antigravity worktree: \(lookup.stderr)") }
        let parent = URL(fileURLWithPath: common).appendingPathComponent("headroom-worktrees")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(UUID().uuidString.lowercased()).path
        let added = try await execute("/usr/bin/git", ["-C", directory, "worktree", "add", "--detach", path, "HEAD"],
                                      directory: nil) { _ in }
        guard added.status == 0 else { throw Failure("Antigravity worktree: \(added.stderr)") }
        return path
    }

    private struct Command {
        var status: Int32
        var stderr: String
    }

    private static func execute(_ executable: String, _ arguments: [String], directory: String?, input: Data = Data(),
                                onProcess: (Int32) -> Void = { _ in }, onLine: (String) -> Void) async throws -> Command {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }
        var environment = ProcessInfo.processInfo.environment
        environment[AgentRun.nestedMarker] = "1"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // An early CLI failure must report EPIPE instead of ending Headroom with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        onProcess(process.processIdentifier)
        let errors = Task.detached {
            var tail = Data()
            while let data = try? stderr.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                tail.append(data)
                if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            }
            return String(decoding: tail, as: UTF8.self)
        }
        let writer = Task.detached {
            defer { try? stdin.fileHandleForWriting.close() }
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines { onLine(line) }
        } catch {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        await writer.value
        return Command(status: process.terminationStatus, stderr: await errors.value)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func message(_ text: String) -> String {
        let lower = text.lowercased()
        let detail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
        if lower.contains("authentication required") || lower.contains("not authenticated") || lower.contains("not signed in")
            || lower.contains("unauthenticated") || lower.contains("token expired") || lower.contains("not logged in")
            || lower.contains("please log in") || lower.contains("please sign in") || lower.contains("invalid_grant") {
            return "Antigravity needs sign-in. Open `agy` in Terminal and authenticate. \(detail)"
        }
        if modelUnavailable(text) { return "Antigravity cannot use this model on the current account. \(detail)" }
        return detail
    }

    static func modelUnavailable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("model") && ["not available", "not supported", "not found", "not recognized", "not entitled", "access denied", "permission_denied", "does not have access", "requires a"].contains { lower.contains($0) }
    }

    static func mentionsLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !modelUnavailable(text) && (lower.contains("resource_exhausted") || lower.contains("quota exhausted")
            || lower.contains("quota exceeded") || lower.contains("quota has been exhausted") || lower.contains("usage limit")
            || lower.contains("limit reached") || lower.contains("quota limit"))
    }

    private static func failure(_ text: String, directory: String) -> SubagentRunner.Result {
        .init(text: message(text), isError: true, limitReached: mentionsLimit(text), modelUnavailable: modelUnavailable(text),
              turns: 0, permissionDenials: 0, directory: directory, account: "Antigravity")
    }

    /// A turn's NDJSON state. DONE closes a step; the final result never duplicates its text item.
    struct Stream {
        var model: String
        var directory: String
        var events: AgentEvents
        private var sessionID: String?
        private var started = false
        private var invalidInit: String?
        private var final: [String: Any]?
        private var text: [Int: String] = [:]
        private var completed = Set<Int>()
        private var tools = Set<Int>()
        private var results = Set<Int>()
        private var permissionDenials = 0
        private var userTurns = 0
        private var turnUsage: [String: Double] = [:]

        init(model: String, directory: String, events: AgentEvents) {
            self.model = model
            self.directory = directory
            self.events = events
        }

        mutating func receive(_ event: [String: Any]) {
            switch event.string("event") {
            case "init":
                guard !started else { return }
                guard let id = event.string("conversation_id"), !id.isEmpty,
                      let cwd = event.dict("init")?.string("cwd"), !cwd.isEmpty else {
                    invalidInit = "Antigravity's init event has no conversation_id or cwd."
                    return
                }
                sessionID = id
                directory = cwd
                started = true
                events.started("Antigravity", model)
            case "step_update":
                guard let step = event.dict("step_update"), let index = step.double("step_index").map(Int.init), !completed.contains(index) else { return }
                let done = step.string("state") == "DONE"
                if done {
                    if step.string("step_type") == "user_input" { userTurns += 1 }
                    for key in ["input_tokens", "output_tokens", "cache_read_tokens"] {
                        if let count = step.dict("usage")?.double(key) { turnUsage[key, default: 0] += count }
                    }
                }
                if step.string("step_type") == "agent_response" {
                    text[index, default: ""] += step.string("text_delta") ?? ""
                    if done, let item = SubagentRunner.transcriptItem(["type": "text", "text": text.removeValue(forKey: index) ?? ""]) {
                        events.item(item)
                    }
                } else if step.string("step_type") == "tool", let info = step.dict("tool_info") {
                    let name = step.string("tool_name") ?? info.string("name") ?? "tool"
                    let id = "\(sessionID ?? step.string("conversation_id") ?? "agy"):\(index)"
                    if tools.insert(index).inserted {
                        let input = info.dict("parameters") ?? [:]
                        var item = SubagentRunner.transcriptItem(["type": "tool_use", "id": id, "name": name, "input": input])!
                        let summary = Self.summary(name, input)
                        item["summary"] = summary
                        events.step(summary)
                        events.item(item)
                    }
                    if done, results.insert(index).inserted {
                        let error = info["error"]
                        let failed = error != nil && !(error is NSNull)
                        let output = Self.render(info["output"])
                        let errorText = Self.render(error)
                        let resultText = [output, errorText].filter { !$0.isEmpty }.joined(separator: "\n")
                        if failed, errorText.lowercased().contains("permission") { permissionDenials += 1 }
                        if let item = SubagentRunner.transcriptItem(["type": "tool_result", "tool_use_id": id,
                                                                   "content": resultText, "is_error": failed]) { events.item(item) }
                    }
                }
                if done { completed.insert(index) }
            case "result": final = event.dict("result")
            default: break
            }
        }

        func finish(exitCode: Int32, stderr: String) -> SubagentRunner.Result {
            let reportedStatus = final?.string("status") ?? ""
            let status = reportedStatus.isEmpty ? "INCOMPLETE" : reportedStatus
            let error = Self.render(final?["error"])
            let response = final?.string("response") ?? ""
            let failed = status != "SUCCESS" || exitCode != 0 || !started || invalidInit != nil
            let details = [error, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            let diagnostic = details.isEmpty ? "Antigravity ended with status \(status). \(response)" : details
            let usage = final?.dict("usage")
            // Resumed result counters include previous turns; step usage covers only this invocation.
            let input = turnUsage["input_tokens"] ?? usage?.double("input_tokens") ?? 0
            let cached = turnUsage["cache_read_tokens"] ?? usage?.double("cache_read_tokens") ?? 0
            let output = turnUsage["output_tokens"] ?? usage?.double("output_tokens") ?? 0
            return .init(text: failed ? message(invalidInit ?? diagnostic) : response, isError: failed,
                         limitReached: failed && mentionsLimit(status + " " + diagnostic),
                         modelUnavailable: failed && modelUnavailable(diagnostic),
                         turns: userTurns > 0 ? userTurns : Int(final?.double("num_turns") ?? 0),
                         permissionDenials: permissionDenials, toolUses: tools.count,
                         durationMs: Int((final?.double("duration_seconds") ?? 0) * 1000),
                         inputTokens: Int(input + cached), outputTokens: Int(output),
                         model: model, sessionID: sessionID ?? final?.string("conversation_id"), directory: directory, account: "Antigravity")
        }

        private static func render(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            if let string = value as? String { return string }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        private static func summary(_ tool: String, _ input: [String: Any]) -> String {
            let detail = ["CommandLine", "TargetFile", "AbsolutePath", "SearchPath", "SearchDirectory", "Query", "Url", "Description", "command", "file_path", "query", "url"]
                .compactMap { input.string($0) }.first
            guard let detail else { return tool }
            return String((tool + ": " + detail.replacingOccurrences(of: "\n", with: " ")).prefix(100))
        }
    }
}
