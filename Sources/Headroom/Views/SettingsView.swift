import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var openRouterKey = ""
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

/// The Claude accounts in priority order: each one's window and Terminal sign-in, adding and
/// removing accounts, and when new sessions should move on to the next account.
struct ClaudeAccountsSettings: View {
    @Bindable var model: AppModel
    @Binding var name: String

    var body: some View {
        let rows = model.claudeRows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 6) {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                Text(row.name).lineLimit(1)
                if row.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                if let email = row.email { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button { model.moveClaudeAccount(row.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Suggest earlier")
                Button { model.moveClaudeAccount(row.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == rows.count - 1)
                    .help("Suggest later")
                Menu {
                    Button(row.isRunning ? "Show its Claude window" : "Open its Claude window") { model.openClaudeWindow(row.id) }
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
        Text("""
            Each account gets its own Claude window, with its own sign-in and sessions; settings, skills, hooks \
            and plugins in ~/.claude are shared, and session presets are kept in sync. To sign a new window in, \
            quit your main Claude app first (the sign-in link goes to whichever copy is open), sign in, then \
            reopen Claude from here. Then sign in once in Terminal so Headroom can show its usage.
            """)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        HStack {
            Text("Suggest the next account at")
            Spacer()
            Picker("Suggest the next account at", selection: Binding(
                get: { model.claudeConfig.newSessionThreshold }, set: { model.setNewSessionThreshold($0) })) {
                ForEach([0.75, 0.85, 0.95], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                Text("Its limit").tag(1.0)
            }
            .labelsHidden()
            .fixedSize()
        }
        Text("New sessions are suggested on the first account below this share of its Session or Weekly limit. A running session stays on its account.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let error = model.claudeError {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        model.addClaudeAccount(name: name)
        if model.claudeError == nil { name = "" }
    }
}
