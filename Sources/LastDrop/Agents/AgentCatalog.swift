import Foundation

/// Where an agent from lastdrop's list runs. Each has a backend that starts it, continues it and lists its models.
enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Your other Claude accounts, the one with the most room.
    case claude
    case codex
    case zai
    case openrouter
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude accounts"
        case .codex: "Codex"
        case .zai: "Z.ai"
        case .openrouter: "OpenRouter"
        case .antigravity: "Antigravity"
        }
    }

    var usageID: ProviderID {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .zai: .zai
        case .openrouter: .openrouter
        case .antigravity: .antigravity
        }
    }
}

/// One agent of lastdrop's list: an agent type Claude sees beside the built-in ones (`lastdrop:<name>`),
/// which always runs on its provider and model.
struct AgentDefinition: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// The type's short name: letters, digits, "-" and "_" (`codex-deep`).
    var name: String
    /// When Claude should use it, as Claude reads it in its list of agent types.
    var description: String
    var provider: AgentProvider
    /// The provider's model id (`gpt-6.1-sol`, `glm-5.3`).
    var model: String
    /// A fixed reasoning effort; nil lets each Agent call's `effort` decide.
    var effort: String?
    var enabled = true

    /// The agent type Claude calls it by.
    var type: String { "\(AgentCatalog.plugin):\(name)" }

    /// "Codex · gpt-6.1-sol · high", where it runs as its row shows it.
    var summary: String {
        ([provider == .claude ? "Claude" : provider.displayName, model] + (effort.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// What the backend is told about its role: the same line Claude chose it by.
    var instructions: String {
        "You are \(name), a subagent another coding agent delegated a task to. Your role: \(description)\n"
            + "Work on the task you are given, then answer with a concise report of what you found or did: it is all the caller sees."
    }

    /// "Codex Deep" → "codex-deep", as an agent type name allows.
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.lowercased().trimmingCharacters(in: .whitespaces).components(separatedBy: allowed.inverted)
        return String(parts.filter { !$0.isEmpty }.joined(separator: "-").prefix(64))
    }
}

/// lastdrop's list of agents, in its support folder. The plugin reads it (`lastdrop --agent-catalog`) on
/// every prompt and registers the enabled ones, so edits apply from the next turn.
struct AgentCatalog: Codable, Equatable, Sendable {
    /// The plugin's name, the agent types' prefix.
    static let plugin = "lastdrop"

    var agents: [AgentDefinition] = []
    /// Bumped on every save, so the plugin knows when to register again.
    var revision = 0
    /// Ask Claude to delegate substantial work to these agents before doing it itself.
    var saveClaude = false
    /// The user's own wording of that instruction; nil uses `defaultSavingInstruction`.
    var saveClaudeText: String?

    /// What Claude reads while saving is on, unless the user rewrote it. The plugin keeps the same text
    /// for an app that sends none.
    static let defaultSavingInstruction = "Claude usage is being saved: delegate substantial work (implementation, exploration, reviews, research) to lastdrop's agents (lastdrop:*), picking by their descriptions, even where a description says to prefer built-in Claude subagents. Work yourself or with built-in subagents only when no lastdrop agent fits."

    /// The instruction Claude gets.
    var savingInstruction: String {
        let text = saveClaudeText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? Self.defaultSavingInstruction : text
    }

    private enum CodingKeys: String, CodingKey { case agents, revision, saveClaude, saveClaudeText }

    var enabled: [AgentDefinition] { agents.filter(\.enabled) }

    /// The enabled agent Claude calls by `type` (`lastdrop:codex-deep`), or by its bare name.
    func agent(_ type: String) -> AgentDefinition? {
        let name = type.hasPrefix("\(Self.plugin):") ? String(type.dropFirst(Self.plugin.count + 1)) : type
        return enabled.first { $0.name == name }
    }

    /// Why `definition` can't be saved as it is, else nil.
    func problem(with definition: AgentDefinition) -> String? {
        if definition.name.isEmpty { return "Give the agent a name." }
        if definition.name != AgentDefinition.slug(definition.name) { return "Names use lowercase letters, digits, - and _." }
        if agents.contains(where: { $0.name == definition.name && $0.id != definition.id }) { return "Another agent is named \(definition.name)." }
        if definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what the agent is for: Claude reads it to choose." }
        if definition.model.isEmpty { return "Pick a model." }
        return nil
    }

    static func load(from url: URL = LastDropPaths.agentCatalog) -> AgentCatalog {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.lastdrop.decode(AgentCatalog.self, from: $0) } ?? .init()
    }

    func save(to url: URL = LastDropPaths.agentCatalog) throws {
        LastDropPaths.ensure(url.deletingLastPathComponent())
        var next = self
        next.revision += 1
        try JSONEncoder.lastdrop.encode(next).write(to: url, options: .atomic)
    }

    /// What the plugin reads: the revision and the enabled agents as Claude Code registers them.
    func pluginJSON() -> [String: Any] {
        ["revision": revision, "saveClaude": saveClaude, "saveClaudeText": savingInstruction, "nativeTasks": true, "agents": enabled.map { agent in
            ["name": agent.name, "description": agent.description, "provider": agent.provider.rawValue,
             "summary": agent.summary, "prompt": agent.instructions]
        }]
    }

    /// `lastdrop --agent-catalog`: the enabled agents for the plugin, as one JSON line.
    static func printMain() -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: load().pluginJSON(), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(0)
    }
}

extension AgentCatalog {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agents = try values.decode([AgentDefinition].self, forKey: .agents)
        revision = try values.decode(Int.self, forKey: .revision)
        saveClaude = try values.decodeIfPresent(Bool.self, forKey: .saveClaude) ?? false
        saveClaudeText = try values.decodeIfPresent(String.self, forKey: .saveClaudeText)
    }
}
