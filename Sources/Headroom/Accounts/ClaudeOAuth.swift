import AppKit
import AuthenticationServices
import Foundation

/// Claude subscription sign-in with Claude Code's own OAuth client, as found in Claude Code 2.1.308.
/// Used only for accounts Headroom adds; the account Claude Code is signed in to is never signed in again.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    static let scopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers",
                         "user:file_upload", "user:plugins"]
    static let beta = "oauth-2025-04-20"

    struct Login: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var scope: String?
    }

    struct Profile: Sendable {
        var uuid: String
        var email: String?
        var orgUUID: String?
        var plan: String?
    }

    enum RefreshOutcome: Sendable { case refreshed(Login), revoked, unavailable(String) }

    // MARK: Sign-in

    /// Opens Claude's sign-in in an empty, throwaway browser session so it can't reuse the account the
    /// default browser or the Claude app is signed in to, and waits for the loopback redirect.
    @MainActor
    static func signIn(loginHint: String?) async throws -> (Login, Profile) {
        let receiver = LoopbackReceiver(path: "/callback")
        let port = try await receiver.start()
        defer { receiver.stop() }

        let verifier = PKCE.randomString()
        let state = PKCE.randomString()
        let redirect = "http://localhost:\(port)/callback"
        var auth = URLComponents(string: authorizeURL)!
        auth.queryItems = [
            .init(name: "code", value: "true"), .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        if let hint = loginHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            auth.queryItems?.append(.init(name: "login_hint", value: hint))
        }

        let sheet = SignInSheet(url: auth.url!)
        sheet.start()
        defer { sheet.cancel() }
        let query = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [String: String].self) { group in
                group.addTask { try await receiver.waitForCallback() }
                group.addTask { try await sheet.waitUntilClosed(); throw CancellationError() }
                // Close the sheet before leaving: the group waits for its child to see it closed.
                do {
                    let first = try await group.next()!
                    sheet.cancel()
                    group.cancelAll()
                    return first
                } catch {
                    sheet.cancel()
                    throw error
                }
            }
        } onCancel: {
            Task { @MainActor in sheet.cancel() }
        }
        guard query["state"] == state else { throw ProviderError.message("Sign-in was interrupted. Try again.") }
        guard let code = query["code"] else {
            throw ProviderError.message(query["error"].map { "Sign-in failed: \($0)." } ?? "Sign-in was cancelled.")
        }

        let body: [String: Any] = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                   "client_id": clientID, "code_verifier": verifier, "state": state]
        let (object, http) = try await HTTP.json(HTTP.request(tokenURL, method: "POST", json: body))
        guard (200..<300).contains(http.statusCode), let root = object as? [String: Any],
              let login = login(from: root, previousRefresh: nil) else {
            throw ProviderError.message(http.statusCode == 401 ? "Claude refused the sign-in code. Try again."
                                                                 : "Claude did not return a login (HTTP \(http.statusCode)).")
        }
        guard let profile = try await profile(accessToken: login.accessToken) else {
            throw ProviderError.message("Signed in, but Claude did not say which account it is.")
        }
        return (login, profile)
    }

    // MARK: Tokens

    static func refresh(_ refreshToken: String) async -> RefreshOutcome {
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                   "client_id": clientID, "scope": scopes.joined(separator: " ")]
        let object: Any, http: HTTPURLResponse
        do { (object, http) = try await HTTP.json(HTTP.request(tokenURL, method: "POST", json: body)) }
        catch { return .unavailable(error.localizedDescription) }
        switch http.statusCode {
        case 200..<300:
            guard let root = object as? [String: Any], let login = login(from: root, previousRefresh: refreshToken) else {
                return .unavailable("Unexpected token response.")
            }
            return .refreshed(login)
        case 400, 401, 403: return .revoked
        default: return .unavailable("Token refresh failed (HTTP \(http.statusCode)).")
        }
    }

    /// The refresh token may or may not rotate; without a new one the old one stays valid.
    static func login(from root: [String: Any], previousRefresh: String?, now: Date = .now) -> Login? {
        guard let access = root.string("access_token"), !access.isEmpty,
              let refresh = root.string("refresh_token") ?? previousRefresh else { return nil }
        let expiresIn = root.double("expires_in") ?? 3600
        return Login(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn),
                     scope: root.string("scope"))
    }

    static func profile(accessToken: String) async throws -> Profile? {
        let headers = ["Authorization": "Bearer \(accessToken)", "anthropic-beta": beta, "Accept": "application/json",
                       "User-Agent": "Headroom"]
        let (object, http) = try await HTTP.json(HTTP.request(profileURL, headers: headers))
        guard (200..<300).contains(http.statusCode), let root = object as? [String: Any] else { return nil }
        return profile(from: root)
    }

    /// `{"account": {"uuid", "email" | "email_address"}, "organization": {"uuid", "organization_type", "rate_limit_tier"}}`
    static func profile(from root: [String: Any]) -> Profile? {
        guard let account = root.dict("account"), let uuid = account.string("uuid") else { return nil }
        let org = root.dict("organization")
        var type = org?.string("organization_type")
        if let t = type, t.hasPrefix("claude_") { type = String(t.dropFirst("claude_".count)) }
        return Profile(uuid: uuid, email: account.string("email") ?? account.string("email_address"),
                       orgUUID: org?.string("uuid"),
                       plan: ClaudeProvider.planName(type: type, tier: org?.string("rate_limit_tier")))
    }
}

/// The system's own sign-in sheet in ephemeral mode: no cookies from Safari or earlier sign-ins.
/// Headroom closes it itself once the loopback listener has the code.
@MainActor
private final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let url: URL
    private var session: ASWebAuthenticationSession?
    private var closed: CheckedContinuation<Void, Error>?
    private var didClose = false
    private var window: NSWindow?

    init(url: URL) { self.url = url }

    func start() {
        // The callback scheme never matches: the redirect goes to the loopback listener instead.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "headroom-signin") { [weak self] _, _ in
            Task { @MainActor in self?.finish() }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        self.session = session
        NSApp.activate()
        if !session.start() { finish() }
    }

    func cancel() {
        session?.cancel()
        session = nil
        window?.close()
        window = nil
        finish()
    }

    func waitUntilClosed() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if didClose { cont.resume() } else { closed = cont }
        }
    }

    private func finish() {
        didClose = true
        closed?.resume()
        closed = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            if let key = NSApp.keyWindow { return key }
            // A menu bar app may have no window to attach the sheet to.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.center()
            w.makeKeyAndOrderFront(nil)
            window = w
            return w
        }
    }
}
