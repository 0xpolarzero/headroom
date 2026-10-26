import AppKit
import Observation
import SwiftUI

/// A single status item showing every provider side by side, opening one panel.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let popover = NSPopover()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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
        observe()
    }

    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Providers in the Settings order; a plain gauge when none has anything to show.
    private func update() {
        let ids = model.menuBarProviders
        if ids.isEmpty {
            let gauge = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Headroom")
            gauge?.isTemplate = true
            item.button?.image = gauge
            return
        }
        let labels = ids.map { id in
            MenuBarLabel(id: id, snapshot: id == .claude ? model.claudeMenuBarSnapshot : model.state(id).snapshot,
                         mode: model.menuBarMode)
        }
        let strip = HStack(spacing: 10) {
            ForEach(labels, id: \.id) { $0 }
        }
        item.button?.image = MenuBarLabel.template(strip)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) { model.panelOpened() }

    func popoverDidClose(_ notification: Notification) { model.showingSettings = false }
}
