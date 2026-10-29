import SwiftUI

/// First launch: the same sections as Settings, one step at a time, each with a word on what it's for.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: Step

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

    private var steps: [Step] { [.features, .accounts] + (model.showsAgents ? [.claudeCode] : []) + (model.showsLimits ? [.menuBar] : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            Form {
                switch step {
                case .features: FeaturesSection(model: model)
                case .accounts: AccountsSections(model: model, listsOthers: true)
                case .claudeCode:
                    PluginSection(model: model)
                    AgentsSections(model: model)
                case .menuBar:
                    MenuBarSection(model: model)
                    StartupSection(model: model)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(steps, id: \.self) { Circle().fill($0 == step ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 6, height: 6) }
                }
                Spacer()
                if step != .features { Button("Back") { move(-1) } }
                Button(step == steps.last ? "Done" : "Continue") { move(1) }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .task(id: step) {
            // Agents need the plugin: install it as the step opens, so the step shows it working.
            if step == .claudeCode, !model.subagentsInstalled, model.claudeError == nil { model.setFeature(.agents, true) }
        }
    }

    private var title: String {
        switch step {
        case .features: "Welcome to Headroom"
        case .accounts: "Connect your accounts"
        case .claudeCode: "Set up Claude Code"
        case .menuBar: "Headroom is in your menu bar"
        }
    }

    private var detail: String {
        switch step {
        case .features: "Choose what you want Headroom to do. You can change this any time in Settings."
        case .accounts: "Logins already on this Mac are listed. Add the other plans you pay for, or a second account of one you have."
        case .claudeCode: "Headroom's plugin lets Claude Code run subagents on your other accounts. Add agents to hand work to your other plans."
        case .menuBar: "Click it to see every limit. On a Mac with a notch, macOS hides menu bar items that don't fit: ⌘-drag other items away if you can't find it."
        }
    }

    private func move(_ offset: Int) {
        let steps = self.steps
        guard let i = steps.firstIndex(of: step) else { step = .features; return }
        if i + offset >= steps.count {
            model.defaults.set(true, forKey: Self.doneKey)
            WindowPresenter.close("setup")
        } else if i + offset >= 0 {
            step = steps[i + offset]
        }
    }
}
