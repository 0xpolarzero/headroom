import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var openRouterKey = ""
    @State private var zaiKey = ""
    @State private var claudeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { model.showingSettings = false }
                    .buttonStyle(.borderless)
            }

            section("Providers") {
                ForEach(Array(model.order.enumerated()), id: \.element) { index, id in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { model.isEnabled(id) },
                            set: { model.setEnabled(id, $0) })) {
                            Label {
                                Text(id.displayName)
                            } icon: {
                                Image(nsImage: Logos.image(id)).renderingMode(.template).resizable().frame(width: 14, height: 14)
                            }
                        }
                        Spacer()
                        Button { model.move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move up")
                        Button { model.move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == model.order.count - 1)
                            .help("Move down")
                    }
                    .buttonStyle(.borderless)
                }
            }

            section("Menu bar") {
                Picker("Menu bar", selection: $model.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            section("Claude accounts") {
                ClaudeAccountsSettings(model: model, name: $claudeName)
            }

            section("Agents") {
                AgentsSettings()
            }

            section("Accounts") {
                account(.antigravity) {
                    if model.antigravitySigningIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", action: model.cancelSignIn)
                    } else if model.antigravitySignedIn {
                        Text(model.antigravityEmail ?? "Signed in").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Sign out", action: model.signOutAntigravity)
                    } else {
                        Text("Antigravity app").foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign in with Google", action: model.signInAntigravity)
                    }
                }
                account(.zai) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(model.zaiSignedIn ? "Signed in" : "Not signed in").foregroundStyle(.secondary)
                            Spacer()
                            if model.zaiSignedIn {
                                Button("Sign out", action: model.signOutZAI)
                            } else {
                                Button("Sign in", action: model.signInZAI)
                            }
                        }
                        HStack {
                            if model.hasZAIKey {
                                Text("Coding Plan API key saved").foregroundStyle(.secondary)
                                Spacer()
                                Button("Remove key", role: .destructive, action: model.removeZAIKey)
                            } else {
                                SecureField("Coding Plan API key", text: $zaiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(saveZAI)
                                Button("Save", action: saveZAI)
                                    .disabled(zaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        Text("Agents need a Coding Plan API key; website sign-in only reads usage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                account(.openrouter) {
                    if model.hasOpenRouterKey {
                        Text("API key saved").foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive, action: model.removeOpenRouterKey)
                    } else {
                        SecureField("API key", text: $openRouterKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveOpenRouter)
                        Button("Save", action: saveOpenRouter)
                            .disabled(openRouterKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !model.hasOpenRouterKey {
                    Text("A management key also lists the usage of every key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.accountError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(!AppModel.isBundled)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else if !AppModel.isBundled {
                    Text("Available when running Headroom.app.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Notify when a limit is reached", isOn: $model.notificationsOn)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
    }

    private func saveZAI() {
        model.saveZAIKey(zaiKey)
        zaiKey = ""
    }

    private func saveOpenRouter() {
        model.saveOpenRouterKey(openRouterKey)
        openRouterKey = ""
    }

    private func account(_ id: ProviderID, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: Logos.image(id)).renderingMode(.template).resizable().frame(width: 14, height: 14)
            Text(id.displayName).frame(width: 74, alignment: .leading)
            content()
        }
        .buttonStyle(.borderless)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// The Claude accounts: their order, signing them in, adding and removing them, and the subagents that
/// run on the ones with room.
struct ClaudeAccountsSettings: View {
    @Bindable var model: AppModel
    @Binding var name: String

    var body: some View {
        let rows = model.claudeRows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 6) {
                Text(row.name).lineLimit(1)
                if row.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                if let email = row.email { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button { model.moveClaudeAccount(row.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { model.moveClaudeAccount(row.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == rows.count - 1)
                    .help("Move down")
                Menu {
                    Button("Sign in in Terminal") { model.signInTerminal(row.id) }
                    if !row.isMain {
                        Divider()
                        Button("Remove", role: .destructive) { model.removeClaudeAccount(row.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
        }

        HStack(spacing: 6) {
            TextField("Name, e.g. Pro", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add account", action: add)
                .disabled(ClaudeAccount.slug(name).isEmpty)
        }
        .buttonStyle(.borderless)
        Text("Opens Terminal on Claude Code in the account's own folder (~/.claude-accounts/<name>), sharing your settings, skills, hooks and plugins. Sign in there with that account.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Run subagents on accounts with room", isOn: Binding(
            get: { model.subagentsInstalled }, set: { model.setSubagentsInstalled($0) }))
        Text("Installs Headroom's Claude Code plugin. When another of your accounts has room, a session's subagents run there, exactly like built-in ones; otherwise they run as usual.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        threshold("Up to Session", \.sessionThreshold) { model.setThresholds(session: $0) }
        threshold("Up to Weekly", \.weeklyThreshold) { model.setThresholds(weekly: $0) }
        if let error = model.claudeError {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func threshold(_ label: String, _ key: KeyPath<ClaudeAccountsConfig, Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker(label, selection: Binding(get: { model.claudeConfig[keyPath: key] }, set: set)) {
                ForEach([0.5, 0.75, 0.9, 0.95], id: \.self) { Text("\(Int($0 * 100))% used").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .disabled(!model.subagentsInstalled)
    }

    private func add() {
        model.addClaudeAccount(name: name)
        if model.claudeError == nil { name = "" }
    }
}
