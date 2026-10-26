import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--print") { printUsage() } else { HeadroomApp.main() }
    }

    /// `Headroom --print`: fetch every provider once and print the result, for debugging.
    private static func printUsage() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), AntigravityProvider(), ZAIProvider()]
            for provider in providers {
                do {
                    let s = try await provider.fetch()
                    print("\(s.title) [\(s.plan ?? "no plan")]")
                    for w in s.windows {
                        let reset = w.resetsAt.map { Format.resets($0) } ?? "no reset"
                        print("  \(w.label): \(Format.used(w)), \(reset)")
                    }
                } catch {
                    print("\(provider.id.displayName): \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
    }
}

struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        let shown = model.menuBarProviders
        MenuBarExtra(isInserted: inserted(shown.contains(.claude))) { panel } label: { label(.claude) }
            .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: inserted(shown.contains(.codex))) { panel } label: { label(.codex) }
            .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: inserted(shown.contains(.antigravity))) { panel } label: { label(.antigravity) }
            .menuBarExtraStyle(.window)
        MenuBarExtra(isInserted: inserted(shown.contains(.zai))) { panel } label: { label(.zai) }
            .menuBarExtraStyle(.window)
        // Keeps Headroom reachable when no provider has an item.
        MenuBarExtra("Headroom", systemImage: "gauge.with.dots.needle.50percent", isInserted: inserted(shown.isEmpty)) { panel }
            .menuBarExtraStyle(.window)
    }

    private var panel: some View { PanelView(model: model) }

    private func label(_ id: ProviderID) -> some View {
        MenuBarLabel(id: id, snapshot: model.state(id).snapshot, mode: model.menuBarMode)
    }

    /// Items follow the model; removing one by dragging it out of the menu bar is ignored.
    private func inserted(_ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { _ in })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this covers `swift run` too.
        NSApp.setActivationPolicy(.accessory)
    }
}
