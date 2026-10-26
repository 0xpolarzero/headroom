import SwiftUI

/// The Claude card when several accounts are connected or routing is on: one block per account in
/// priority order, the one Claude Code is using marked, and the latest switch.
struct ClaudeAccountsSection: View {
    @Bindable var model: AppModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(model.claudeRows) { row in
                AccountBlock(row: row, now: now)
            }
            if let note = activity {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ProviderID.claude.brandBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(ProviderID.claude.brandColors[0].opacity(0.25), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: Logos.image(.claude))
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(LinearGradient(colors: ProviderID.claude.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Claude").font(.headline)
            Spacer()
            if model.claudeConfig.routing {
                if model.relayHealthy {
                    Text("Auto-switch").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("The relay is not running, so Claude Code can't connect. Headroom is restarting it.")
                }
            }
        }
    }

    /// "13:02 Switched to Max: session limit on Pro" and when the first account comes back.
    private var activity: String? {
        guard model.claudeConfig.routing else { return nil }
        var parts: [String] = []
        if let event = model.relayState?.events.last(where: { $0.from != nil }), now.timeIntervalSince(event.at) < 12 * 3600 {
            let from = event.from.map(model.name(forKey:)) ?? ""
            parts.append("\(Format.clock(event.at, now: now)) Switched to \(model.name(forKey: event.to)): \(event.reason.lowercased()) on \(from).")
        }
        if let back = model.claudeReturnNote { parts.append(back + ".") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private struct AccountBlock: View {
    let row: ClaudeAccountRow
    let now: Date
    @AppStorage private var showMore: Bool

    init(row: ClaudeAccountRow, now: Date) {
        self.row = row
        self.now = now
        _showMore = AppStorage(wrappedValue: false, "showMore.claude.\(row.ref.key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(row.inUse ? Color.green : Color.clear).frame(width: 6, height: 6)
                    .help(row.inUse ? "Claude Code is using this account" : "")
                Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let plan = row.plan {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if row.isMain {
                    Text("Main").font(.caption2).foregroundStyle(.secondary)
                        .help("The account the Claude app is signed in to. Claude Code's own sign-in is used for it.")
                }
                Spacer()
                if let status { Text(status).font(.caption).foregroundStyle(.orange).lineLimit(1) }
            }
            if let snapshot = row.snapshot {
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
        .background(row.inUse ? AnyShapeStyle(.background.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// "Limit until 17:40", "Extra usage", "Sign in again".
    private var status: String? {
        guard let limits = row.limits else { return nil }
        if limits.signInNeeded { return "Sign in again" }
        if let until = limits.limitedUntil, until > now {
            if limits.overage { return row.allowOverage ? "Extra usage" : "Skipped: extra usage" }
            return "Out until \(Format.clock(until, now: now))"
        }
        if let scoped = limits.scoped.filter({ $0.value > now }).min(by: { $0.value < $1.value }) {
            return "\(scoped.key.capitalized) out until \(Format.clock(scoped.value, now: now))"
        }
        return nil
    }
}
