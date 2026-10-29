import AppKit
import SwiftUI

/// `Headroom --snapshots <folder>`: renders the panel, Settings, setup and the add-account sheet to PNGs with
/// the accounts on this Mac, offscreen, for reviewing the UI. Starts no status item and no warm pool, so it
/// runs beside the installed app.
@MainActor
enum Snapshots {
    static func main(to folder: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        model.start()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))   // usage and local checks
            for page in SettingsPage.allCases {
                model.settingsPage = page
                await capture(SettingsView(model: model), NSSize(width: 720, height: 560), titled: "Headroom Settings", to: folder, "settings-\(page.rawValue)")
            }
            model.settingsPage = .accounts
            model.claudeError = "Claude Code refused: plugin headroom@headroom not found in marketplace."
            await capture(SettingsView(model: model), NSSize(width: 720, height: 560), titled: "Headroom Settings", to: folder, "settings-repair")
            model.claudeError = nil
            await capture(SavingInstructionEditor(catalog: AgentCatalog.load()) {}, nil, to: folder, "save-instruction")
            model.panelTab = .limits
            await capture(PanelView(model: model), nil, to: folder, "panel-limits")
            model.panelTab = .agents
            await capture(PanelView(model: model), nil, to: folder, "panel-agents")
            for step in SetupView.Step.allCases {
                await capture(SetupView(model: model, step: step), NSSize(width: 600, height: 560), titled: "", to: folder, "setup-\(step.rawValue)")
            }
            let waiting = ConnectProvider(model: model, provider: .claude, back: {}, done: {}).frame(width: 440)
                .onAppear { model.connectStatus = .working("Finish signing in in your browser.") }
            await capture(waiting, nil, to: folder, "add-claude-waiting")
            model.connectStatus = .idle
            await capture(AddAccountSheet(model: model), nil, to: folder, "add-account")
            await capture(ConnectProvider(model: model, provider: .zai, back: {}, done: {}).frame(width: 440), nil, to: folder, "add-zai")
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func capture(_ view: some View, _ size: NSSize?, titled title: String? = nil, to folder: URL, _ name: String) async {
        let host = NSHostingController(rootView: view)
        if size != nil { host.sizingOptions = [] }
        var style: NSWindow.StyleMask = title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if title != nil { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400), styleMask: style, backing: .buffered, defer: false)
        window.title = title ?? ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(size ?? host.view.fittingSize)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        if size == nil { window.setContentSize(host.view.fittingSize); try? await Task.sleep(for: .seconds(0.5)) }
        guard let frameView = window.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        // Split views and grouped forms draw through layers that cacheDisplay leaves blank: render the layer tree.
        let scale = window.backingScaleFactor, bounds = frameView.bounds
        guard let layer = frameView.layer,
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(origin: .zero, size: bounds.size))
        if !layer.isGeometryFlipped && frameView.isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        window.close()
    }
}
