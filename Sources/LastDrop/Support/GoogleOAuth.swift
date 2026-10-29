import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth with Antigravity's installed-app client (the same one OpenUsage uses). For installed
/// apps Google treats the client secret as public.
enum GoogleOAuth {
    private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let clientSecret = "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"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]

    enum RefreshOutcome { case refreshed(String, expiresIn: TimeInterval), revoked, unavailable }

    static func refresh(_ refreshToken: String) async -> RefreshOutcome {
        let form = ["client_id": clientID, "client_secret": clientSecret,
                    "refresh_token": refreshToken, "grant_type": "refresh_token"]
        guard let (object, http) = try? await HTTP.json(formRequest(form)) else { return .unavailable }
        switch http.statusCode {
        case 200..<300:
            guard let body = object as? [String: Any], let access = body.string("access_token") else { return .unavailable }
            return .refreshed(access, expiresIn: body.double("expires_in") ?? 3600)
        case 408, 429: return .unavailable
        case 400..<500: return .revoked
        default: return .unavailable
        }
    }

    /// Browser sign-in with a loopback redirect and PKCE. Returns the refresh token and the account email.
    static func signIn() async throws -> (refreshToken: String, email: String?) {
        let receiver = LoopbackReceiver(path: "/oauth2callback")
        let port = try await receiver.start()
        defer { receiver.stop() }

        let verifier = randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString()
        let redirect = "http://127.0.0.1:\(port)/oauth2callback"
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = auth.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let query = try await receiver.waitForCallback()
        guard query["state"] == state else { throw ProviderError.message("Sign-in was interrupted. Try again.") }
        guard let code = query["code"] else { throw ProviderError.message(query["error"].map { "Sign-in failed: \($0)." } ?? "Sign-in was cancelled.") }

        let form = ["client_id": clientID, "client_secret": clientSecret, "code": code, "code_verifier": verifier,
                    "redirect_uri": redirect, "grant_type": "authorization_code"]
        let (object, http) = try await HTTP.json(formRequest(form))
        guard (200..<300).contains(http.statusCode), let body = object as? [String: Any],
              let refresh = body.string("refresh_token") else {
            throw ProviderError.message("Google did not return a login. Try again.")
        }
        var email: String?
        if let access = body.string("access_token"),
           let (info, infoHTTP) = try? await HTTP.json(HTTP.request("https://www.googleapis.com/oauth2/v2/userinfo",
                                                                     headers: ["Authorization": "Bearer \(access)"])),
           (200..<300).contains(infoHTTP.statusCode) {
            email = (info as? [String: Any])?.string("email")
        }
        return (refresh, email)
    }

    private static func formRequest(_ form: [String: String]) -> URLRequest {
        var req = HTTP.request(tokenURL, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"])
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=/?")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        return req
    }

    private static func randomString() -> String { PKCE.randomString() }
}
