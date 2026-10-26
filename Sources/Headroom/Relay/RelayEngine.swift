import CryptoKit
import Foundation
import Network

/// Serves the decrypted connections: forwards every request to `api.anthropic.com` unchanged, except
/// that `/v1/messages` goes out with the token of the first account in the priority order that has
/// room, and is sent again on the next one if Anthropic answers that the limit is reached.
final class RelayEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var config = ClaudeAccountsConfig.load()
    private var configStamp: Date?
    private var state = RelayState()
    private var dirty = false
    private var lastConnection = Date()
    private let started = Date()
    /// Profiles of the tokens Claude Code sent, by token hash (Main may be a different account in the
    /// Claude app and in the terminal).
    private var mains: [String: (profile: ClaudeOAuth.Profile?, checked: Date)] = [:]
    var hasIdentity = false

    /// Seams for tests; the defaults are the real keychain, profile endpoint and `api.anthropic.com`.
    struct Dependencies: Sendable {
        var fixedConfig: ClaudeAccountsConfig?
        var persist = true
        var token: @Sendable (_ uuid: String, _ rejected: String?) async throws -> String = { uuid, rejected in
            try await ClaudeTokens.shared.accessToken(uuid, rejected: rejected)
        }
        var profile: @Sendable (_ token: String) async -> ClaudeOAuth.Profile? = { token in
            (try? await ClaudeOAuth.profile(accessToken: token)) ?? nil
        }
        var upstream: @Sendable () -> Upstream = { Upstream() }
    }
    private let deps: Dependencies

    static let idleExit: TimeInterval = 30 * 60

    init(_ deps: Dependencies = Dependencies()) {
        self.deps = deps
        state = deps.persist ? (RelayState.load() ?? RelayState()) : RelayState()
        state.pid = getpid()
        state.lastError = nil
        if let fixed = deps.fixedConfig { config = fixed } else { reloadConfigIfChanged() }
    }

    /// A copy of the current state, for tests.
    var snapshot: RelayState { lock.withLock { state } }

    // MARK: Called by the server

    func noteConnection() { lock.withLock { lastConnection = Date() } }

    var decryptsNewProcesses: Bool {
        reloadConfigIfChanged()
        return lock.withLock { config.routing && hasIdentity }
    }

    /// Only Claude Code processes started after the CA went into `settings.json` trust it.
    func trusts(_ process: ClientProcess) -> Bool {
        guard process.isClaudeCode, let since = lock.withLock({ config.routingSince }) else { return false }
        return process.startedAt > since
    }

    // MARK: Housekeeping

    private func reloadConfigIfChanged() {
        guard deps.fixedConfig == nil else { return }
        let stamp = (try? HeadroomPaths.accounts.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let changed = lock.withLock { stamp != configStamp }
        guard changed else { return }
        let fresh = ClaudeAccountsConfig.load()
        lock.withLock {
            config = fresh
            configStamp = stamp
            // A removed account's state goes with it; an account signed in again starts clean.
            for (key, value) in state.accounts where key != "main" && key != state.mainUUID && fresh.account(key) == nil {
                _ = value
                state.accounts[key] = nil
            }
            for account in fresh.accounts where state.accounts[account.uuid]?.signInNeeded == true
                && ClaudeTokens.read(account.uuid) != nil {
                state.accounts[account.uuid]?.signInNeeded = false
            }
            dirty = true
        }
    }

    /// Saves the state every few seconds and exits once routing has been off and idle for a while.
    func runHousekeeping() async {
        var lastBeat = Date.distantPast
        while true {
            try? await Task.sleep(for: .seconds(2))
            reloadConfigIfChanged()
            let now = Date()
            let (save, snapshot, routing, idleSince) = lock.withLock { () -> (Bool, RelayState, Bool, Date) in
                let save = dirty || now.timeIntervalSince(lastBeat) > 20
                if save { state.updatedAt = now; dirty = false }
                return (save, state, config.routing, lastConnection)
            }
            if save, deps.persist { snapshot.save(); lastBeat = now }
            if !routing, now.timeIntervalSince(idleSince) > Self.idleExit, now.timeIntervalSince(started) > Self.idleExit {
                relayLog("Routing is off and nothing has connected for 30 minutes; stopping.")
                RelayInstaller.removeAgentFile()
                exit(0)
            }
        }
    }

    private func mutate(_ body: (inout RelayState) -> Void) {
        lock.withLock {
            body(&state)
            dirty = true
        }
    }

    // MARK: Serving

    func serve(_ client: ByteStream, from process: ClientProcess) async {
        let upstream = deps.upstream()
        defer { client.close(); upstream.close() }
        while true {
            guard let head = try? await client.readHead() else { return }
            // The relay takes the whole body before forwarding, so it answers the client's
            // `Expect: 100-continue` itself and doesn't pass the header on.
            if head.value("expect")?.lowercased() == "100-continue" {
                guard (try? await client.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))) != nil else { return }
            }
            guard let body = try? await client.readBody(of: head) else { return }
            var request = head
            if request.isChunked {
                request.remove("transfer-encoding")
                request.set("Content-Length", String(body.count))
            }
            request.remove("expect")
            let keepAlive: Bool
            do {
                if request.method == "POST", request.path == "/v1/messages" || request.path == "/v1/messages/count_tokens" {
                    keepAlive = try await route(request, body, client: client, upstream: upstream)
                } else {
                    let response = try await upstream.send(request, body)
                    keepAlive = try await upstream.relay(response, method: request.method, to: client)
                }
            } catch {
                relayLog("Request \(request.method) \(request.path) failed: \(error)")
                // Once part of a response went out, a 502 would corrupt it: just close.
                if !upstream.responseStarted {
                    try? await client.send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                }
                return
            }
            if !keepAlive || request.value("connection")?.lowercased() == "close" { return }
        }
    }

    /// Sends a messages request with the right account's token. Returns whether the client connection
    /// can carry another request.
    private func route(_ request: HTTPHead, _ body: Data, client: ByteStream, upstream: Upstream) async throws -> Bool {
        reloadConfigIfChanged()
        let incoming = request.value("authorization")
        let main = await mainProfile(incoming)
        let json = try? JSONSerialization.jsonObject(with: body)
        let model = (json as? [String: Any])?["model"] as? String
        let lifetime = Router.cacheLifetime(json)
        let session = request.value("x-claude-code-session-id")
        let (config, states, pin) = lock.withLock { (self.config, state.accounts, session.flatMap { state.pins[$0] }) }
        let candidates = Router.candidates(config: config, states: states, model: model, mainUUID: main?.uuid, pin: pin)
        /// The last "limit reached" answer, kept to hand to Claude Code if no later account can serve:
        /// it carries the real reset time, unlike an extra account's sign-in error.
        var refusal: (head: HTTPHead, body: Data)?

        candidates: for (index, ref) in candidates.enumerated() {
            let key = Router.stateKey(ref, mainUUID: main?.uuid)
            let isLast = index == candidates.count - 1
            var outgoing = request
            var outgoingBody = body
            var rejected: String?
            while true {
                if case .extra(let uuid) = ref {
                    let token: String
                    do {
                        token = try await deps.token(uuid, rejected)
                    } catch {
                        mutate { s in
                            if case ClaudeTokens.TokenError.signInAgain = error { s.accounts[key, default: .init()].signInNeeded = true }
                            s.accounts[key, default: .init()].lastError = error.localizedDescription
                        }
                        continue candidates
                    }
                    outgoing.set("Authorization", "Bearer \(token)")
                    // The body names the sending account too; make it the one whose token goes with it.
                    outgoingBody = Router.rewriteAccount(in: body, to: uuid)
                    outgoing.set("Content-Length", String(outgoingBody.count))
                } else if let incoming {
                    outgoing.set("Authorization", incoming)
                }

                let response = try await upstream.send(outgoing, outgoingBody)
                if response.statusCode == 401, case .extra = ref {
                    try await upstream.discard(response, method: outgoing.method)
                    if rejected == nil {
                        // Refresh once and try the same account again.
                        rejected = outgoing.value("authorization")?.replacingOccurrences(of: "Bearer ", with: "")
                        continue
                    }
                    mutate { s in
                        s.accounts[key, default: .init()].signInNeeded = true
                        s.accounts[key, default: .init()].lastError = "Claude refused this account's sign-in."
                    }
                    continue candidates
                }
                let reading = RateLimitReading.read(status: response.statusCode, headers: response.lowercasedHeaders)
                record(reading, key: key, ref: ref, main: main)

                if case .limited(_, _, let overage) = reading.verdict, !overage, !isLast {
                    refusal = (response, try await upstream.readBody(response, method: outgoing.method))
                    continue candidates
                }
                if request.path == "/v1/messages", (200..<300).contains(response.statusCode) {
                    settle(ref, session: session, lifetime: lifetime, mainUUID: main?.uuid, threshold: config.newSessionThreshold)
                }
                return try await upstream.relay(response, method: outgoing.method, to: client)
            }
        }
        // Every account was out or couldn't sign in: pass on Anthropic's own refusal.
        if let refusal {
            var head = refusal.head
            head.remove("transfer-encoding")
            head.set("Content-Length", String(refusal.body.count))
            try await client.send(head.serialized + refusal.body)
            return true
        }
        let response = try await upstream.send(request, body)
        return try await upstream.relay(response, method: request.method, to: client)
    }

    private func record(_ reading: RateLimitReading, key: String, ref: AccountRef, main: ClaudeOAuth.Profile?) {
        mutate { s in
            var account = s.accounts[key] ?? AccountLimitState()
            account.apply(reading, now: Date())
            account.lastUsed = Date()
            if case .ok = reading.verdict { account.lastError = nil }
            s.accounts[key] = account
            if ref == .main, let main {
                s.mainUUID = main.uuid
                s.mainEmail = main.email
                s.mainPlan = main.plan
            }
        }
    }

    /// Records where a session was served: its pin, and an event when a warm session had to move or
    /// new sessions start on another account than before.
    private func settle(_ ref: AccountRef, session: String?, lifetime: TimeInterval, mainUUID: String?, threshold: Double) {
        mutate { s in
            let now = Date()
            let key = ref.key
            func limits(_ account: String) -> AccountLimitState? {
                s.accounts[Router.stateKey(AccountRef(key: account), mainUUID: mainUUID)]
            }
            var isNew = true
            if let session {
                let previous = s.pins[session]
                let stayed = previous.map { $0.isWarm(now) && $0.account == key } ?? false
                isNew = !(previous?.isWarm(now) ?? false)
                let warmUntil = max(stayed ? previous!.warmUntil : now, now.addingTimeInterval(lifetime))
                s.pins[session] = SessionPin(account: key, lastUsed: now, warmUntil: warmUntil)
                if let previous, previous.isWarm(now), previous.account != key {
                    let reason = limits(previous.account).map(Router.reason) ?? "Limit reached"
                    let recent = s.events.last { $0.from == previous.account && $0.to == key && now.timeIntervalSince($0.at) < 600 }
                    if recent == nil { addEvent(&s, from: previous.account, to: key, reason: reason, kind: "moved", now: now) }
                }
                if s.pins.count > 300 {
                    let keep = s.pins.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(200)
                    s.pins = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                }
                s.pins = s.pins.filter { now.timeIntervalSince($0.value.lastUsed) < 24 * 3600 }
            }
            guard isNew, s.inUse != key else { return }
            let previous = s.inUse
            let reason: String
            if let previous, let prev = limits(previous), let until = prev.limitedUntil, until > now {
                reason = Router.reason(prev)
            } else if previous == nil {
                reason = "First request"
            } else if let previous, Router.load(limits(previous), now: now) >= threshold {
                reason = "Over \(Int((threshold * 100).rounded()))%"
            } else {
                reason = "Available again"
            }
            s.inUse = key
            addEvent(&s, from: previous, to: key, reason: reason, now: now)
        }
    }

    private func addEvent(_ s: inout RelayState, from: String?, to: String, reason: String, kind: String? = nil, now: Date) {
        s.events.append(RelayEvent(at: now, from: from, to: to, reason: reason, kind: kind))
        if s.events.count > 50 { s.events.removeFirst(s.events.count - 50) }
        relayLog("\(from ?? "-") → \(to) (\(reason))")
    }

    /// Who the token Claude Code sent belongs to, looked up once per token.
    private func mainProfile(_ authorization: String?) async -> ClaudeOAuth.Profile? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let token = String(authorization.dropFirst("Bearer ".count))
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = lock.withLock({ mains[hash] }),
           cached.profile != nil || Date().timeIntervalSince(cached.checked) < 300 {
            return cached.profile
        }
        let profile = await deps.profile(token)
        lock.withLock {
            if mains.count > 20 { mains.removeAll() }
            mains[hash] = (profile, Date())
        }
        return profile
    }
}

