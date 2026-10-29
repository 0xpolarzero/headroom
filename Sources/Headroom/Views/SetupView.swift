import SwiftUI

/// First launch: the two Settings pages, one at a time, each with a word on what it's for.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: Step

    enum Step: Int, CaseIterable { case accounts, agents }

    init(model: AppModel, step: Step = .accounts) {
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

    private var steps: [Step] { Step.allCases }

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
                case .accounts: AccountsSections(model: model, listsOthers: true)
                case .agents:
                    AgentsSwitchSection(model: model)
                    if model.agentsEnabled { AgentsSections(model: model) }
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
                if step != .accounts { Button("Back") { move(-1) } }
                Button(step == steps.last ? "Done" : "Continue") { move(1) }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
    }

    private var title: String {
        switch step {
        case .accounts: "Welcome to Headroom"
        case .agents: "Agents"
        }
    }

    private var detail: String {
        switch step {
        case .accounts: "See what's left of your AI plans. Logins on this Mac are already here."
        case .agents: "Optional. Get more out of your plans in Claude Code."
        }
    }

    private func move(_ offset: Int) {
        let steps = self.steps
        guard let i = steps.firstIndex(of: step) else { step = .accounts; return }
        if i + offset >= steps.count {
            model.defaults.set(true, forKey: Self.doneKey)
            WindowPresenter.close("setup")
        } else if i + offset >= 0 {
            step = steps[i + offset]
        }
    }
}
