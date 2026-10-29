import SwiftUI

// The pieces Settings and first-launch setup share, so each setting looks and works the same in both.
// Each is one or more Form sections.

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
                    Text(provider.displayName)
                } footer: {
                    if accounts.count > 1 && model.showsAgents { Caption(footer(provider)) }
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
                            Button(provider.signsInWithBrowser ? "Sign In…" : "Add Key…") { model.connectStatus = .idle; connecting = provider }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                HStack {
                    Caption(model.connectedProviders.isEmpty ? "Add the plans you use: Claude, Codex, Antigravity, Z.ai or OpenRouter."
                                                             : "Add another plan, or a second account of one you have.")
                    Spacer()
                    Button("Add Account…") { model.connectStatus = .idle; adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .sheet(item: $connecting) { provider in AddAccountSheet(model: model, provider: provider) }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func footer(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "Subagents run on the account with the most room. This order breaks ties."
        case .antigravity: "Agents use the first account: the Antigravity CLI signs in one account per Mac."
        default: "Agents run on the account with the most room. This order breaks ties."
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
                    Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if let email = info.email {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                Picker("Menu bar", selection: Binding(get: { info.account.menuBar }, set: { model.setMenuBar(info.id, $0) })) {
                    Text("Not shown").tag(MenuBarMode?.none)
                    Divider()
                    if info.account.provider == .openrouter {
                        Text("Credits").tag(MenuBarMode?.some(.session))
                    } else {
                        ForEach(MenuBarMode.allCases) { Text($0 == .both ? "Session and Weekly" : $0.title).tag(MenuBarMode?.some($0)) }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("What this account shows in the menu bar")
            HStack(spacing: 4) {
                Image(systemName: info.account.notifyAt == nil ? "bell.slash" : "bell").foregroundStyle(.secondary)
                Picker("Notify", selection: Binding(get: { info.account.notifyAt }, set: { model.setNotify(info.id, $0) })) {
                    Text("Off").tag(Double?.none)
                    Divider()
                    ForEach(Account.notifyChoices, id: \.self) { Text(Account.notifyTitle($0)).tag(Double?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("Notify when this little is left of its session or weekly limit")
            Menu {
                Button("Rename…") { newName = info.name; renaming = info }
                if count > 1 {
                    Button("Move Up") { model.moveAccount(info.id, by: -1) }.disabled(index == 0)
                    Button("Move Down") { model.moveAccount(info.id, by: 1) }.disabled(index == count - 1)
                }
                if info.account.provider == .claude {
                    Button("Sign In Again in Terminal") { model.signInInTerminal(info.account) }
                }
                if model.canRemove(info.account) {
                    Divider()
                    Button(info.account.isMain ? "Sign Out" : "Remove", role: .destructive) { model.remove(info.account) }
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
                Label {
                    Text("Agents in Claude Code")
                    Text("Subagents run on whichever Claude account has room, and your other plans become agents Claude can call.")
                } icon: {
                    Image(systemName: "sparkle").foregroundStyle(ProviderID.claude.brandColors[0])
                }
            }
            .disabled(version == "")
            HStack(spacing: 6) {
                Image(systemName: icon.name).foregroundStyle(icon.color)
                Caption(status)
            }
            if let error = model.claudeError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task { version = await Task.detached { SubagentRunner.executable().map(SelfTest.version) ?? "" }.value }
    }

    private var icon: (name: String, color: Color) {
        if version == "" { return ("exclamationmark.triangle.fill", .orange) }
        return model.subagentsInstalled ? ("checkmark.circle.fill", .green) : ("circle", .secondary)
    }

    private var status: String {
        guard let version else { return "Looking for Claude Code…" }
        if version.isEmpty { return "Claude Code isn't installed. Install it, then come back here." }
        let claude = version.replacingOccurrences(of: " (Claude Code)", with: "")
        guard model.subagentsInstalled else {
            return "Claude Code \(claude). Turning this on adds Headroom's plugin to ~/.claude/settings.json for all your sessions."
        }
        let tested = (try? Data(contentsOf: HeadroomPaths.selfTest)).flatMap { try? JSONDecoder.headroom.decode(SelfTest.Record.self, from: $0) }
        let test = tested.map { $0.version == version ? " · test passed \(Format.clock($0.at))" : "" } ?? ""
        return "Plugin installed in Claude Code \(claude)\(test)"
    }
}

/// Save Claude usage, then the agents list with its editor.
struct AgentsSections: View {
    @Bindable var model: AppModel
    @State private var catalog = AgentCatalog.load()
    @State private var editing: AgentDefinition?
    @State private var error: String?

    var body: some View {
        Group {
            Section {
                SaveClaudeToggle(catalog: catalog) { catalog = AgentCatalog.load() }
            }
            Section {
                ForEach(catalog.agents) { agent in row(agent) }
                if catalog.agents.isEmpty {
                    Caption("Agents run on your other plans and show up in Claude Code as headroom:<name>, next to its own agents.")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
                    Button("New Agent…") { editing = AgentDefinition(name: "", description: "", provider: .codex, model: "") }
                        .controlSize(.small)
                }
            } footer: {
                Caption("Claude picks an agent by its description. Changes apply from the next prompt, in every session.")
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
                }
                Caption(agent.description)
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
                threshold("Use until its session has", \.sessionThreshold) { model.setThresholds(session: $0) }
                threshold("Use until its week has", \.weeklyThreshold) { model.setThresholds(weekly: $0) }
            } header: {
                Text("Claude accounts")
            } footer: {
                Caption("A subagent runs on the account with the most left, and skips one with less left than this. A session never sends subagents to its own account.")
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
