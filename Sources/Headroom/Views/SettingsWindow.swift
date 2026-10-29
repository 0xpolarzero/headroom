import AppKit
import SwiftUI

/// Settings and first-launch setup, each in a window of its own: the panel only shows usage.
@MainActor
enum WindowPresenter {
    private static var windows: [String: NSWindow] = [:]

    static func settings(_ model: AppModel, page: SettingsPage? = nil) {
        if let page { model.settingsPage = page }
        show("settings", title: "Headroom Settings", size: NSSize(width: 720, height: 560)) { SettingsView(model: model) }
    }

    static func setup(_ model: AppModel) {
        show("setup", title: "Welcome to Headroom", size: NSSize(width: 600, height: 560), resizable: false) { SetupView(model: model) }
    }

    static func close(_ name: String) { windows[name]?.close() }

    private static func show(_ name: String, title: String, size: NSSize, resizable: Bool = true, content: () -> some View) {
        if let window = windows[name] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.center()
        windows[name] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, accounts, limits, claudeCode
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .limits: "Limits"
        case .claudeCode: "Claude Code"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .limits: "gauge.with.dots.needle.50percent"
        case .claudeCode: "sparkle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .accounts: .blue
        case .limits: .green
        case .claudeCode: ProviderID.claude.brandColors[0]
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pages) { page in
                    Button { model.settingsPage = page } label: {
                        HStack(spacing: 8) {
                            Image(systemName: page.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            Text(page.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(page == current ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .frame(width: 190)
            .background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(current.title).font(.title3.weight(.semibold)).padding(.leading, 20).padding(.top, 14).frame(height: 44, alignment: .bottom)
                Group {
                    switch current {
                    case .general: GeneralPage(model: model)
                    case .accounts: AccountsPage(model: model)
                    case .limits: LimitsPage(model: model)
                    case .claudeCode: ClaudeCodePage(model: model)
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var current: SettingsPage { pages.contains(model.settingsPage) ? model.settingsPage : .general }

    /// Only the pages of the features that are on.
    private var pages: [SettingsPage] {
        SettingsPage.allCases.filter { page in
            switch page {
            case .limits: model.showsLimits
            case .claudeCode: model.showsAgents
            case .general, .accounts: true
            }
        }
    }
}

// MARK: Pages

private struct GeneralPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            FeaturesSection(model: model)
            StartupSection(model: model)
            Section {
                Button("Run Setup Again…") { WindowPresenter.close("settings"); WindowPresenter.setup(model) }
            }
        }
    }
}

private struct AccountsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form { AccountsSections(model: model) }
    }
}

private struct LimitsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form { MenuBarSection(model: model) }
    }
}

private struct ClaudeCodePage: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            PluginSection(model: model)
            AgentsSections(model: model)
            ClaudeAccountsSection(model: model)
        }
    }
}
