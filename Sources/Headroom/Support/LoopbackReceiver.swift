import CryptoKit
import Foundation
import Network

/// PKCE helpers shared by the OAuth sign-ins.
enum PKCE {
    static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "headroom.oauth")
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(path: String) { self.path = path }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.ready = cont
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.ready?.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error): self?.ready?.resume(throwing: error)
                    default: return
                    }
                    self?.ready = nil
                }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits up to five minutes for the browser to come back.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let result = self.result { cont.resume(with: result); return }
                    self.callback = cont
                    self.queue.asyncAfter(deadline: .now() + 300) {
                        self.finish(.failure(ProviderError.message("Sign-in timed out.")))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() { queue.async { self.listener?.cancel() } }

    private func finish(_ result: Result<[String: String], Error>) {
        guard self.result == nil else { return }
        self.result = result
        callback?.resume(with: result)
        callback = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix(self?.path ?? "/") else { connection.cancel(); return }
            var query: [String: String] = [:]
            for item in URLComponents(string: "http://localhost" + target)?.queryItems ?? [] { query[item.name] = item.value }
            let html = "<html><body style=\"font:16px -apple-system;text-align:center;margin-top:20vh\">"
                + "Headroom is signed in. You can close this tab.</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self?.finish(.success(query))
        }
    }
}
