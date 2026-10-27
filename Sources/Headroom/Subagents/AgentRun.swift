import CryptoKit
import Foundation

/// `Headroom --agent-run`: one subagent for Headroom's Claude Code plugin, which answers the built-in Agent
/// tool with it. Reads a JSON request on stdin and writes JSON lines on stdout:
///
/// - `{"type":"no_room"}`: no other account has room; the plugin lets the built-in subagent run.
/// - `{"type":"error","text"}`: it couldn't start, for a reason that needs fixing (no fallback hides it).
/// - `{"type":"started","agentId","account","model","outputFile"}`: Claude Code started as expected and
///   is running, the agent's id fixed.
/// - `{"type":"step","text"}`: a step the agent took ("Read: note.txt").
/// - `{"type":"moved","account","reason"}`: the account refused before any work; another took over.
/// - `{"type":"result","text","isError",...}`: its final answer; `stopped` when TaskStop ended it.
enum AgentRun {
    /// Set in a subagent's environment: a subagent never starts subagents on yet another account.
    static let nestedMarker = "HEADROOM_SUBAGENT"

    struct Request: Decodable {
        var prompt: String
        var description: String?
        var subagentType: String?
        var model: String?
        var effort: String?
        var isolation: String?
        var cwd: String
        var permissionMode: String?
        /// The calling session's model, which a subagent inherits unless the call names one.
        var parentModel: String?
        /// An agent this runner started earlier: continue it (SendMessage) on its account.
        var resume: String?
        /// An agent type from Headroom's list (`headroom:codex-deep`): it runs on its own provider, never elsewhere.
        var agent: String?
        /// The engine's final background decision and whether its host keeps an interactive prompt.
        var background: Bool?
        var interactive: Bool?

        var backgroundError: String? {
            guard background == true, interactive != true else { return nil }
            return "Headroom cannot run a background agent in a non-interactive session: Claude Code does not wait for its report when input ends. Run this Agent in the foreground (run_in_background: false, and remove background: true from its definition), or use an interactive Claude Code session."
        }
    }

