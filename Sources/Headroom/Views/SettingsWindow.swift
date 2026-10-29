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
        let host = NSHostingController(rootView: content())
        host.sizingOptions = []   // the window keeps its size; long pages scroll
        window.contentViewController = host
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 600, height: 420)
        window.center()
        windows[name] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case accounts, agents
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .agents: "Agents"
        }
    }

    /// Beside the title: what the page is about.
    var about: String {
        switch self {
        case .accounts: "Your plans, what each shows in the menu bar, and when it notifies you."
        case .agents: "In Claude Code: subagents on your other Claude accounts, and agents on your other plans."
        }
    }

    var icon: String {
        switch self {
        case .accounts: "person.2"
        case .agents: "sparkle"
        }
    }

    var tint: Color {
        switch self {
        case .accounts: .blue
        case .agents: ProviderID.claude.brandColors[0]
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
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
                        .background(page == model.settingsPage ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if model.needsRepair {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Plugin problem").font(.callout.weight(.medium))
                            InfoTip(model.claudeError ?? "")
                        }
                        Button("Repair") { model.repair() }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 8)
                }
                Menu {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .disabled(!AppModel.isBundled)
                } label: {
                    Image(systemName: "ellipsis.circle").imageScale(.large).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .frame(width: 190)
            .background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                // In line with the first sidebar item, which starts as far down.
                HStack(spacing: 5) {
                    Text(model.settingsPage.title).font(.title3.weight(.semibold))
                    InfoTip(model.settingsPage.about)
                    Spacer()
                    if model.settingsPage == .accounts {
                        Button("Add account…") { model.connectStatus = .idle; adding = true }
                    }
                }
                .frame(height: 30)
                .padding(.horizontal, 20)
                .padding(.top, 44)
                Group {
                    switch model.settingsPage {
                    case .accounts: Form { AccountsSections(model: model) }
                    case .agents:
                        Form {
                            AgentsSwitchSection(model: model)
                            if model.agentsEnabled {
                                AgentsSections(model: model)
                                ClaudeAccountsSection(model: model)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }
}
