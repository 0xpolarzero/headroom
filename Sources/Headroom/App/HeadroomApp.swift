import AppKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--print") { printUsage(); return }
        if CommandLine.arguments.contains("--relay") { RelayMain.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--routing"), CommandLine.arguments.indices.contains(i + 1) {
            setRouting(CommandLine.arguments[i + 1] == "on"); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // the bundle sets LSUIElement; this covers `swift run` too
        app.run()
    }

    /// `Headroom --routing on|off`: what the Settings switch does, for scripts and debugging.
    private static func setRouting(_ on: Bool) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                if on { try await RelayInstaller.enable() } else { try RelayInstaller.disable() }
                print(on ? "Routing on. Claude Code sessions started from now on go through the relay."
                         : "Routing off. The settings keys are blank now and are removed by the app a minute from now.")
            } catch {
                print("Failed: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
    }

    /// `Headroom --print`: fetch every provider once and print the result, for debugging.
    private static func printUsage() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), AntigravityProvider(), ZAIProvider(), OpenRouterProvider()]
            for provider in providers {
                do {
                    let s = try await provider.fetch()
                    print("\(s.title) [\(s.plan ?? "no plan")]")
                    for w in s.windows {
                        let reset = w.resetsAt.map { Format.resets($0) } ?? "no reset"
                        print("  \(w.label): \(Format.left(w)), \(reset)")
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        model.start()
        self.model = model
        statusBar = StatusBarController(model: model)
    }
}
