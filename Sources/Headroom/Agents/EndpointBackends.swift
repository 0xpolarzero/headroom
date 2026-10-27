import Foundation

/// Claude Code on the Z.ai Coding Plan's Anthropic endpoint.
/// Model and effort list: https://docs.z.ai/devpack/latest-model
enum ZAIBackend: AgentBackend {
    static func models() async throws -> [AgentModel] {
        ["glm-5.3", "glm-5.3-flash"].map {
            AgentModel(id: $0, name: $0, efforts: ["low", "high", "max"], defaultEffort: "max")
        }
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        await EndpointProfile.run(job, events, provider: .zai)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { EndpointProfile.terminal(entry, provider: .zai) }
}

/// Claude Code on OpenRouter's Anthropic endpoint, with models that advertise tool use.
/// https://openrouter.ai/docs/guides/coding-agents/claude-code-integration
enum OpenRouterBackend: AgentBackend {
    static func models() async throws -> [AgentModel] {
        let (body, http) = try await HTTP.json(HTTP.request("https://openrouter.ai/api/v1/models"))
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let root = body as? [String: Any] else { throw ProviderError.invalidResponse }
        return try decodeModels(root)
    }

    static func decodeModels(_ root: [String: Any]) throws -> [AgentModel] {
        guard let data = root.array("data") else { throw ProviderError.invalidResponse }
        return data.compactMap { entry in
            let parameters = entry["supported_parameters"] as? [String] ?? []
            guard parameters.contains("tools"), let id = entry.string("id"), !id.isEmpty else { return nil }
            let reasoning = entry.dict("reasoning")
            let efforts = reasoning?["supported_efforts"] as? [String]
                ?? (parameters.contains("reasoning") ? ["low", "medium", "high"] : [])
            let preferred = reasoning?.string("default_effort")
            return AgentModel(id: id, name: entry.string("name") ?? id, efforts: efforts,
                              defaultEffort: preferred.flatMap { efforts.contains($0) ? $0 : nil })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func run(_ job: AgentJob, _ events: AgentEvents) async -> SubagentRunner.Result {
        await EndpointProfile.run(job, events, provider: .openrouter)
    }

    static func terminal(_ entry: AgentRegistry.Entry) -> String? { EndpointProfile.terminal(entry, provider: .openrouter) }
}

/// An owned Claude Code profile. Settings and Terminal scripts contain a key helper, never its output.
struct EndpointProfile: Equatable, Sendable {
    var provider: AgentProvider
    var directory: String
    var model: String
    var effort: String?

    static let modelVariables = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                                 "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]

    static func directory(for provider: AgentProvider) -> String {
        HeadroomPaths.support.appendingPathComponent("endpoints/\(provider.rawValue)", isDirectory: true).path
    }

    var environment: [String: String] {
        var env = ["ANTHROPIC_BASE_URL": provider == .zai ? "https://api.z.ai/api/anthropic" : "https://openrouter.ai/api",
                   "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_API_KEY": "", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                   "API_TIMEOUT_MS": "3000000"]
        for key in Self.modelVariables { env[key] = model }
        return env
    }

    /// Session settings pin routing above file settings; project env must not switch the provider.
    var arguments: [String] {
        let settings: [String: Any] = ["env": environment, "model": model]
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["--setting-sources", "user", "--settings", String(decoding: data, as: UTF8.self)]
    }

    /// Only non-secret, useful context is shared with the user's Claude profile.
    func prepare(helperExecutable: String = CommandLine.arguments[0], sharedDirectory: String = NSHomeDirectory() + "/.claude") throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = URL(fileURLWithPath: helperExecutable).standardizedFileURL.path
        let helper = "\(ClaudeSignIn.shellQuote(executable)) --agent-key \(provider.rawValue)"
        let settings = try JSONSerialization.data(withJSONObject: ["apiKeyHelper": helper], options: [.prettyPrinted, .sortedKeys])
        let file = dir.appendingPathComponent("settings.json")
        // Replace a stale symlink rather than writing through it into a user's settings.
        if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil { try fm.removeItem(at: file) }
        try settings.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let state = dir.appendingPathComponent(".claude.json")
        var onboarding = (try? Data(contentsOf: state)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if onboarding["hasCompletedOnboarding"] as? Bool != true {
            onboarding["hasCompletedOnboarding"] = true
            try JSONSerialization.data(withJSONObject: onboarding, options: [.sortedKeys]).write(to: state, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        }
        for item in ["agents", "skills", "CLAUDE.md", "commands"] {
            let source = sharedDirectory + "/" + item, target = directory + "/" + item
            guard fm.fileExists(atPath: source), (try? fm.attributesOfItem(atPath: target)) == nil else { continue }
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
        }
    }

    static func apiKey(_ provider: AgentProvider) -> String? {
        switch provider {
        case .zai: ZAIProvider.apiKey()
        case .openrouter: OpenRouterProvider.apiKey()
        default: nil
        }
    }

    static func missingKey(_ provider: AgentProvider) -> String {
        provider == .zai ? "Add a Z.ai Coding Plan API key in Headroom's Settings."
            : "Add a regular OpenRouter API key in Headroom's Settings. Management keys can't run models."
    }

    /// The helper writes only the requested provider's key to stdout, before AppKit starts.
    static func keyMain() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--agent-key"), i + 1 < args.count,
              let provider = AgentProvider(rawValue: args[i + 1]), provider == .zai || provider == .openrouter else { exit(2) }
        guard let key = apiKey(provider) else {
            FileHandle.standardError.write(Data((missingKey(provider) + "\n").utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(Data((key + "\n").utf8))
        exit(0)
    }

    static func run(_ job: AgentJob, _ events: AgentEvents, provider: AgentProvider) async -> SubagentRunner.Result {
        func failure(_ message: String) -> SubagentRunner.Result {
            .init(text: message, isError: true, limitReached: false, turns: 0, permissionDenials: 0, account: provider.displayName)
        }
        guard let key = apiKey(provider) else { return failure(missingKey(provider)) }
        do {
            if provider == .openrouter { try await OpenRouterProvider.validateInferenceKey(key) }
            let model = job.resume?.model ?? job.definition.model
            let effort = job.resume.map { $0.effort } ?? job.effort
            if provider == .zai, let effort, !["low", "high", "max"].contains(effort) {
                return failure("Z.ai supports low, high, or max effort; received \(effort).")
            }
            let profile = EndpointProfile(provider: provider, directory: directory(for: provider), model: model, effort: effort)
            try profile.prepare()
            let request = SubagentRunner.Request(prompt: job.prompt, model: model, effort: effort,
                worktree: job.resume == nil && job.worktree, permissionMode: AgentRun.mappedPermissionMode(job.permissionMode),
                sessionID: job.resume?.sessionID ?? UUID().uuidString.lowercased(), resume: job.resume != nil,
                mcpConfig: job.mcpConfig, systemPrompt: job.definition.instructions, endpoint: profile)
            var result = await SubagentRunner.run(request, on: ClaudeAccount(id: "main"), in: job.resume?.directory ?? job.cwd,
                onProcess: events.process, check: { event in
                    if let reason = SubagentRunner.checkInit(event, subagentType: nil) { return "\(reason) on \(provider.displayName)" }
                    events.started(provider.displayName, model)
                    return nil
                }, onStep: events.step, onItem: events.item)
            result.account = provider.displayName
            return result
        } catch { return failure(error.localizedDescription) }
    }

    static func terminal(_ entry: AgentRegistry.Entry, provider: AgentProvider) -> String? {
        guard let model = entry.model else { return nil }
        let profile = EndpointProfile(provider: provider, directory: directory(for: provider), model: model, effort: entry.effort)
        guard (try? profile.prepare()) != nil else { return nil }
        return profile.terminal(entry)
    }

    /// Terminal starts as a login shell too; drop its routing and effort overrides before exporting ours.
    func terminal(_ entry: AgentRegistry.Entry) -> String {
        var lines = ["for name in ${(k)parameters}; do",
                     "  if [[ $name == ANTHROPIC_* || $name == CLAUDE_CODE_* || $name == CLAUDE_AGENT_* ]]; then unset $name; fi", "done",
                     "unset CLAUDECODE CLAUDE_CONFIG_DIR CLAUDE_EFFORT CLAUDE_PID MAX_THINKING_TOKENS",
                     "export CLAUDE_CONFIG_DIR=\(ClaudeSignIn.shellQuote(directory))"]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(ClaudeSignIn.shellQuote(value))")
        }
        lines.append("cd \(ClaudeSignIn.shellQuote(entry.directory)) || exit 1")
        var args = ["claude", "--resume", entry.sessionID, "--model", model] + arguments
        if let effort = entry.effort { args += ["--effort", effort] }
        lines.append("exec " + args.map(ClaudeSignIn.shellQuote).joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}
