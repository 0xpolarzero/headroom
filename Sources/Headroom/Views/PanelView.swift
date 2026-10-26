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
    }

    @ViewBuilder
    private func usage(now: Date) -> some View {
        if model.enabledProviders.isEmpty {
            Text("No providers enabled.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        } else {
            // Never taller than the space under the menu bar, or macOS shifts the popover.
            CappedScroll(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 80) {
                VStack(spacing: 0) {
                    ForEach(Array(model.enabledProviders.enumerated()), id: \.element) { index, id in
                        if index > 0 { Divider().padding(.horizontal, 14) }
                        ProviderSection(id: id, state: model.state(id), now: now)
                    }
                }
                .padding(.vertical, 4)
            }
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
    @State private var showKeys = false

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
                if !snapshot.keys.isEmpty {
                    DisclosureGroup(isExpanded: $showKeys) {
                        CappedScroll(maxHeight: 220) {
                            VStack(spacing: 8) {
                                ForEach(snapshot.keys, id: \.self) { KeyRow(key: $0) }
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 8)   // room for the scroller
                        }
                    } label: {
                        Text(snapshot.keys.count == 1 ? "API key" : "API keys (\(snapshot.keys.count))")
                            .font(.subheadline)
                            .contentShape(Rectangle())
                            .onTapGesture { showKeys.toggle() }
                    }
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
                Text(Format.left(window))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Meter(remaining: window.remainingPercent ?? 0)
            if let reset = window.resetsAt {
                Text(Format.resets(reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Fills with what is left: blue, yellow at 20% left, red at 10% left.
/// Spend on one API key; keys with a limit get a meter of what is left of it.
struct KeyRow: View {
    let key: KeyUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(key.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(key.disabled ? .secondary : .primary)
                Spacer()
                Text(Format.dollars(key.total)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if let limit = key.limit, limit > 0 {
                let left = key.limitRemaining ?? max(limit - key.total, 0)
                Meter(remaining: left / limit * 100)
                Text("\(Format.dollars(left)) of \(Format.dollars(limit)) left").font(.caption).foregroundStyle(.tertiary)
            }
            if let periods = periods {
                Text(periods).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var periods: String? {
        let parts = [key.today.map { "Today \(Format.dollars($0))" }, key.month.map { "This month \(Format.dollars($0))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct Meter: View {
    let remaining: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(remaining, 0), 100) / 100)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.3), value: remaining)
    }

    private var color: Color {
        remaining <= 10 ? .red : remaining <= 20 ? .yellow : .blue
    }
}

/// A scroll view as tall as its content, up to `maxHeight`; beyond that it scrolls.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { geo in
                    Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
