import SwiftUI

/// The Claude card with several accounts: one block per account in the order set in Settings.
struct ClaudeAccountsSection: View {
    @Bindable var model: AppModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: Logos.image(.claude))
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(LinearGradient(colors: ProviderID.claude.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Claude").font(.headline)
                Spacer()
            }
            ForEach(model.claudeRows) { row in
                AccountBlock(row: row, now: now, showsSubagents: model.subagentsInstalled) { model.signInTerminal(row.id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ProviderID.claude.brandBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(ProviderID.claude.brandColors[0].opacity(0.25), lineWidth: 0.5))
    }
}

private struct AccountBlock: View {
    let row: ClaudeAccountRow
    let now: Date
    let showsSubagents: Bool
    let signIn: () -> Void
    @AppStorage private var showMore: Bool

    init(row: ClaudeAccountRow, now: Date, showsSubagents: Bool, signIn: @escaping () -> Void) {
        self.row = row
        self.now = now
        self.showsSubagents = showsSubagents
        self.signIn = signIn
        _showMore = AppStorage(wrappedValue: false, "showMore.claude.\(row.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.name).font(.subheadline.weight(.semibold))
                if let plan = row.plan, plan != row.name {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if row.isMain { Text("Main").font(.caption2).foregroundStyle(.secondary) }
                ResetBadge(resets: row.snapshot?.resets, now: now)
                Spacer()
                if showsSubagents && row.takesSubagents {
                    Text("Takes subagents").font(.caption2).foregroundStyle(.secondary)
                        .hoverTip("Below both thresholds, so sessions on your other accounts can run subagents on it.")
                }
            }
            if let email = row.email {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.top, -4)
            }
            if row.cliUUID == nil {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sign in once in Terminal so Headroom can read its usage.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign in", action: signIn).font(.caption).buttonStyle(.borderless)
                }
            } else if let snapshot = row.snapshot {
                let windows = ProviderSection.split(snapshot.windows)
                ForEach(windows.main, id: \.label) { WindowRow(window: $0, now: now) }
                if showMore { ForEach(windows.more, id: \.label) { WindowRow(window: $0, now: now) } }
                if !windows.more.isEmpty {
                    Caret(isExpanded: showMore) { showMore.toggle() }.padding(.bottom, -4)
                }
            } else if let error = row.error {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