    static func main() -> Never {
        stopOnSignal()
        Task.detached {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let request = try? JSONDecoder().decode(Request.self, from: input) else {
                emit(["type": "result", "text": "Headroom couldn't read the subagent request.", "isError": true])
                exit(1)
            }
            await run(request)
            AgentRegistry.setRunning(nil)
            exit(0)
        }
        dispatchMain()
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// The plugin ends a run nobody waits for any more (the person interrupted a foreground agent) by ending
    /// this process: the Claude Code it started ends with it.
    private static func stopOnSignal() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                var children = [pid_t](repeating: 0, count: 64)
                let count = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.size))
                for pid in children.prefix(Int(max(0, min(count, Int32(children.count))))) where pid > 0 { kill(pid, SIGTERM) }
                AgentRegistry.setRunning(nil)
                exit(1)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// `Headroom --agent-warm`: the plugin's heads-up when a prompt is sent, with the same request an Agent
    /// call would make. The app starts a process for it on the account a run would pick, unless one is ready.
    static func warmMain() -> Never {
        Task.detached {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            if let request = try? JSONDecoder().decode(Request.self, from: input),
               ProcessInfo.processInfo.environment[nestedMarker] == nil {
                await warm(request)
            }
            exit(0)
        }
        dispatchMain()
    }

    static func warm(_ request: Request) async {
        let config = ClaudeAccountsConfig.load()
        guard let account = await pick(config.ordered, config: config, own: SubagentAccounts.ownAccountUUID(), excluding: [], log: false)
        else { return }
        var model = request.model ?? request.parentModel
        if let m = model, AgentRegistry.lacksModel(account.id, m) { model = SubagentRunner.fallbackModel }
        let req = SubagentRunner.Request(prompt: "", subagentType: request.subagentType, model: model, effort: request.effort,
                                         permissionMode: mappedPermissionMode(request.permissionMode), sessionID: "",
                                         mcpConfig: writeMCPConfig(directory: request.cwd))
        guard let spec = SubagentRunner.warmSpec(req, on: account, in: request.cwd, environment: ProcessInfo.processInfo.environment)
        else { return }
        WarmPool.warm(spec)
    }

    static func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func run(_ request: Request) async {
        // Owned agents and follow-ups never fall back. Reject before starting their provider or session.
        if request.agent != nil || request.resume != nil, let error = request.backgroundError {
            emit(["type": "error", "text": error])
            return
        }
        let config = ClaudeAccountsConfig.load()
        let accounts = config.ordered
        let mcpConfig = writeMCPConfig(directory: request.cwd)
        let permissionMode = mappedPermissionMode(request.permissionMode)

        // A follow-up goes back to the account, session, folder and agent type the agent ran with.
        if let agentID = request.resume, let entry = AgentRegistry.lookup(agentID), let definition = entry.definition {
            return await runDefined(definition, request, agentID: agentID, resume: entry, mcpConfig: mcpConfig)
        }
        if let type = request.agent {
            guard ProcessInfo.processInfo.environment[nestedMarker] == nil else {
                emit(["type": "error", "text": "An agent Headroom runs can't start Headroom's agents (\(type))."])
                return
            }
            guard let definition = AgentCatalog.load().agent(type) else {
                emit(["type": "error", "text": "No agent \(type) is enabled in Headroom (Settings → Agents)."])
                return
            }
            return await runDefined(definition, request, agentID: UUID().uuidString.lowercased(), resume: nil, mcpConfig: mcpConfig)
        }
        if let agentID = request.resume {
            guard let entry = AgentRegistry.lookup(agentID), let account = accounts.first(where: { $0.id == entry.account }) else {
                emit(["type": "error", "text": "No agent \(agentID) was started by Headroom."])
                return
            }
            let launch = Launch()
            AgentRegistry.setRunning(account.id)
            let req = SubagentRunner.Request(prompt: request.prompt, subagentType: entry.subagentType, model: entry.model,
                                             effort: entry.effort, permissionMode: permissionMode, sessionID: entry.sessionID,
                                             resume: true, mcpConfig: mcpConfig)
            let result = await SubagentRunner.run(req, on: account, in: entry.directory,
                                                  onProcess: { AgentRegistry.setProcess(agentID, claude: $0) },
                                                  check: launch.check(subagentType: entry.subagentType, account: account.id) {
                emit(["type": "started", "agentId": agentID, "account": account.id, "model": entry.model ?? "", "outputFile": logURL(agentID).path])
            }) { step(agentID, $0) } onItem: { item(agentID, $0) }
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            guard launch.started else { return fail(agentID, result) }
            AgentRegistry.remember(agentID, entry: entry, at: result.directory)
            finish(agentID, result, account: account.id)
            return
        }

        if ProcessInfo.processInfo.environment[nestedMarker] != nil { emit(["type": "no_room"]); return }
        let own = SubagentAccounts.ownAccountUUID()
        let agentID = UUID().uuidString.lowercased()
        let launch = Launch()
        var tried = Set<String>()
        while true {
            guard let account = await pick(accounts, config: config, own: own, excluding: tried) else {
                if launch.started {
                    finish(agentID, .init(text: AgentRun.noRoom, isError: true, limitReached: true, turns: 0, permissionDenials: 0), account: nil)
                } else {
                    emit(["type": "no_room"])
                }
                return
            }
            // No room still belongs to the built-in tool; an eligible routed agent must fail visibly.
            if let error = request.backgroundError {
                emit(["type": "error", "text": error])
                return
            }
            var model = request.model ?? request.parentModel
            if let m = model, AgentRegistry.lacksModel(account.id, m) { model = SubagentRunner.fallbackModel }
            AgentRegistry.setRunning(account.id)
            let firstModel = model
            let check = launch.check(subagentType: request.subagentType, account: account.id) {
                emit(["type": "started", "agentId": agentID, "account": account.id, "model": firstModel ?? "", "outputFile": logURL(agentID).path])
                log(agentID, "Started on the \(account.id) account: \(request.description ?? "")")
            }
            var req = SubagentRunner.Request(prompt: request.prompt, subagentType: request.subagentType, model: model,
                                             effort: request.effort, worktree: request.isolation == "worktree",
                                             permissionMode: permissionMode, sessionID: UUID().uuidString.lowercased(),
                                             mcpConfig: mcpConfig)
            let onProcess: @Sendable (Int32) -> Void = { AgentRegistry.setProcess(agentID, claude: $0) }
            var result = await SubagentRunner.run(req, on: account, in: request.cwd, onProcess: onProcess, check: check) {
                step(agentID, $0)
            } onItem: { item(agentID, $0) }
            // Plans differ in models (Pro has no Fable): run it again with one every plan has.
            if result.modelUnavailable, model != SubagentRunner.fallbackModel, !AgentRegistry.wasStopped(agentID) {
                if let model { AgentRegistry.rememberLacking(account.id, model) }
                req.model = SubagentRunner.fallbackModel
                req.sessionID = UUID().uuidString.lowercased()
                step(agentID, "Using Sonnet: the \(account.id) plan doesn't include \(model ?? "the default model")")
                result = await SubagentRunner.run(req, on: account, in: request.cwd, onProcess: onProcess, check: check) {
                    step(agentID, $0)
                } onItem: { item(agentID, $0) }
            }
            if !launch.started { return fail(agentID, result) }
            if result.limitReached && result.toolUses == 0 && !AgentRegistry.wasStopped(agentID) {
                // Refused before doing anything: another account can take the task whole.
                await SubagentUsage.shared.markFull(account)
                tried.insert(account.id)
                emit(["type": "moved", "account": account.id, "reason": "\(account.id) is at its usage limit"])
                continue
            }
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            AgentRegistry.remember(agentID, entry: .init(account: account.id, directory: result.directory ?? request.cwd,
                                                         sessionID: result.sessionID ?? req.sessionID, model: req.model,
                                                         subagentType: request.subagentType, effort: request.effort, at: Date()))
            finish(agentID, result, account: account.id)
            return
        }
    }

    /// Runs an agent from Headroom's list on its provider: its answer, or an error when the provider didn't
    /// take it. Nothing stands in for it: no other provider, no built-in agent.
    static func runDefined(_ definition: AgentDefinition, _ request: Request, agentID: String, resume: AgentRegistry.Entry?,
                           mcpConfig: String?) async {
        SubagentLog.write("\(agentID) \(resume == nil ? "start" : "continue") \(definition.type) on \(definition.summary)")
        let launch = Launch()
        let job = AgentJob(agentID: agentID, definition: definition, prompt: request.prompt, cwd: resume?.directory ?? request.cwd,
                           effort: resume?.effort ?? definition.effort ?? request.effort, permissionMode: request.permissionMode ?? "default",
                           worktree: request.isolation == "worktree", mcpConfig: mcpConfig, resume: resume)
        let events = AgentEvents(
            process: { AgentRegistry.setProcess(agentID, claude: $0) },
            started: { place, model in
                guard launch.begin() else { return }
                emit(["type": "started", "agentId": agentID, "account": place, "model": model, "provider": definition.provider.rawValue,
                      "outputFile": logURL(agentID).path])
                log(agentID, "Started \(definition.name) on \(place) (\(model)): \(request.description ?? "")")
            },
            step: { step(agentID, $0) },
            item: { item(agentID, $0) })
        let result = await definition.provider.backend.run(job, events)
        guard launch.started else { return fail(agentID, result) }
        let entry = resume ?? AgentRegistry.Entry(account: result.account ?? definition.provider.displayName, directory: request.cwd,
                                                   sessionID: "", model: definition.model, subagentType: definition.type,
                                                   effort: job.effort, at: Date(), definition: definition)
        if let session = result.sessionID, !session.isEmpty {
            var updated = entry
            updated.sessionID = session
            AgentRegistry.remember(agentID, entry: updated, at: result.directory)
        }
        finish(agentID, result, account: result.account ?? definition.provider.displayName)
    }

    /// What a run's callbacks share: whether `started` went out, which happens once Claude Code's init
    /// passed the check, on whichever account and attempt that was.
    final class Launch: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        var started: Bool { lock.lock(); defer { lock.unlock() }; return done }

        /// Marks it started: true the first time only.
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }

        /// The run's init check: a reason refuses it; otherwise `begin` runs, the first time only.
        func check(subagentType: String?, account: String, begin: @escaping @Sendable () -> Void) -> @Sendable ([String: Any]) -> String? {
            { [self] event in
                if let reason = SubagentRunner.checkInit(event, subagentType: subagentType) { return "\(reason) on the \(account) account" }
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                if first { begin() }
                return nil
            }
        }
    }

    /// It never started: why, as an error for the plugin to show. Nothing else stands in for it.
    private static func fail(_ agentID: String, _ result: SubagentRunner.Result) {
        AgentRegistry.setProcess(agentID, claude: nil)
        _ = AgentRegistry.takeStopped(agentID)
        emit(["type": "error", "text": result.text.isEmpty ? "Claude Code stopped before it started." : result.text])
    }

    static let noRoom = "No other Claude account has room right now. Use built-in subagents."

    static func pick(_ accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?,
                             excluding tried: Set<String>, log: Bool = true) async -> ClaudeAccount? {
        var candidates: [SubagentAccounts.Candidate] = []
        let allowOwn = FileManager.default.fileExists(atPath: HeadroomPaths.allowOwnAccount.path)
        for account in accounts where !tried.contains(account.id) {
            guard let signedIn = ClaudeProvider.signedInAccount(configDir: account.cliConfigDir).uuid, allowOwn || signedIn != own else { continue }
            let usage = await SubagentUsage.shared.usage(account)
            candidates.append(.init(account: account, name: account.id, sessionUsed: usage.session, weeklyUsed: usage.weekly,
                                    active: AgentRegistry.running(account.id)))
        }
        let choice = SubagentAccounts.pick(candidates, sessionThreshold: config.sessionThreshold, weeklyThreshold: config.weeklyThreshold)
        if log { SubagentLog.write("own \(own?.prefix(8) ?? "?"); " + candidates.map {
            "\($0.name) session \($0.sessionUsed.map { "\(Int($0))%" } ?? "?") weekly \($0.weeklyUsed.map { "\(Int($0))%" } ?? "?")"
        }.joined(separator: ", ") + " → \(choice?.name ?? "none")") }
        return choice?.account
    }

    /// Built-in subagents inherit the parent's mode. A headless run can't ask, so "default" (ask each
    /// time) becomes auto, where Claude Code's classifier decides what would have been asked.
    static func mappedPermissionMode(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty, mode != "default" else { return "auto" }
        return mode
    }

    private static func writeMCPConfig(directory: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let root = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let config = SubagentRunner.mcpConfig(from: root, directory: directory),
              let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys) else { return nil }
        // Named by content: the same servers give the same arguments, which a ready process must match.
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let file = HeadroomPaths.agentsDir.appendingPathComponent("mcp-\(digest).json")
        HeadroomPaths.ensure(HeadroomPaths.agentsDir)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }

    // MARK: Output

    static func logURL(_ agentID: String) -> URL { HeadroomPaths.agentsDir.appendingPathComponent("\(agentID).log") }

    private static func step(_ agentID: String, _ text: String) {
        emit(["type": "step", "text": text])
    }

    /// A transcript entry for the plugin's row, and in readable form for the agent's log (its `outputFile`).
    private static func item(_ agentID: String, _ item: [String: Any]) {
        var line = item
        line["type"] = "item"
        emit(line)
        switch item["kind"] as? String {
        case "text": log(agentID, item["text"] as? String ?? "")
        case "tool": log(agentID, "→ \(item["summary"] as? String ?? "")")
        case "result": log(agentID, "← " + (item["text"] as? String ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20).joined(separator: "\n   "))
        default: break
        }
    }

    /// `Headroom --agent-open <agentId>`: Terminal on the agent's own Claude Code session, on its account,
    /// where its whole transcript reads as any session's and can be continued.
    static func openMain() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--agent-open"), i + 1 < args.count,
              let entry = AgentRegistry.lookup(args[i + 1]),
              let lines = (entry.definition?.provider ?? .claude).backend.terminal(entry) else { exit(1) }
        let script = HeadroomPaths.agentsDir.appendingPathComponent("open-\(args[i + 1]).command")
        HeadroomPaths.ensure(HeadroomPaths.agentsDir)
        let body = "#!/bin/zsh -l\n\(lines)\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { exit(1) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [script.path]
        try? open.run()
        open.waitUntilExit()
        exit(0)
    }

    /// `Headroom --agent-stop <agentId>`: TaskStop for an agent Headroom runs. Ends its Claude Code
    /// process; its runner then reports it stopped.
    static func stopMain() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--agent-stop"), i + 1 < args.count else { exit(2) }
        let id = args[i + 1]
        guard let pid = AgentRegistry.process(id) else {
            emit(["type": "error", "text": "Agent \(id) isn't running."])
            exit(1)
        }
        AgentRegistry.markStopped(id)
        SubagentRunner.terminate(pid)
        emit(["type": "stopped"])
        exit(0)
    }

    private static func finish(_ agentID: String, _ result: SubagentRunner.Result, account: String?) {
        AgentRegistry.setProcess(agentID, claude: nil)
        if AgentRegistry.takeStopped(agentID) {
            log(agentID, "Stopped.")
            var object: [String: Any] = ["type": "result", "text": "Stopped.", "isError": true, "stopped": true,
                                         "toolUses": result.toolUses, "durationMs": result.durationMs]
            if let account { object["account"] = account }
            emit(object)
            return
        }
        log(agentID, result.isError ? "Failed: \(result.text.prefix(500))" : "Finished.\n\n\(result.text)")
        var object: [String: Any] = [
            "type": "result", "text": result.text, "isError": result.isError, "limitReached": result.limitReached,
            "toolUses": result.toolUses, "durationMs": result.durationMs, "turns": result.turns,
            "inputTokens": result.inputTokens, "outputTokens": result.outputTokens, "permissionDenials": result.permissionDenials,
        ]
        if let account { object["account"] = account }
        if let model = result.model { object["model"] = model }
        emit(object)
    }

    private static func log(_ agentID: String, _ text: String) {
        HeadroomPaths.ensure(HeadroomPaths.agentsDir)
        let url = logURL(agentID)
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

/// One line per decision in ~/Library/Logs/Headroom/subagents.log, to see why an account was or wasn't used.
enum SubagentLog {
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Headroom/subagents.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }
}

