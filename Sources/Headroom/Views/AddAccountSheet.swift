import SwiftUI

extension ProviderID {
    /// The plan someone needs, as the add-account list says it.
    var planHint: String {
        switch self {
        case .claude: "Pro, Max or Team"
        case .codex: "Your ChatGPT plan"
        case .antigravity: "Google AI Pro or Ultra"
        case .zai: "GLM Coding Plan"
        case .openrouter: "Credits, any model"
        }
    }

    /// Signs in through the browser; the others take an API key.
    var signsInWithBrowser: Bool { [.claude, .codex, .antigravity].contains(self) }

    var signInTitle: String {
        switch self {
        case .claude: "Sign in with Claude"
        case .codex: "Sign in with ChatGPT"
        case .antigravity: "Sign in with Google"
        case .zai, .openrouter: "Connect"
        }
    }

    /// What to do, in a few words.
    var connectHint: String {
        switch self {
        case .claude: "Sign in on claude.ai with the account to add."
        case .codex: "Sign in on ChatGPT with the account to add."
        case .antigravity: "Sign in with the Google account that has the plan."
        case .zai: "Paste a Coding Plan API key."
        case .openrouter: "Paste an API key."
        }
    }

    /// The rest, for the ⓘ.
    var connectDetail: String {
        switch self {
        case .claude: "It gets its own sign-in and sessions, and shares your Claude Code settings, skills, agents and plugins."
        case .codex: "It gets its own Codex sign-in, and shares your Codex settings."
        case .antigravity: "Headroom reads the plan's limits with this sign-in."
        case .zai: "Find it at z.ai → API Keys. Standard keys bill your balance, not the plan."
        case .openrouter: "Find it at openrouter.ai/keys. A management key only reads spending and can't run agents."
        }
    }
}

/// Pick a provider, then sign in or paste a key. Shared by Settings and first-launch setup.
struct AddAccountSheet: View {
    @Bindable var model: AppModel
    @State var provider: ProviderID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let provider {
                ConnectProvider(model: model, provider: provider, back: { self.provider = nil; model.cancelConnect() }, done: { dismiss() })
            } else {
                picker
            }
        }
        .frame(width: 440)
        .onDisappear { model.cancelConnect() }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an account").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ProviderID.allCases) { id in
                    Button { model.connectStatus = .idle; model.lastConnected = nil; provider = id } label: {
                        HStack(spacing: 10) {
                            ProviderTile(id: id)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(id.displayName).fontWeight(.medium)
                                Caption(id.planHint)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}

/// One provider's sign-in: a button for the browser, or a key field; then what the account unlocked.
struct ConnectProvider: View {
    @Bindable var model: AppModel
    let provider: ProviderID
    var back: (() -> Void)?
    let done: () -> Void
    @State private var key = ""
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderTile(id: provider)
                Text(finished == nil ? "Add a \(provider.displayName) account" : "\(provider.displayName) connected").font(.title3.weight(.semibold))
            }
            if let info = finished {
                result(info)
            } else {
                form
            }
            HStack {
                if finished == nil, let back { Button("Back", action: back) }
                Spacer()
                if finished != nil {
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                } else if case .working = model.connectStatus {
                    Button("Cancel", role: .cancel) { model.cancelConnect() }.keyboardShortcut(.cancelAction)
                } else if provider.signsInWithBrowser {
                    Button(provider.signInTitle) { started = true; model.connectInBrowser(provider) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Connect") { started = true; model.connect(provider, key: key) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
    }

    /// The account just added, once its sign-in landed.
    private var finished: AccountInfo? {
        guard started, model.connectStatus == .idle, let id = model.lastConnected else { return nil }
        return model.allAccounts.first { $0.id == id } ?? model.accountsConfig.account(id).map { account in
            AccountInfo(account: account, name: model.displayName(account, plan: nil), state: model.state(of: account), limits: .pending)
        }
    }

    @ViewBuilder private var form: some View {
        HStack(spacing: 4) {
            Text(provider.connectHint).foregroundStyle(.secondary)
            InfoTip(provider.connectDetail)
        }
        if !provider.signsInWithBrowser {
            SecureField("API key", text: $key).textFieldStyle(.roundedBorder).onSubmit { started = true; model.connect(provider, key: key) }
        }
        switch model.connectStatus {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        case .failed(let text):
            Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
        if provider == .zai {
            HStack(spacing: 4) {
                Button("Use the website instead") { started = true; model.connectZAIWebsite() }
                    .buttonStyle(.link).font(.caption)
                InfoTip("Shows limits only: agents need a key.")
            }
        }
    }

    private func result(_ info: AccountInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(info.name).fontWeight(.medium)
                if let plan = info.plan, plan != info.name { PlanChip(text: plan) }
            }
            if let email = info.email { Caption(email) }
            VStack(alignment: .leading, spacing: 6) {
                line("Limits", info.limits, ready: "Headroom reads its limits.")
                if model.showsAgents, let text = agentsLine(info.account) { line("Agents", .ready, ready: text) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// What agents do with the account, when they use it.
    private func agentsLine(_ account: Account) -> String? {
        if provider == .claude { return "Subagents run on it when it has the most room." }
        guard let agentProvider = AgentProvider.allCases.first(where: { $0.usageID == provider }), AgentPool.pools(agentProvider) || account.isMain else { return nil }
        return "Your \(provider.displayName) agents can run on it."
    }

    private func line(_ title: String, _ capability: Capability, ready: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch capability {
            case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .pending: ProgressView().controlSize(.mini)
            }
            Text(title).fontWeight(.medium)
            Text(capability.problem ?? (capability == .pending ? "Checking…" : ready)).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
