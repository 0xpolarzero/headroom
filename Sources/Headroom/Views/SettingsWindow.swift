import AppKit
import SwiftUI

/// Settings and first-launch setup, each in a window of its own: the panel only shows usage.
@MainActor
enum WindowPresenter {
    private static var windows: [String: NSWindow] = [:]

    static func settings(_ model: AppModel, page: SettingsPage? = nil) {
        if let page { model.settingsPage = page }
        show("settings", title: "Headroom Settings", size: NSSize(width: 720, height: 560)) { SettingsView(model: model) }
    }

    static func setup(_ model: AppModel) {
        show("setup", title: "Welcome to Headroom", size: NSSize(width: 600, height: 520), resizable: false) { SetupView(model: model) }
    }

    static func close(_ name: String) { windows[name]?.close() }

    private static func show(_ name: String, title: String, size: NSSize, resizable: Bool = true, content: () -> some View) {
        if let window = windows[name] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.center()
        windows[name] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, accounts, limits, claudeCode
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .limits: "Limits"
        case .claudeCode: "Claude Code"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .limits: "gauge.with.dots.needle.50percent"
        case .claudeCode: "sparkle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .accounts: .blue
        case .limits: .green
        case .claudeCode: ProviderID.claude.brandColors[0]
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pages) { page in
                    Button { model.settingsPage = page } label: {
                        HStack(spacing: 8) {
                            Image(systemName: page.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            Text(page.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(page == current ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .frame(width: 190)
            .background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(current.title).font(.title3.weight(.semibold)).padding(.leading, 20).padding(.top, 14).frame(height: 44, alignment: .bottom)
                Group {
                    switch current {
                    case .general: GeneralPage(model: model)
                    case .accounts: AccountsPage(model: model)
                    case .limits: LimitsPage(model: model)
                    case .claudeCode: ClaudeCodePage(model: model)
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var current: SettingsPage { pages.contains(model.settingsPage) ? model.settingsPage : .general }

    /// Only the pages of the features that are on.
    private var pages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .limits: model.showsLimits
            case .claudeCode: model.showsAgents
            case .general, .accounts: true
            }
        }
    }
}

// MARK: General

private struct GeneralPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: feature(.limits)) {
                    Text("Limits in the menu bar")
                    Text("What's left of every plan's session and weekly limits.")
                }
                Toggle(isOn: feature(.agents)) {
                    Text("Agents in Claude Code")
                    Text("Subagents run on the Claude account with room, and your other plans become agents. Installs Headroom's plugin for Claude Code.")
                }
                if let error = model.claudeError { Text(error).foregroundStyle(.red).font(.caption) }
            } header: {
                Text("Features")
            } footer: {
                Caption("At least one stays on.")
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(!AppModel.isBundled)
                if let error = model.launchAtLoginError { Caption(error) }
                Toggle("Notify when a limit is reached", isOn: $model.notificationsOn)
            }
            Section {
                Button("Run Setup Again…") { WindowPresenter.close("settings"); WindowPresenter.setup(model) }
            }
        }
    }

    private func feature(_ feature: Feature) -> Binding<Bool> {
        Binding(get: { model.features.contains(feature) }, set: { model.setFeature(feature, $0) })
    }
}

// MARK: Accounts

private struct AccountsPage: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var renaming: AccountInfo?
    @State private var newName = ""

    var body: some View {
        Form {
            ForEach(model.connectedProviders) { provider in
                let accounts = model.accounts(provider)
                Section {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, info in
                        row(info, index: index, count: accounts.count)
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    if accounts.count > 1 { Caption(footer(provider)) }
                }
            }
            Section {
                HStack {
                    if model.connectedProviders.isEmpty { Caption("Add the plans you use: Claude, Codex, Antigravity, Z.ai or OpenRouter.") }
                    Spacer()
                    Button("Add Account…") { model.connectStatus = .idle; adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
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
                    Caption(email)
                }
            }
            Spacer()
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

// MARK: Limits

private struct LimitsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Shows", selection: $model.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(model.connectedProviders) { provider in
                    Toggle(isOn: Binding(get: { model.showsInMenuBar(provider) }, set: { model.setShowsInMenuBar(provider, $0) })) {
                        HStack(spacing: 8) {
                            ProviderLogo(id: provider, size: 14)
                            Text(provider.displayName)
                        }
                    }
                }
            }
            Section {
                Toggle("Notify when a limit is reached", isOn: $model.notificationsOn)
            } footer: {
                Caption("On a Mac with a notch, Headroom shortens the menu bar item, then shows a gauge, when there isn't room for every provider.")
            }
        }
    }
}

// MARK: Claude Code

private struct ClaudeCodePage: View {
    @Bindable var model: AppModel
    @State private var catalog = AgentCatalog.load()
    @State private var editing: AgentDefinition?
    @State private var error: String?
    @State private var version = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: model.subagentsInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(model.subagentsInstalled ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.subagentsInstalled ? "Connected to Claude Code" : "Headroom's plugin isn't installed").fontWeight(.medium)
                        Caption(statusDetail)
                    }
                    Spacer()
                    if !model.subagentsInstalled { Button("Install") { model.setFeature(.agents, true) } }
                }
                if let error = model.claudeError { Text(error).font(.caption).foregroundStyle(.red) }
            }

            Section {
                SaveClaudeToggle(catalog: catalog) { catalog = AgentCatalog.load() }
            }

            Section {
                ForEach(catalog.agents) { agent in
                    HStack(spacing: 10) {
                        ProviderLogo(id: agent.provider.usageID, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name).fontWeight(.medium)
                                Text(agent.type).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                            Caption(agent.description)
                            if let problem = model.agentProblem(agent.provider) {
                                Text(problem).font(.caption).foregroundStyle(.orange)
                            } else {
                                Caption(agent.summary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { agent.enabled }, set: { on in change { $0.agents[index(agent)].enabled = on } }))
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

            if model.accounts(.claude).count > 1 {
                Section {
                    threshold("Use until its session is", \.sessionThreshold) { model.setThresholds(session: $0) }
                    threshold("Use until its week is", \.weeklyThreshold) { model.setThresholds(weekly: $0) }
                } header: {
                    Text("Claude accounts")
                } footer: {
                    Caption("A subagent runs on the account with the most room, and skips one past either limit. A session never sends subagents to its own account.")
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
        .task { version = await Task.detached { SubagentRunner.executable().map(SelfTest.version) ?? "" }.value }
    }

    private var statusDetail: String {
        guard model.subagentsInstalled else { return "Agents need it. It's added to ~/.claude/settings.json for all your sessions." }
        let tested = (try? Data(contentsOf: HeadroomPaths.selfTest)).flatMap { try? JSONDecoder.headroom.decode(SelfTest.Record.self, from: $0) }
        let claude = version.isEmpty ? "Claude Code" : version.replacingOccurrences(of: " (Claude Code)", with: "")
        let test = tested.map { $0.version == version ? " · test passed \(Format.clock($0.at))" : "" } ?? ""
        return "Plugin installed · \(claude)\(test)"
    }

    private func index(_ agent: AgentDefinition) -> Int { catalog.agents.firstIndex { $0.id == agent.id } ?? 0 }

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

    private func threshold(_ title: String, _ key: KeyPath<AccountsConfig, Double>, set: @escaping (Double) -> Void) -> some View {
        Picker(title, selection: Binding(get: { model.accountsConfig[keyPath: key] }, set: set)) {
            ForEach([0.5, 0.75, 0.9, 0.95], id: \.self) { Text("\(Int($0 * 100))% used").tag($0) }
        }
    }
}
