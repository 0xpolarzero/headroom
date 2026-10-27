import SwiftUI

/// Agent types and their provider, model and effort.
struct AgentsSettings: View {
    @State private var catalog = AgentCatalog.load()
    /// The agent being added or edited; nil when none is.
    @State private var editing: AgentDefinition?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("Save Claude usage", isOn: Binding(get: { catalog.saveClaude }, set: { on in
                    var next = catalog
                    next.saveClaude = on
                    _ = write(next)
                }))
                .fixedSize()
                SettingsInfo(text: "When on, Claude delegates substantial work to Headroom's agents, picking by their descriptions, before doing it itself.")
                Spacer()
            }
            .padding(.bottom, 4)
            ForEach(catalog.agents) { agent in
                if editing?.id == agent.id {
                    AgentEditor(agent: Binding(get: { editing ?? agent }, set: { editing = $0 }), error: error, save: save, cancel: cancel)
                } else {
                    row(agent)
                }
            }
            if let new = editing, !catalog.agents.contains(where: { $0.id == new.id }) {
                AgentEditor(agent: Binding(get: { editing ?? new }, set: { editing = $0 }), error: error, save: save, cancel: cancel)
            } else if editing == nil {
                HStack(spacing: 6) {
                    if catalog.agents.isEmpty {
                        Text("No agents yet.").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("Add agent") {
                        error = nil
                        editing = AgentDefinition(name: "", description: "", provider: .codex, model: "")
                    }
                    SettingsInfo(text: "Claude uses enabled agents as headroom:<name> types that always run on their provider.")
                }
                .buttonStyle(.borderless)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ agent: AgentDefinition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle(isOn: Binding(get: { agent.enabled }, set: { on in update(agent.id) { $0.enabled = on } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).lineLimit(1)
                    Text(agent.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(agent.description)
            Spacer()
            Menu {
                Button("Edit") { error = nil; editing = agent }
                Divider()
                Button("Remove", role: .destructive) { remove(agent.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func save() {
        guard var agent = editing else { return }
        agent.name = AgentDefinition.slug(agent.name)
        agent.description = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = catalog.problem(with: agent) { error = problem; return }
        var next = catalog
        if let i = next.agents.firstIndex(where: { $0.id == agent.id }) { next.agents[i] = agent } else { next.agents.append(agent) }
        if write(next) { editing = nil; error = nil }
    }

    private func cancel() {
        editing = nil
        error = nil
    }

    private func update(_ id: UUID, _ change: (inout AgentDefinition) -> Void) {
        var next = catalog
        guard let i = next.agents.firstIndex(where: { $0.id == id }) else { return }
        change(&next.agents[i])
        _ = write(next)
    }

    private func remove(_ id: UUID) {
        var next = catalog
        next.agents.removeAll { $0.id == id }
        _ = write(next)
    }

    /// Saves the list, which the plugin reads on the next prompt; false when it couldn't.
    private func write(_ next: AgentCatalog) -> Bool {
        do {
            try next.save()
            catalog = AgentCatalog.load()
            return true
        } catch {
            self.error = "Couldn't save the agents: \(error.localizedDescription)"
            return false
        }
    }
}

/// Adding or editing one agent: its name and role, then its provider, model and effort.
private struct AgentEditor: View {
    @Binding var agent: AgentDefinition
    var error: String?
    var save: () -> Void
    var cancel: () -> Void

    @State private var models: [AgentModel] = []
    @State private var modelsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $agent.name)
                .textFieldStyle(.roundedBorder)
            TextField("Description", text: $agent.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Picker("Provider", selection: $agent.provider) {
                ForEach(AgentProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: agent.provider) { agent.model = ""; agent.effort = nil }
            if models.isEmpty {
                TextField("Model id", text: $agent.model)
                    .textFieldStyle(.roundedBorder)
                if let modelsError { Text(modelsError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else {
                Picker("Model", selection: $agent.model) {
                    if !models.contains(where: { $0.id == agent.model }) { Text(agent.model.isEmpty ? "Choose…" : agent.model).tag(agent.model) }
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .onChange(of: agent.model) {
                    if let effort = agent.effort, !efforts.contains(effort) { agent.effort = nil }
                }
            }
            if !efforts.isEmpty {
                Picker("Effort", selection: $agent.effort) {
                    Text("Decided by Claude").tag(String?.none)
                    ForEach(efforts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("headroom:\(AgentDefinition.slug(agent.name))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        .task(id: agent.provider) { await loadModels() }
    }

    /// The selected model's efforts; every level when the model isn't in the provider's list.
    private var efforts: [String] {
        models.first { $0.id == agent.model }?.efforts ?? (agent.model.isEmpty ? [] : ClaudeBackend.efforts)
    }

    private func loadModels() async {
        models = []
        modelsError = nil
        do {
            models = try await agent.provider.backend.models()
            if models.isEmpty { modelsError = "\(agent.provider.displayName) lists no models here: type the model's id." }
        } catch {
            modelsError = "Couldn't list \(agent.provider.displayName)'s models (\(error.localizedDescription)): type the model's id."
        }
    }
}
