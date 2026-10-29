import AppKit
import Observation
import SwiftUI

/// A single status item showing every provider side by side, opening one panel.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let popover = NSPopover()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Provider strips from fullest to smallest; the first that fits is shown. Empty when no provider
    /// has anything to show.
    private var strips: [NSImage] = []
    private lazy var gauge: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Headroom")
        image?.isTemplate = true
        return image
    }()

    init(model: AppModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setAccessibilityLabel("Headroom")
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(itemMoved(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observe()
    }

    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Providers in the Settings order; a plain gauge when none has anything to show. With less room,
    /// the strip keeps every provider at one number each first, then drops providers from the end.
    private func update() {
        let ids = model.menuBarProviders
        let single: MenuBarMode = model.menuBarMode == .both ? .session : model.menuBarMode
        var layouts = [(ids, model.menuBarMode)]
        if single != model.menuBarMode { layouts.append((ids, single)) }
        layouts += (1..<max(ids.count, 1)).reversed().map { (Array(ids.prefix($0)), single) }
        strips = ids.isEmpty ? [] : layouts.map { strip($0.0, mode: $0.1) }
        layout()
    }

    private func strip(_ ids: [ProviderID], mode: MenuBarMode) -> NSImage {
        let model = self.model
        let claudeRows = model.showsClaudeAccounts ? model.claudeRows : nil
        return MenuBarLabel.template(HStack(spacing: 10) {
            ForEach(ids) { id in
                if id == .claude, let claudeRows {
                    ClaudeMenuBarLabel(rows: claudeRows, mode: mode)
                } else {
                    MenuBarLabel(id: id, snapshot: model.state(id).snapshot, mode: mode)
                }
            }
        })
    }

    /// macOS hides a status item that would reach under the notch, without telling the app, so show the
    /// fullest strip that fits, or the gauge. Items keep their right edge as their width changes, which
    /// measures the room without flickering.
    private func layout() {
        guard let button = item.button else { return }
        var image = strips.first ?? gauge
        // The area beside the notch runs to the screen's right edge; its width avoids guessing its coordinates.
        if !strips.isEmpty, let window = button.window, let screen = window.screen,
           let area = screen.auxiliaryTopRightArea, area.width > 0 {
            let padding = window.frame.width - (button.image?.size.width ?? 0)
            let room = window.frame.maxX - padding - (screen.frame.maxX - area.width)
            image = strips.first { $0.size.width <= room } ?? gauge
        }
        if button.image !== image { button.image = image }
    }

    @objc private func itemMoved(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === item.button?.window else { return }
        layout()
    }

    @objc private func screensChanged() { layout() }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) { model.panelOpened() }
}
