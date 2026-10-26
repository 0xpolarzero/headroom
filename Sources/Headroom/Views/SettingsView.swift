import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var zaiKey = ""

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

            section("Z.ai API key") {
                if model.hasZAIKey {
                    HStack {
                        Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeZAIKey() }
                            .buttonStyle(.borderless)
                    }
                } else {
                    HStack {
                        SecureField("Paste your API key", text: $zaiKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(zaiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
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

    private func save() {
        model.saveZAIKey(zaiKey)
        zaiKey = ""
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
