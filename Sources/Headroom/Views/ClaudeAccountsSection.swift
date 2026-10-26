import SwiftUI

/// The Claude card with several accounts: one block per account in priority order, with a button to
/// open its Claude window and a mark on the one new sessions should use.
struct ClaudeAccountsSection: View {
    @Bindable var model: AppModel
    let now: Date

    var body: some View {
        let rows = model.claudeRows
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
            ForEach(rows) { row in
                AccountBlock(row: row, now: now, open: { model.openClaudeWindow(row.id) },
                             signIn: { model.signInTerminal(row.id) })
            }
            if !rows.contains(where: \.isRecommended), rows.contains(where: { $0.used != nil }) {
                Text("Every account is at its limit.").font(.caption).foregroundStyle(.secondary)
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
    let open: () -> Void
    let signIn: () -> Void
    @AppStorage private var showMore: Bool

    init(row: ClaudeAccountRow, now: Date, open: @escaping () -> Void, signIn: @escaping () -> Void) {
        self.row = row
        self.now = now
        self.open = open
        self.signIn = signIn
        _showMore = AppStorage(wrappedValue: false, "showMore.claude.\(row.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(row.isRecommended ? Color.green : Color.clear).frame(width: 6, height: 6)
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
                Spacer()
                Button(action: open) {
                    Label(row.isRunning ? "Show" : "Open", systemImage: "macwindow")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(row.isRunning ? "Bring this account's Claude window forward" : "Open this account's Claude window")
            }
            if row.isRecommended || row.email != nil {
                Text([row.isRecommended ? "New sessions here" : nil, row.email].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(row.isRecommended ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .padding(.top, -4)
            }
            issue
            if let snapshot = row.snapshot {
                let windows = ProviderSection.split(snapshot.windows)
                ForEach(windows.main, id: \.label) { WindowRow(window: $0, now: now) }
                if showMore { ForEach(windows.more, id: \.label) { WindowRow(window: $0, now: now) } }
                if !windows.more.isEmpty {
                    Caret(isExpanded: showMore) { showMore.toggle() }.padding(.bottom, -4)
                }
            } else if row.cliUUID != nil, let error = row.error {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if row.cliUUID != nil {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(row.isRecommended ? AnyShapeStyle(.background.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// What keeps this account from working fully, and the fix.
    @ViewBuilder private var issue: some View {
        if row.appUUID == nil && !row.isMain {
            Text("Its Claude window isn't signed in yet. Open it and sign in while your main Claude app is closed.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if row.cliUUID == nil {
            HStack(alignment: .firstTextBaseline) {
                Text("Sign in once in Terminal so Headroom can show its usage.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Sign in", action: signIn).font(.caption).buttonStyle(.borderless)
            }
        } else if row.mismatch {
            HStack(alignment: .firstTextBaseline) {
                Text("Its window and its Terminal sign-in are different accounts.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Fix", action: signIn).font(.caption).buttonStyle(.borderless)
            }
        }
    }
}
