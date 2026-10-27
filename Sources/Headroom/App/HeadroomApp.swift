import AppKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--print") { printUsage(); return }
        if CommandLine.arguments.contains("--mcp") { SubagentServer.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // the bundle sets LSUIElement; this covers `swift run` too
        app.run()
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
