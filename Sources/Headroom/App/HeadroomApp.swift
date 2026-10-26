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
            let providers: [any UsageProvider] = [CodexProvider(), AntigravityProvider(), ZAIProvider()]
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
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(percent: model.menuBarPercent)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this covers `swift run` too.
        NSApp.setActivationPolicy(.accessory)
    }
}
