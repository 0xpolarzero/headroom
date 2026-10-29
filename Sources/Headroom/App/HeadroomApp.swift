import AppKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--agent-key") { EndpointProfile.keyMain() }
        if CommandLine.arguments.contains("--print") { printUsage(); return }
        if CommandLine.arguments.contains("--agent-run") { AgentRun.main() }
        if CommandLine.arguments.contains("--agent-route") { AgentRun.main(routeOnly: true) }
        if CommandLine.arguments.contains("--agent-warm") { AgentRun.warmMain() }
        if CommandLine.arguments.contains("--agent-open") { AgentRun.openMain() }
        if CommandLine.arguments.contains("--agent-stop") { AgentRun.stopMain() }
        if CommandLine.arguments.contains("--agent-selftest") { SelfTest.main() }
        if CommandLine.arguments.contains("--agent-catalog") { AgentCatalog.printMain() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
            Snapshots.main(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // the bundle sets LSUIElement; this covers `swift run` too
        app.run()
    }

    /// `Headroom --print`: fetch every account once and print the result, for debugging.
    private static func printUsage() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for account in AccountsConfig.load().accounts {
                let name = account.provider.displayName + (account.isMain ? "" : " · \(account.key)")
                do {
                    let s = try await account.usageProvider.fetch()
                    print("\(name) [\(s.plan ?? "no plan")]")
                    for w in s.windows {
                        let reset = w.resetsAt.map { Format.resets($0) } ?? "no reset"
                        print("  \(w.label): \(Format.left(w)), \(reset)")
                    }
                    if let c = s.credits { print("  Credits: \(c.amount)\(c.inUse ? " (in use)" : "")\(c.detail.map { ", \($0)" } ?? "")") }
                } catch {
                    print("\(name): \(error.localizedDescription)")
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
        SetupView.showIfNeeded(model)
        WarmPoolServer.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WarmPoolServer.shared.stop()
    }
}
