import SwiftUI

/// First launch: the two Settings pages, one at a time, each with a word on what it's for.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: Step
    @State private var adding = false

    enum Step: Int, CaseIterable { case accounts, agents }

    init(model: AppModel, step: Step = .accounts) {
        self.model = model
        _step = State(initialValue: step)
    }

    static let doneKey = "setupDone"

    /// Shows setup on a fresh install. An install from before setup existed counts as set up.
    static func showIfNeeded(_ model: AppModel) {
        guard !model.defaults.bool(forKey: doneKey) else { return }
        if model.isFreshInstall { WindowPresenter.setup(model) } else { model.defaults.set(true, forKey: doneKey) }
    }

    private var steps: [Step] { Step.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.weight(.bold))
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if step == .accounts { Button("Add account…") { model.connectStatus = .idle; adding = true } }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            // The list takes the room there is and scrolls; what's below stays in view.
            Form {
                switch step {
                case .accounts:
                    AccountsSections(model: model, listsOthers: true)
                case .agents:
                    AgentsSwitchSection(model: model)
                    if model.agentsEnabled {
                        SuggestedAgentsSection(model: model)
                        AgentsSections(model: model)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            if step == .accounts {
                LoginSwitch(model: model)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 8) {
                steps(current: step)
                Spacer()
                if step != .accounts { Button("Back") { move(-1) } }
                Button(step == steps.last ? "Done" : "Continue") { move(1) }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }

    /// "1 Accounts › 2 Agents", the current one in full color.
    private func steps(current: Step) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                HStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(step == current ? Color.white : .secondary)
                        .frame(width: 16, height: 16)
                        .background(step == current ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                    Text(step == .accounts ? "Accounts" : "Agents")
                        .font(.callout)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
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
