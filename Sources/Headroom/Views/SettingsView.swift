import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var openRouterKey = ""
    @State private var claudeEmail = ""

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
                ClaudeAccountsSettings(model: model, email: $claudeEmail)
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
                    Text(model.zaiSignedIn ? "Signed in" : "Not signed in").foregroundStyle(.secondary)
                    Spacer()
                    if model.zaiSignedIn {
                        Button("Sign out", action: model.signOutZAI)
                    } else {
                        Button("Sign in", action: model.signInZAI)
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

/// The priority order of Claude accounts, adding and removing them, and the switch that routes
/// Claude Code through Headroom.
struct ClaudeAccountsSettings: View {
    @Bindable var model: AppModel
    @Binding var email: String

    var body: some View {
        let rows = model.claudeRows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 6) {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if row.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                if let plan = row.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.moveClaudeAccount(row.ref, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Use earlier")
                Button { model.moveClaudeAccount(row.ref, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == rows.count - 1)
                    .help("Use later")
                Menu {
                    Toggle("Use extra usage past the limit", isOn: Binding(
                        get: { row.allowOverage }, set: { model.setAllowOverage(row.ref, $0) }))
                    if case .extra(let uuid) = row.ref {
                        Divider()
                        Button("Sign in again") { model.addClaudeAccount(loginHint: row.name) }
                        Button("Remove", role: .destructive) { model.removeClaudeAccount(uuid) }
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
            if model.claudeSigningIn {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancelClaudeSignIn)
            } else {
                TextField("Email (optional)", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add account", action: add)
            }
        }
        .buttonStyle(.borderless)
        Text("Signs in to another Claude account in a private window. The account the Claude app uses is already in the list as Main.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        HStack {
            Text("New sessions skip an account at")
            Spacer()
            Picker("New sessions skip an account at", selection: Binding(
                get: { model.claudeConfig.newSessionThreshold }, set: { model.setNewSessionThreshold($0) })) {
                ForEach([0.75, 0.85, 0.95], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                Text("Its limit").tag(1.0)
            }
            .labelsHidden()
            .fixedSize()
        }
        Text("A running session stays on its account while its cache is warm, so the conversation isn't read again at full price. New sessions leave an account once it reaches this share of its Session or Weekly limit, keeping the rest for the sessions already on it.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Switch Claude Code between accounts", isOn: Binding(
            get: { model.claudeConfig.routing }, set: { model.setRouting($0) }))
            .disabled(model.routingBusy)
        Text(routingHelp)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if model.claudeConfig.routing && !model.relayHealthy && !model.routingBusy {
            Text("The relay is not running, so Claude Code can't connect. Turn the switch off and on, or see ~/Library/Logs/Headroom/relay.log.")
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.claudeError {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var routingHelp: String {
        "New sessions start on the first account with room left. A session moves down the list only when its "
            + "account runs out, and back up once its cache has gone cold. Adds HTTPS_PROXY to ~/.claude/settings.json; "
            + "sessions started after that take part. Anthropic's terms forbid bypassing usage limits, so use it at your own risk."
    }

    private func add() {
        model.addClaudeAccount(loginHint: email)
        email = ""
    }
}