/// One TLS connection to `api.anthropic.com`, reused across requests while it stays open.
final class Upstream: @unchecked Sendable {
    private var stream: ByteStream?
    private var lastUsed = Date.distantPast
    private let host: String
    private let port: UInt16
    private let tls: Bool
    /// Part of the current response already went to the client.
    private(set) var responseStarted = false

    /// A connection idle longer than this is replaced rather than reused: servers close idle keep-alive
    /// connections, and a request written into one that is closing could not be told apart from one
    /// the server received.
    static let maxIdle: TimeInterval = 15

    init(host: String = Relay.upstreamHost, port: UInt16 = 443, tls: Bool = true) {
        self.host = host
        self.port = port
        self.tls = tls
    }

    private func open() async throws -> (ByteStream, reused: Bool) {
        if let stream, Date().timeIntervalSince(lastUsed) < Self.maxIdle { return (stream, true) }
        close()
        let params: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: options)
        } else {
            params = .tcp
        }
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let queue = DispatchQueue(label: "headroom.upstream")
        let ok = await Once.connect(connection, queue: queue)
        guard ok else { throw ProviderError.message("Could not reach \(host).") }
        let stream = ByteStream(connection)
        self.stream = stream
        return (stream, false)
    }

    func close() {
        stream?.close()
        stream = nil
    }

    /// Sends a request and reads the response head, skipping interim 1xx heads.
    ///
    /// A request is sent again only when a reused connection failed in a way that means the server
    /// never took it: the write failed, or the connection closed straight away without a byte. A
    /// request the server may be working on (an error or close after a while) is never resent, so it
    /// can't be billed twice.
    func send(_ head: HTTPHead, _ body: Data) async throws -> HTTPHead {
        responseStarted = false
        for attempt in 0..<2 {
            let (stream, reused) = try await open()
            let sentAt = Date()
            do {
                try await stream.send(head.serialized + body)
            } catch {
                close()
                if reused && attempt == 0 { continue }
                throw error
            }
            do {
                while let response = try await stream.readHead() {
                    if (100..<200).contains(response.statusCode), response.statusCode != 101 { continue }
                    lastUsed = Date()
                    return response
                }
                // Clean close before any response.
                close()
                if reused && attempt == 0 && Date().timeIntervalSince(sentAt) < 1 { continue }
                throw ProviderError.message("\(host) closed the connection.")
            } catch {
                close()
                throw error
            }
        }
        throw ProviderError.message("\(host) closed the connection.")
    }

    /// Forwards the response head and body to the client unchanged. Returns whether both connections
    /// can be reused.
    func relay(_ response: HTTPHead, method: String, to client: ByteStream) async throws -> Bool {
        guard let stream else { throw ProviderError.message("No upstream connection.") }
        responseStarted = true
        try await client.send(response.serialized)
        let reusable = try await copyBody(of: response, method: method, from: stream) { try await client.send($0) }
        if reusable { lastUsed = Date() } else { close() }
        return reusable
    }

    /// Reads and drops a response body, keeping the connection usable.
    func discard(_ response: HTTPHead, method: String) async throws {
        _ = try await readBody(response, method: method)
    }

    /// Reads a whole response body as sent (still chunked if it came chunked, see `route`).
    func readBody(_ response: HTTPHead, method: String) async throws -> Data {
        guard let stream else { return Data() }
        var raw = Data()
        let reusable = try await copyBody(of: response, method: method, from: stream) { raw.append($0) }
        if reusable { lastUsed = Date() } else { close() }
        guard response.isChunked else { return raw }
        return Self.dechunk(raw)
    }

    /// Joins the chunks of a complete chunked body.
    static func dechunk(_ raw: Data) -> Data {
        var out = Data()
        var i = raw.startIndex
        while let lineEnd = raw[i...].range(of: Data("\r\n".utf8)) {
            let line = String(decoding: raw[i..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(line.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard raw.distance(from: start, to: raw.endIndex) >= size else { break }
            let end = raw.index(start, offsetBy: size)
            out.append(raw[start..<end])
            i = raw.index(end, offsetBy: min(2, raw.distance(from: end, to: raw.endIndex)))
        }
        return out
    }

    private func copyBody(of response: HTTPHead, method: String, from stream: ByteStream,
                          _ sink: (Data) async throws -> Void) async throws -> Bool {
        let code = response.statusCode
        let closes = response.value("connection")?.lowercased() == "close"
        if method == "HEAD" || code == 204 || code == 304 || (100..<200).contains(code) { return !closes }
        if response.isChunked {
            var scanner = ChunkedScanner()
            while !scanner.isDone {
                guard let data = try await stream.readSome() else { return false }
                let used = scanner.feed(data)
                try await sink(data.prefix(used))
                if used < data.count { stream.unread(data.suffix(from: data.startIndex + used)) }
            }
            return !closes
        }
        if let length = response.contentLength {
            var left = length
            while left > 0 {
                guard let data = try await stream.readSome() else { return false }
                let take = min(left, data.count)
                try await sink(data.prefix(take))
                if take < data.count { stream.unread(data.suffix(from: data.startIndex + take)) }
                left -= take
            }
            return !closes
        }
        // No length: the body runs until the server closes.
        while let data = try await stream.readSome() { try await sink(data) }
        return false
    }
}

func relayLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