/// What Headroom remembers about the agents it ran, shared by every runner process: which account and
/// session each agent is (for SendMessage), which accounts lack which models, and what is running now.
enum AgentRegistry {
    /// An agent as a follow-up needs it: where it ran (a worktree's folder with `--worktree`), its session,
    /// and what it was started as, which `--resume` alone doesn't bring back.
    struct Entry: Codable {
        var account: String
        var directory: String
        var sessionID: String
        var model: String?
        var subagentType: String?
        var effort: String?
        var at: Date
        /// For an agent from Headroom's list, the definition it started with: a follow-up runs with it even
        /// after the list changed.
        var definition: AgentDefinition?
    }
    /// A running agent's processes: its runner's and Claude Code's.
    struct Processes: Codable { var runner: Int32; var claude: Int32 }
    struct Store: Codable {
        var agents: [String: Entry] = [:]
        var lacking: [String: [String]] = [:]   // account → models its plan doesn't include
        var fullUntil: [String: Date] = [:]     // account → when to try it again after "limit reached"
        var processes: [String: Processes]? = [:]
        var stopped: [String]? = []             // agents TaskStop ended, until their runner reported it
    }

    private static func withStore<T>(_ body: (inout Store) -> T) -> T {
        HeadroomPaths.ensure(HeadroomPaths.support)
        let lockFD = open(HeadroomPaths.agentsLock.path, O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var store = (try? Data(contentsOf: HeadroomPaths.agents)).flatMap { try? JSONDecoder.headroom.decode(Store.self, from: $0) } ?? Store()
        let value = body(&store)
        if store.agents.count > 500 {
            store.agents = Dictionary(uniqueKeysWithValues: store.agents.sorted { $0.value.at > $1.value.at }.prefix(400).map { ($0.key, $0.value) })
        }
        try? JSONEncoder.headroom.encode(store).write(to: HeadroomPaths.agents, options: .atomic)
        return value
    }

    static func remember(_ id: String, entry: Entry, at directory: String? = nil) {
        var entry = entry
        if let directory { entry.directory = directory }
        entry.at = Date()
        withStore { $0.agents[id] = entry }
    }

    /// Records the Claude Code process running `id` (nil: none any more), beside this runner's own.
    static func setProcess(_ id: String, claude pid: Int32?) {
        withStore { store in
            store.processes = (store.processes ?? [:]).filter { kill($0.value.runner, 0) == 0 }
            store.processes?[id] = pid.map { Processes(runner: getpid(), claude: $0) }
        }
    }

    /// The Claude Code process running `id`, while the runner that started it is alive (so the pid is still its).
    static func process(_ id: String) -> Int32? {
        withStore { store in
            guard let p = store.processes?[id], p.claude > 0, kill(p.runner, 0) == 0 else { return nil }
            return p.claude
        }
    }

    static func markStopped(_ id: String) { withStore { $0.stopped = ($0.stopped ?? []).filter { $0 != id } + [id] } }

    static func wasStopped(_ id: String) -> Bool { withStore { $0.stopped?.contains(id) ?? false } }

    /// Whether TaskStop ended `id`, forgetting it.
    static func takeStopped(_ id: String) -> Bool {
        withStore { store in
            guard store.stopped?.contains(id) == true else { return false }
            store.stopped?.removeAll { $0 == id }
            return true
        }
    }

    static func lookup(_ id: String) -> Entry? { withStore { $0.agents[id] } }

    static func lacksModel(_ account: String, _ model: String) -> Bool { withStore { $0.lacking[account]?.contains(model) ?? false } }

    static func rememberLacking(_ account: String, _ model: String) {
        withStore { store in if !(store.lacking[account]?.contains(model) ?? false) { store.lacking[account, default: []].append(model) } }
    }

    static func markFull(_ account: String) { withStore { $0.fullUntil[account] = Date().addingTimeInterval(600) } }

    static func isFull(_ account: String) -> Bool { withStore { ($0.fullUntil[account] ?? .distantPast) > Date() } }

    /// Marks this runner as working on `account` (nil: on none) for `running(_:)`.
    static func setRunning(_ account: String?) {
        let dir = HeadroomPaths.agentsDir.appendingPathComponent("running")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("\(getpid()).") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if let account { FileManager.default.createFile(atPath: dir.appendingPathComponent("\(getpid()).\(account)").path, contents: nil) }
    }

    /// Runner processes alive on an account, from their pid files; spreads parallel agents over accounts.
    static func running(_ account: String) -> Int {
        let dir = HeadroomPaths.agentsDir.appendingPathComponent("running")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { name in
            let parts = name.split(separator: ".")
            guard parts.count == 2, parts[1] == account, let pid = Int32(parts[0]) else { return false }
            return kill(pid, 0) == 0
        }.count
    }
}
