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
/// - `{"type":"moved","account","reason"}`: the account reached its usage limit; another took over (before
///   any work, from the start; partway through, continuing the same session).
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
        /// Claude Code's native task id, also used for Headroom's logs, stop and resume.
        var id: String?

        var validID: Bool {
            guard let id else { return true }
            return !id.isEmpty && id.count <= 100 && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
    }

    static func main(routeOnly: Bool = false) -> Never {
        stopOnSignal()
        Task.detached {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let request = try? JSONDecoder().decode(Request.self, from: input) else {
                emit(["type": "result", "text": "Headroom couldn't read the subagent request.", "isError": true])
                exit(1)
            }
            guard request.validID else {
                emit(["type": "error", "text": "Headroom received an invalid native agent id."])
                exit(1)
            }
            if routeOnly { emit(await route(request)) } else { await run(request) }
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
                // A ready process came from the app, so it is not necessarily this runner's child.
                for pid in AgentRegistry.ownedProcesses() { SubagentRunner.terminate(pid) }
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

    /// Checks routing before the engine creates its native task. It starts no provider or model request.
    static func route(_ request: Request) async -> [String: Any] {
        if ProcessInfo.processInfo.environment[nestedMarker] != nil { return ["type": "no_room"] }
        if let id = request.resume {
            return ["type": AgentRegistry.lookup(id) == nil ? "no_room" : "routed"]
        }
        if let type = request.agent {
            guard AgentCatalog.load().agent(type) != nil else {
                return ["type": "error", "text": "No agent \(type) is enabled in Headroom (Settings → Agents)."]
            }
            return ["type": "routed"]
        }
        let config = ClaudeAccountsConfig.load()
        let account = await pick(config.ordered, config: config, own: SubagentAccounts.ownAccountUUID(), excluding: [])
        return ["type": account == nil ? "no_room" : "routed"]
    }

    static func run(_ request: Request) async {
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
            return await runDefined(definition, request, agentID: request.id ?? UUID().uuidString.lowercased(), resume: nil, mcpConfig: mcpConfig)
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
            var result = await SubagentRunner.run(req, on: account, in: entry.directory,
                                                  onProcess: { AgentRegistry.setProcess(agentID, claude: $0) },
                                                  check: launch.check(subagentType: entry.subagentType, account: account.id) { event in
                AgentRegistry.remember(agentID, entry: entry, at: event["cwd"] as? String)
                emit(["type": "started", "agentId": agentID, "account": account.id, "model": entry.model ?? "", "outputFile": logURL(agentID).path])
            }) { step(agentID, $0) } onItem: { item(agentID, $0) }
            if result.limitReached { await SubagentUsage.shared.markFull(account) }
            guard launch.started else { return fail(agentID, result) }
            var moved = entry
            if let directory = result.directory { moved.directory = directory }
            (result, moved) = await carryOn(agentID, entry: moved, result: result, accounts: accounts, config: config,
                                            own: SubagentAccounts.ownAccountUUID(), tried: [],
                                            permissionMode: permissionMode, mcpConfig: mcpConfig)
            AgentRegistry.remember(agentID, entry: moved)
            finish(agentID, result, account: moved.account)
            return
        }

        if ProcessInfo.processInfo.environment[nestedMarker] != nil { emit(["type": "no_room"]); return }
        let own = SubagentAccounts.ownAccountUUID()
        let agentID = request.id ?? UUID().uuidString.lowercased()
        let launch = Launch()
        var tried = Set<String>()
        var refused: SubagentRunner.Result?
        while true {
            // Admitted already: when the room it was admitted for is gone, the session's own account takes it,
            // as a built-in subagent would have run there.
            guard let account = await nextAccount(accounts, config: config, own: own, excluding: tried) else {
                if launch.started {
                    finish(agentID, refused ?? .init(text: AgentRun.noRoom, isError: true, limitReached: true, turns: 0, permissionDenials: 0), account: nil)
                } else {
                    emit(["type": "no_room"])
                }
                return
            }
            var model = request.model ?? request.parentModel
            if let m = model, AgentRegistry.lacksModel(account.id, m) { model = SubagentRunner.fallbackModel }
            AgentRegistry.setRunning(account.id)
            let firstModel = model
            let check = launch.check(subagentType: request.subagentType, account: account.id) { event in
                // A native stop can end the runner before `run` returns. Keep its session from init onward.
                AgentRegistry.remember(agentID, entry: .init(account: account.id, directory: event["cwd"] as? String ?? request.cwd,
                                                           sessionID: event["session_id"] as? String ?? "", model: event["model"] as? String ?? firstModel,
                                                           subagentType: request.subagentType, effort: request.effort, at: Date()))
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
                refused = result
                emit(["type": "moved", "account": account.id, "reason": "\(account.id) is at its usage limit"])
                continue
            }
            var entry = AgentRegistry.Entry(account: account.id, directory: result.directory ?? request.cwd,
                                            sessionID: result.sessionID ?? req.sessionID, model: req.model,
                                            subagentType: request.subagentType, effort: request.effort, at: Date())
            (result, entry) = await carryOn(agentID, entry: entry, result: result, accounts: accounts, config: config, own: own,
                                            tried: tried, permissionMode: permissionMode, mcpConfig: mcpConfig)
            AgentRegistry.remember(agentID, entry: entry)
            finish(agentID, result, account: entry.account)
            return
        }
    }

    /// What a moved agent is told: nothing about accounts or limits, only to go on.
    static let continuePrompt = "Continue the task from where you left off and finish it."

    /// An agent an account stopped at its usage limit partway through: its session moves to the next account
    /// with room, else to the calling session's own, and continues there. Whoever called the agent only ever
    /// gets its report; the limit shows only when every account, the session's own included, is at one.
    static func carryOn(_ agentID: String, entry: AgentRegistry.Entry, result: SubagentRunner.Result,
                        accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?, tried: Set<String>,
                        permissionMode: String, mcpConfig: String?) async -> (SubagentRunner.Result, AgentRegistry.Entry) {
        var entry = entry, result = result, tried = tried
        var toolUses = result.toolUses, durationMs = result.durationMs
        while result.limitReached, !AgentRegistry.wasStopped(agentID),
              let from = accounts.first(where: { $0.id == entry.account }) {
            await SubagentUsage.shared.markFull(from)
            tried.insert(from.id)
            guard let to = await nextAccount(accounts, config: config, own: own, excluding: tried) else { break }
            guard SessionTransfer.copy(entry.sessionID, from: from, to: to) else {
                SubagentLog.write("\(agentID): session \(entry.sessionID) couldn't be copied from \(from.id) to \(to.id)")
                break
            }
            SubagentLog.write("\(agentID) continues on \(to.id): \(from.id) is at its usage limit")
            emit(["type": "moved", "account": from.id, "reason": "\(from.id) is at its usage limit; continuing on \(to.id)"])
            log(agentID, "\(from.id) is at its usage limit; continuing on the \(to.id) account.")
            if let m = entry.model, AgentRegistry.lacksModel(to.id, m) { entry.model = SubagentRunner.fallbackModel }
            entry.account = to.id
            AgentRegistry.setRunning(to.id)
            AgentRegistry.remember(agentID, entry: entry)   // a stop or a follow-up finds it on its new account
            var req = SubagentRunner.Request(prompt: continuePrompt, subagentType: entry.subagentType, model: entry.model,
                                             effort: entry.effort, permissionMode: permissionMode, sessionID: entry.sessionID,
                                             resume: true, mcpConfig: mcpConfig)
            let onProcess: @Sendable (Int32) -> Void = { AgentRegistry.setProcess(agentID, claude: $0) }
            result = await SubagentRunner.run(req, on: to, in: entry.directory, onProcess: onProcess) {
                step(agentID, $0)
            } onItem: { item(agentID, $0) }
            if result.modelUnavailable, let model = entry.model, model != SubagentRunner.fallbackModel,
               !AgentRegistry.wasStopped(agentID), SessionTransfer.copy(entry.sessionID, from: from, to: to) {
                AgentRegistry.rememberLacking(to.id, model)
                entry.model = SubagentRunner.fallbackModel
                req.model = entry.model
                step(agentID, "Using Sonnet: the \(to.id) plan doesn't include \(model)")
                result = await SubagentRunner.run(req, on: to, in: entry.directory, onProcess: onProcess) {
                    step(agentID, $0)
                } onItem: { item(agentID, $0) }
            }
            toolUses += result.toolUses
            durationMs += result.durationMs
        }
        result.toolUses = toolUses
        result.durationMs = durationMs
        return (result, entry)
    }

    /// The calling session's own account among Headroom's, as `ownAccountUUID` names it.
    static func ownAccount(_ accounts: [ClaudeAccount], own: String?) -> ClaudeAccount? {
        guard let own else { return nil }
        return accounts.first { ClaudeProvider.signedInAccount(configDir: $0.cliConfigDir).uuid == own }
    }

    /// Where an admitted agent runs next: the other account with the most room, else the session's own.
    static func nextAccount(_ accounts: [ClaudeAccount], config: ClaudeAccountsConfig, own: String?,
                            excluding tried: Set<String>) async -> ClaudeAccount? {
        if let account = await pick(accounts, config: config, own: own, excluding: tried) { return account }
        guard let mine = ownAccount(accounts, own: own), !tried.contains(mine.id) else { return nil }
        SubagentLog.write("no other account has room → \(mine.id), the session's own")
        return mine
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
        func check(subagentType: String?, account: String, begin: @escaping @Sendable ([String: Any]) -> Void) -> @Sendable ([String: Any]) -> String? {
            { [self] event in
                if let reason = SubagentRunner.checkInit(event, subagentType: subagentType) { return "\(reason) on the \(account) account" }
                lock.lock()
                let first = !done
                done = true
                lock.unlock()
                if first { begin(event) }
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
            "cacheReadInputTokens": result.cacheReadInputTokens, "cacheCreationInputTokens": result.cacheCreationInputTokens,
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

    /// Only processes handed to this runner, including ones claimed from the warm pool.
    static func ownedProcesses() -> [Int32] {
        withStore { store in
            (store.processes ?? [:]).values.filter { $0.runner == getpid() && $0.claude > 0 }.map(\.claude)
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
