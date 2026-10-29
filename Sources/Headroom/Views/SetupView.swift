import SwiftUI

/// First launch: choose features, connect accounts, then set up Claude Code or the menu bar.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: Step
    @State private var limits = true
    @State private var agents = true
    @State private var connecting: ProviderID?
    @State private var claudeVersion: String?

    enum Step: Int { case features, accounts, claudeCode, menuBar }

    init(model: AppModel, step: Step = .features) {
        self.model = model
        _step = State(initialValue: step)
    }

    static let doneKey = "setupDone"

    /// Shows setup on a fresh install. An install from before setup existed counts as set up.
    static func showIfNeeded(_ model: AppModel) {
        let defaults = model.defaults
        guard !defaults.bool(forKey: doneKey) else { return }
        let existing = defaults.object(forKey: "providerOrder") != nil
            || FileManager.default.fileExists(atPath: HeadroomPaths.accounts.path)
            || FileManager.default.fileExists(atPath: HeadroomPaths.accountsConfig.path)
        if existing { defaults.set(true, forKey: doneKey) } else { WindowPresenter.setup(model) }
    }

    private var steps: [Step] { [.features, .accounts] + (agents ? [.claudeCode] : []) + (limits ? [.menuBar] : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .features: features
                case .accounts: accounts
                case .claudeCode: claudeCode
                case .menuBar: menuBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 36)
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { Circle().fill($0 == step ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 6, height: 6) }
                }
                Spacer()
                if step != .features { Button("Back") { move(-1) } }
                Button(step == steps.last ? "Done" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!limits && !agents)
            }
            .padding(16)
        }
        .frame(width: 600, height: 520)
        .sheet(item: $connecting) { provider in AddAccountSheet(model: model, provider: provider) }
        .onAppear {
            limits = model.showsLimits
            agents = model.showsAgents || !model.defaults.bool(forKey: Self.doneKey)
        }
    }

    private func move(_ offset: Int) {
        if step == .features {
            if limits != model.showsLimits { model.setFeature(.limits, limits) }
            if agents != model.showsAgents { model.setFeature(.agents, agents) }
        }
        let steps = self.steps
        guard let i = steps.firstIndex(of: step) else { return }
        if i + offset >= steps.count {
            model.defaults.set(true, forKey: Self.doneKey)
            WindowPresenter.close("setup")
        } else if i + offset >= 0 {
            step = steps[i + offset]
        }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.largeTitle.weight(.bold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    // MARK: Steps

    private var features: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Welcome to Headroom", "Choose what you want it to do. You can change this any time in Settings.")
            HStack(alignment: .top, spacing: 12) {
                card(isOn: $limits, icon: "gauge.with.dots.needle.50percent", title: "See your limits",
                     text: "What's left of every plan's session and weekly limits, in the menu bar.")
                card(isOn: $agents, icon: "sparkle", title: "More agents in Claude Code",
                     text: "Subagents run on whichever Claude account has room, and your other plans become agents Claude can call.")
            }
        }
    }

    private func card(isOn: Binding<Bool>, icon: String, title: String, text: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.title).foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                }
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(isOn.wrappedValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn.wrappedValue ? Color.accentColor : .secondary.opacity(0.25), lineWidth: isOn.wrappedValue ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Connect your accounts", "Logins already on this Mac are connected. Add the others you want to use.")
            VStack(spacing: 0) {
                ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider().padding(.leading, 50) }
                    providerRow(provider)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button("Add Another Account…") { connecting = .claude }
                .buttonStyle(.link)
                .padding(.top, 10)
        }
    }

    private func providerRow(_ provider: ProviderID) -> some View {
        let accounts = model.accounts(provider)
        return HStack(spacing: 10) {
            ProviderTile(id: provider)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(provider.displayName).fontWeight(.medium)
                    ForEach(accounts.compactMap(\.plan), id: \.self) { PlanChip(text: $0) }
                }
                Caption(accounts.isEmpty ? provider.planHint : accounts.compactMap(\.email).first ?? "Found on this Mac")
            }
            Spacer()
            if accounts.isEmpty {
                Button(provider.signsInWithBrowser ? "Sign In" : "Add Key") { connecting = provider }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var claudeCode: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Set up Claude Code", "Headroom adds a plugin to Claude Code for all your sessions. Turning agents off removes it.")
            VStack(alignment: .leading, spacing: 12) {
                check(claudeVersion.map { !$0.isEmpty } ?? nil,
                      claudeVersion.map { $0.isEmpty ? "Claude Code not found: install it, then reopen setup" : "Claude Code \($0.replacingOccurrences(of: " (Claude Code)", with: "")) found" }
                        ?? "Looking for Claude Code…")
                check(model.subagentsInstalled ? true : model.claudeError == nil ? nil : false,
                      model.subagentsInstalled ? "Plugin installed" : model.claudeError ?? "Installing the plugin…")
                let claude = model.accounts(.claude).count
                check(true, claude > 1 ? "Subagents will run on whichever of your \(claude) Claude accounts has the most room"
                                       : "Add another Claude account to run subagents on the one with room")
            }
            Caption("Add agents on your other plans in Settings → Claude Code.").padding(.top, 20)
        }
        .task {
            claudeVersion = await Task.detached { SubagentRunner.executable().map(SelfTest.version) ?? "" }.value
            if !model.subagentsInstalled && model.claudeError == nil { model.setFeature(.agents, true) }
        }
    }

    private func check(_ ok: Bool?, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch ok {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case nil: ProgressView().controlSize(.small)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Headroom is in your menu bar",
                  "Click it to see every limit. On a Mac with a notch, macOS hides menu bar items that don't fit: ⌘-drag other items away if you can't find it.")
            Form {
                Picker("Menu bar shows", selection: $model.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(!AppModel.isBundled)
                Toggle("Notify when a limit is reached", isOn: $model.notificationsOn)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
        }
    }
}

