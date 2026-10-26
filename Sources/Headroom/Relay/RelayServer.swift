import Foundation
import Network

enum Relay {
    static let port: UInt16 = 47812
    static var proxyURL: String { "http://127.0.0.1:\(port)" }
    static let upstreamHost = "api.anthropic.com"
    static let healthPath = "/headroom/health"
}

/// `HTTPS_PROXY` for Claude Code. Every `CONNECT` is tunnelled byte for byte, except Claude Code's own
/// connections to `api.anthropic.com` once it trusts Headroom's CA: those are decrypted, so that each
/// `/v1/messages` request can be sent with the token of the account that should take it.
///
/// Network.framework can't start TLS on a connection that is already open, so a decrypted `CONNECT` is
/// spliced to a second listener on loopback that speaks TLS with the CA's certificate.
final class RelayServer: @unchecked Sendable {
    let engine: RelayEngine
    private let queue = DispatchQueue(label: "headroom.relay", attributes: .concurrent)
    private var outer: NWListener?
    private var inner: NWListener?
    private var innerPort: UInt16 = 0
    private let lock = NSLock()
    /// Splice connections waiting for the TLS listener to accept them, by their local port.
    private var pending: [UInt16: ClientProcess] = [:]

    init(engine: RelayEngine) { self.engine = engine }

    func start(identity: sec_identity_t?) async throws {
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let params = NWParameters(tls: tls)
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let inner = try NWListener(using: params)
            inner.newConnectionHandler = { [weak self] in self?.acceptDecrypted($0) }
            innerPort = try await ready(inner)
            self.inner = inner
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Relay.port)!)
        params.allowLocalEndpointReuse = true
        let outer = try NWListener(using: params)
        outer.newConnectionHandler = { [weak self] in self?.acceptProxy($0) }
        _ = try await ready(outer)
        self.outer = outer
    }

    private func ready(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.claim() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: Proxy side

    private func acceptProxy(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { await self.serveProxy(ByteStream(connection)) }
    }

    private func serveProxy(_ client: ByteStream) async {
        guard let head = try? await client.readHead() else { client.close(); return }
        guard head.method == "CONNECT" else {
            let ok = head.path == Relay.healthPath
            let status = ok ? "200 OK" : "405 Method Not Allowed"
            let body = ok ? "ok" : ""
            try? await client.send(Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
            client.close()
            return
        }
        engine.noteConnection()
        let (host, port) = Self.split(head.target)
        var process: ClientProcess?
        if host == Relay.upstreamHost, port == 443, inner != nil, engine.decryptsNewProcesses,
           case .hostPort(_, let clientPort)? = client.connection.currentPath?.remoteEndpoint,
           let found = ClientProcess.claudeCode(clientPort: clientPort.rawValue, relayPort: Relay.port),
           engine.trusts(found) {
            process = found
        }

        let upstream: NWConnection
        if process != nil {
            upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: innerPort)!, using: .tcp)
        } else {
            let params = NWParameters.tcp
            params.preferNoProxies = true
            guard let p = NWEndpoint.Port(rawValue: port) else { client.close(); return }
            upstream = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        }
        guard await connect(upstream) else {
            try? await client.send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            client.close()
            upstream.cancel()
            return
        }
        if let process, case .hostPort(_, let localPort)? = upstream.currentPath?.localEndpoint {
            lock.withLock { pending[localPort.rawValue] = process }
        }
        do {
            try await client.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        } catch {
            client.close(); upstream.cancel(); return
        }
        await Self.pipe(client, ByteStream(upstream))
    }

    private func connect(_ connection: NWConnection) async -> Bool {
        await Once.connect(connection, queue: queue)
    }

    /// Copies bytes both ways. When one side finishes sending, that is passed on as a half-close and
    /// the other direction may go on for up to `halfCloseGrace`, so an answer to a half-closed request
    /// still gets through.
    static func pipe(_ a: ByteStream, _ b: ByteStream, halfCloseGrace: Duration = .seconds(120)) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await copy(from: a, to: b); return true }
            group.addTask { await copy(from: b, to: a); return true }
            _ = await group.next()
            group.addTask { try? await Task.sleep(for: halfCloseGrace); return false }
            _ = await group.next()
            a.close()
            b.close()
            group.cancelAll()
        }
    }

    private static func copy(from source: ByteStream, to sink: ByteStream) async {
        while let data = try? await source.readSome() {
            guard (try? await sink.send(data)) != nil else { return }
        }
        sink.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// "api.anthropic.com:443" → ("api.anthropic.com", 443); "[::1]:8443" → ("::1", 8443).
    static func split(_ target: String) -> (String, UInt16) {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            return (host, UInt16(rest.dropFirst()) ?? 443)
        }
        guard let colon = target.lastIndex(of: ":") else { return (target, 443) }
        return (String(target[..<colon]), UInt16(target[target.index(after: colon)...]) ?? 443)
    }

    // MARK: Decrypted side

    private func acceptDecrypted(_ connection: NWConnection) {
        guard case .hostPort(_, let port) = connection.endpoint else { connection.cancel(); return }
        Task {
            // The accept can arrive before the proxy side has recorded the splice; wait for it briefly.
            var process: ClientProcess?
            for _ in 0..<50 {
                process = lock.withLock { pending.removeValue(forKey: port.rawValue) }
                if process != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            // Only connections spliced from the proxy side are accepted.
            guard let process else { connection.cancel(); return }
            connection.start(queue: queue)
            await self.engine.serve(ByteStream(connection), from: process)
        }
    }
}

/// A flag that can be claimed once, from any thread; guards continuations resumed from callbacks.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    var isClaimed: Bool { lock.withLock { claimed } }

    /// Starts `connection` and waits until it is ready (true) or failed (false), at most 20 s.
    static func connect(_ connection: NWConnection, queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { cont in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { cont.resume(returning: true) }
                case .failed, .cancelled: if once.claim() { cont.resume(returning: false) }
                case .waiting: connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) { if !once.isClaimed { connection.cancel() } }
        }
    }
}
