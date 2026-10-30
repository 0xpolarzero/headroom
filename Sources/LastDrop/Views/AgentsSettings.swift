import SwiftUI

/// Adding or editing one agent, in a sheet: its name and role, then where it runs.
struct AgentEditor: View {
    @State var agent: AgentDefinition
    let catalog: AgentCatalog
    let save: (AgentDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AgentModel] = []
    @State private var modelsError: String?
    @State private var error: String?

    private var isNew: Bool { !catalog.agents.contains { $0.id == agent.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $agent.name, prompt: Text("reviewer"))
                    TextField("When should Claude use it?", text: $agent.description,
                              prompt: Text("Reviews code, plans and diffs that need strong reasoning."), axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    HStack(spacing: 4) {
                        Caption("Claude uses it as model: \"\(AgentDefinition.slug(agent.name))\" on the Agent tool.")
                        InfoTip("Claude picks agents by their description, so write it for Claude.")
                    }
                }
                Section("Runs on") {
                    Picker("Provider", selection: $agent.provider) {
                        ForEach(AgentProvider.allCases) { provider in
                            HStack {
                                ProviderLogo(id: provider.usageID, size: 13)
                                Text(provider.displayName)
                            }
                            .tag(provider)
                        }
                    }
                    .onChange(of: agent.provider) { agent.model = ""; agent.effort = nil }
                    if models.isEmpty {
                        TextField("Model", text: $agent.model, prompt: Text("Model id"))
                        if let modelsError { Caption(modelsError) }
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
                            Text("Claude decides").tag(String?.none)
                            ForEach(efforts, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add agent" : "Save", action: commit).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
        .task(id: agent.provider) { await loadModels() }
    }

    private func commit() {
        var next = agent
        next.name = AgentDefinition.slug(next.name)
        next.description = next.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = catalog.problem(with: next) { error = problem; return }
        save(next)
        dismiss()
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
            modelsError = "Couldn't list \(agent.provider.displayName)'s models (\(error.localizedDescription)). Type the model's id."
        }
    }
}
