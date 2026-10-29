import SwiftUI

// The pieces Settings and first-launch setup share, so each setting looks and works the same in both.
// Each is one or more Form sections.

/// Opening Headroom when the Mac starts.
struct LoginSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                SettingLabel(icon: "power", title: "Open at login", detail: model.launchAtLoginError, detailColor: .orange)
            }
            .disabled(!AppModel.isBundled)
        }
    }
}

/// Every account, by provider, with its menu; then Add Account.
struct AccountsSections: View {
    @Bindable var model: AppModel
    /// Also lists the providers not connected yet, each with its own button: setup's more guided version.
    var listsOthers = false
    @State private var adding = false
    @State private var connecting: ProviderID?
    @State private var renaming: AccountInfo?
    @State private var newName = ""

    var body: some View {
        Group {
            ForEach(model.connectedProviders) { provider in
                let accounts = model.accounts(provider)
                Section {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, info in
                        row(info, index: index, count: accounts.count)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                        if accounts.count > 1 && model.showsAgents { InfoTip(footer(provider)) }
                    }
                }
            }
            let others = ProviderID.allCases.filter { !model.connectedProviders.contains($0) }
            if listsOthers && !others.isEmpty {
                Section("Not connected") {
                    ForEach(others) { provider in
                        HStack(spacing: 10) {
                            ProviderTile(id: provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName).fontWeight(.medium)
                                Caption(provider.planHint)
                            }
                            Spacer()
                            Button(provider.signsInWithBrowser ? "Sign in…" : "Add key…") { model.connectStatus = .idle; connecting = provider }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if listsOthers {
                Section {
                    HStack {
                        Spacer()
                        Button("Add another account…") { model.connectStatus = .idle; adding = true }
                    }
                }
            } else if model.connectedProviders.isEmpty {
                Section { Caption("No accounts yet.") }
            }
        }
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .sheet(item: $connecting) { provider in AddAccountSheet(model: model, provider: provider) }
        .alert("Rename account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func footer(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "Subagents go to the account with the most left. Ties follow this order."
        case .antigravity: "Agents use the first account: the Antigravity CLI signs in only one."
        default: "Agents go to the account with the most left. Ties follow this order."
        }
    }

    private func row(_ info: AccountInfo, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            ProviderTile(id: info.account.provider)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).fontWeight(.medium)
                    if let plan = info.plan, plan != info.name { PlanChip(text: plan) }
                }
                if let problem = info.limits.problem {
                    // A rate limit clears by itself: grey, not orange. One line; the rest on hover.
                    Text(info.state.rateLimited ? "Busy, retrying soon" : problem)
                        .font(.caption)
                        .foregroundStyle(info.state.rateLimited ? .secondary : Color.orange)
                        .lineLimit(1)
                        .help(problem)
                } else if let email = info.email {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer()
            // The icon goes inside each choice, so the dropdown shows it right beside the value.
            Picker("Menu bar", selection: Binding(get: { info.account.menuBar }, set: { model.setMenuBar(info.id, $0) })) {
                Label("Hidden", systemImage: "menubar.rectangle").tag(MenuBarMode?.none)
                Divider()
                if info.account.provider == .openrouter {
                    Label("Credits", systemImage: "menubar.rectangle").tag(MenuBarMode?.some(.session))
                } else {
                    ForEach(MenuBarMode.allCases) { Label($0.title, systemImage: "menubar.rectangle").tag(MenuBarMode?.some($0)) }
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Shown in the menu bar")
            Picker("Notify", selection: Binding(get: { info.account.notifyAt }, set: { model.setNotify(info.id, $0) })) {
                Label("Off", systemImage: "bell.slash").tag(Double?.none)
                Divider()
                ForEach(Account.notifyChoices, id: \.self) { Label(Account.notifyTitle($0), systemImage: "bell").tag(Double?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Notify when this much is left")
            Menu {
                Button("Rename…") { newName = info.name; renaming = info }
                if count > 1 {
                    Button("Move up") { model.moveAccount(info.id, by: -1) }.disabled(index == 0)
                    Button("Move down") { model.moveAccount(info.id, by: 1) }.disabled(index == count - 1)
                }
                if info.account.provider == .claude {
                    Button("Sign in again in Terminal") { model.signInInTerminal(info.account) }
                }
                if model.canRemove(info.account) {
                    Divider()
                    Button(info.account.isMain ? "Sign out" : "Remove", role: .destructive) { model.remove(info.account) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// The switch for agents in Claude Code, and whether Headroom's plugin is there.
struct AgentsSwitchSection: View {
    @Bindable var model: AppModel
    @State private var version: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.agentsEnabled }, set: { model.setAgents($0) })) {
                SettingLabel(icon: "sparkle", color: ProviderID.claude.brandColors[0], title: "Agents in Claude Code",
                             tip: "Subagents run on whichever Claude account has the most left, and your other plans become agents Claude can call. Adds Headroom's plugin to Claude Code.",
                             detail: model.claudeError ?? status, detailColor: model.claudeError == nil && version != "" ? .secondary : .orange)
            }
            .disabled(version == "")
        }
        .task { version = await Task.detached { SubagentRunner.executable().map(SelfTest.version) ?? "" }.value }
    }

    private var status: String {
        guard let version else { return "Looking for Claude Code…" }
        if version.isEmpty { return "Claude Code not found" }
        let claude = version.replacingOccurrences(of: " (Claude Code)", with: "")
        return model.subagentsInstalled ? "Plugin installed · Claude Code \(claude)" : "Claude Code \(claude)"
    }
}

/// Save Claude usage, then the agents list with its editor.
struct AgentsSections: View {
    @Bindable var model: AppModel
    @State private var catalog = AgentCatalog.load()
    @State private var editing: AgentDefinition?
    @State private var editingPrompt = false
    @State private var error: String?

    var body: some View {
        Group {
            Section {
                Toggle(isOn: Binding(get: { catalog.saveClaude }, set: { on in change { $0.saveClaude = on } })) {
                    SettingLabel(icon: "leaf.fill", color: .green, title: "Save Claude usage",
                                 tip: catalog.enabled.isEmpty ? "Add an agent first." : SaveClaudeToggle.about)
                }
                .disabled(catalog.enabled.isEmpty && !catalog.saveClaude)
                HStack {
                    SettingLabel(icon: "text.quote", title: "Prompt", detail: catalog.saveClaudeText == nil ? "Default" : "Custom")
                    Spacer()
                    Button("Edit…") { editingPrompt = true }
                }
            }
            .sheet(isPresented: $editingPrompt) { SavingInstructionEditor(catalog: catalog) { catalog = AgentCatalog.load() } }
            Section {
                ForEach(catalog.agents) { agent in row(agent) }
                if catalog.agents.isEmpty { Caption("No agents yet.") }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                HStack(spacing: 4) {
                    Text("Your agents")
                    InfoTip("Agents run on your other plans. Claude Code calls them as headroom:<name> and picks one by its description. Changes apply from the next prompt.")
                    Spacer()
                    Button("New agent…") { editing = AgentDefinition(name: "", description: "", provider: .codex, model: "") }
                }
            }
        }
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent, catalog: catalog) { saved in
                change { next in
                    if let i = next.agents.firstIndex(where: { $0.id == saved.id }) { next.agents[i] = saved } else { next.agents.append(saved) }
                }
            }
        }
    }

    private func row(_ agent: AgentDefinition) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).fontWeight(.medium)
                    Text(agent.type).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    InfoTip(agent.description)
                }
                AgentBadges(agent: agent).padding(.top, 2)
                if let problem = model.agentProblem(agent.provider) {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { agent.enabled }, set: { on in change { next in
                if let i = next.agents.firstIndex(where: { $0.id == agent.id }) { next.agents[i].enabled = on }
            } }))
            .toggleStyle(.switch)
            .labelsHidden()
            Menu {
                Button("Edit…") { editing = agent }
                Divider()
                Button("Remove", role: .destructive) { change { $0.agents.removeAll { $0.id == agent.id } } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Saves the list, which the plugin reads on the next prompt.
    private func change(_ edit: (inout AgentCatalog) -> Void) {
        var next = AgentCatalog.load()
        edit(&next)
        do {
            try next.save()
            catalog = AgentCatalog.load()
            error = nil
        } catch {
            self.error = "Couldn't save the agents: \(error.localizedDescription)"
        }
    }
}

/// When to stop sending subagents to a Claude account; only with more than one.
struct ClaudeAccountsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.agentsEnabled && model.accounts(.claude).count > 1 {
            Section {
                threshold("Use until the session has", \.sessionThreshold) { model.setThresholds(session: $0) }
                threshold("Use until the week has", \.weeklyThreshold) { model.setThresholds(weekly: $0) }
            } header: {
                HStack(spacing: 4) {
                    Text("Claude accounts")
                    InfoTip("Subagents go to the account with the most left, and skip one with less left than this. A session never sends subagents to its own account.")
                }
            }
        }
    }

    private func threshold(_ title: String, _ key: KeyPath<AccountsConfig, Double>, set: @escaping (Double) -> Void) -> some View {
        Picker(title, selection: Binding(get: { model.accountsConfig[keyPath: key] }, set: set)) {
            // Stored as the share used, shown as what's left.
            ForEach([0.5, 0.75, 0.9, 0.95], id: \.self) { Text("\(Int(((1 - $0) * 100).rounded()))% left").tag($0) }
        }
    }
}
