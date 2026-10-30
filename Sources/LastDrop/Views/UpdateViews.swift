import AppKit
import SwiftUI

/// A new release in the panel, above its footer: what it is, and the one thing to do next.
struct UpdateBanner: View {
    let updater: Updater

    var body: some View {
        let version = updater.release?.version ?? ""
        HStack(spacing: 8) {
            Image(systemName: updater.phase.isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(updater.phase.isFailed ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(version)).font(.callout.weight(.medium))
                if let detail = detail(version) { Caption(detail) }
            }
            Spacer(minLength: 4)
            if let action = action {
                Button(action) { updater.advance() }.controlSize(.small)
            }
            if updater.phase != .installing {
                Menu {
                    if let page = updater.release?.page {
                        Button("What's new in \(version)") { NSWorkspace.shared.open(page) }
                    }
                    Button("Skip \(version)") { updater.skip() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func title(_ version: String) -> String {
        switch updater.phase {
        case .downloading: "Downloading \(version)… \(Int(updater.fraction * 100))%"
        case .installing: "Installing \(version)…"
        case .failed: "Update failed"
        case .ready: "lastdrop \(version) is ready"
        default: "lastdrop \(version) is available"
        }
    }

    private func detail(_ version: String) -> String? {
        if case .failed(let message) = updater.phase { return message }
        return nil
    }

    private var action: String? {
        switch updater.phase {
        case .available: "Update"
        case .ready: "Restart"
        case .failed: "Try again"
        default: nil
        }
    }
}

/// Settings' Updates page.
struct UpdatesSection: View {
    @Bindable var model: AppModel

    private var updater: Updater { model.updater }

    var body: some View {
        PageSection {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Row(icon: "arrow.down.circle", title: "lastdrop \(updater.current)", detail: status(context.date), detailColor: statusColor) {
                    if updater.isRelease { button }
                }
            }
            if updater.isRelease {
                RowDivider()
                Row(icon: "clock.arrow.circlepath", title: "Check for updates automatically") {
                    RowSwitch(label: "Check for updates automatically",
                              isOn: Binding(get: { model.checkUpdates }, set: { model.checkUpdates = $0 }))
                }
            }
        }
    }

    @ViewBuilder private var button: some View {
        switch updater.phase {
        case .available: Button("Download & install") { updater.advance() }
        case .failed: Button("Try again") { updater.advance() }
        case .ready: Button("Restart to update") { updater.advance() }
        case .downloading, .installing: EmptyView()
        case .idle:
            Button(updater.checking ? "Checking…" : "Check now") {
                model.skippedUpdate = nil
                Task { await updater.update(manual: true) }
            }
            .disabled(updater.checking)
        }
    }

    private func status(_ now: Date) -> String {
        guard updater.isRelease else { return "Development build: updates come from git" }
        let version = updater.release?.version ?? ""
        switch updater.phase {
        case .available: return "Version \(version) is available"
        case .downloading: return "Downloading \(version)… \(Int(updater.fraction * 100))%"
        case .ready: return "Version \(version) is ready to install"
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle:
            if let error = updater.checkError { return error }
            guard let last = updater.lastCheck else { return "Not checked yet" }
            return "Up to date · checked \(Format.clock(last, now: now))"
        }
    }

    private var statusColor: Color {
        if updater.phase.isFailed || updater.checkError != nil { return .orange }
        return .secondary
    }
}
