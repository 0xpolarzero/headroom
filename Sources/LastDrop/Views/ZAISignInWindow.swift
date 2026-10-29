import AppKit
import WebKit

/// A small browser window on z.ai. Once the user is signed in, the page's session token is picked up,
/// checked against the quota API, and kept in lastdrop's own keychain item.
@MainActor
final class ZAISignInWindow: NSObject, NSWindowDelegate {
    private static var current: ZAISignInWindow?
    private static let startURL = URL(string: "https://z.ai/manage-apikey/subscription")!

    private let window: NSWindow
    private let web: WKWebView
    private let completion: (Bool) -> Void
    private var timer: Timer?
    private var tried: Set<String> = []
    private var checking = false
    private var finished = false

    static func present(completion: @escaping (Bool) -> Void) {
        if let current { current.window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        current = ZAISignInWindow(completion: completion)
    }

    private init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Sign in to Z.ai"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        web.load(URLRequest(url: Self.startURL))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    /// Collects JWT-looking values and `*token*` entries from web storage and z.ai cookies.
    private func scan() {
        guard !checking, !finished else { return }
        checking = true
        let js = "JSON.stringify([Object.entries(localStorage), Object.entries(sessionStorage)])"
        web.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    MainActor.assumeIsolated {
                        var pairs: [(String, String)] = cookies
                            .filter { $0.domain.hasSuffix("z.ai") }
                            .map { ($0.name, $0.value) }
                        if let text = result as? String,
                           let lists = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[[String]]] {
                            pairs += lists.flatMap { $0 }.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
                        }
                        self.check(Self.candidates(pairs))
                    }
                }
            }
        }
    }

    private func check(_ found: [String]) {
        let fresh = found.filter { !tried.contains($0) }
        tried.formUnion(fresh)
        guard !fresh.isEmpty else { checking = false; return }
        Task {
            let header = await ZAIProvider.validSessionHeader(fresh)
            checking = false
            if let header, Keychain.writeOwn(service: ZAIProvider.service, account: ZAIProvider.sessionAccount, value: header) {
                finished = true
                window.close()
            }
        }
    }

    nonisolated static func candidates(_ pairs: [(String, String)]) -> [String] {
        let jwt = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
        var out: [String] = []
        for (key, value) in pairs {
            let range = NSRange(value.startIndex..., in: value)
            out += jwt.matches(in: value, range: range).compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            if key.lowercased().contains("token"), value.count >= 20, !value.contains(" "), !value.hasPrefix("{") {
                out.append(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        completion(finished)
        Self.current = nil
    }
}
