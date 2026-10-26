import AppKit
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showingSettings {
                SettingsView(model: model)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    usage(now: context.date)
                }
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.panelOpened()
        }
    }

    @ViewBuilder
    private func usage(now: Date) -> some View {
        if model.enabledProviders.isEmpty {
            Text("No providers enabled.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.enabledProviders.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.horizontal, 14) }
                    ProviderSection(id: id, state: model.state(id), now: now)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            Button { model.showingSettings.toggle() } label: {
                Image(systemName: model.showingSettings ? "gearshape.fill" : "gearshape")
            }
            .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit Headroom")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func updatedText(now: Date) -> String {
        guard let last = model.lastUpdated else { return model.isRefreshing ? "Updating…" : "Not updated yet" }
        if now.timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(Format.clock(last, now: now))"
    }
}

struct ProviderSection: View {
    let id: ProviderID
    let state: ProviderState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot = state.snapshot {
                if snapshot.windows.isEmpty {
                    Text("No limits reported.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.windows, id: \.label) { window in
                    WindowRow(window: window, now: now)
                }
            } else if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: Logos.image(id))
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
            Text(id.displayName).font(.headline)
            if let plan = state.snapshot?.plan {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.mini)
            }
            if state.isStale(now: now) {
                Text("Outdated").font(.caption).foregroundStyle(.orange)
            }
            // A missing snapshot already shows the error inline.
            if let error = state.error, state.snapshot != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.subheadline)
                Spacer()
                Text(Format.used(window))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Meter(percent: window.usedPercent ?? 0)
            if let reset = window.resetsAt {
                Text(Format.resets(reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Meter: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.3), value: percent)
    }

    private var color: Color {
        percent >= 90 ? .red : percent >= 80 ? .yellow : .blue
    }
}
