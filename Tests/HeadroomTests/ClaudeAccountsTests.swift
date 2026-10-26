import Network
import XCTest
@testable import Headroom

final class ClaudeAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: Rate-limit headers

    func testLimitReachedIsLimitedUntilReset() {
        let reading = RateLimitReading.read(status: 429, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-representative-claim": "five_hour",
            "anthropic-ratelimit-unified-reset": "1793018000",
            "retry-after": "18000",
        ], now: now)
        XCTAssertEqual(reading.verdict, .limited(until: Date(timeIntervalSince1970: 1_793_018_000), claim: "five_hour", overage: false))
        XCTAssertNil(reading.scope)
    }

    func testServedAsExtraUsageCountsAsLimited() {
        let reading = RateLimitReading.read(status: 200, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-overage-status": "allowed",
            "anthropic-ratelimit-unified-representative-claim": "seven_day",
            "anthropic-ratelimit-unified-reset": "1793100000",
        ], now: now)
        XCTAssertEqual(reading.verdict, .limited(until: Date(timeIntervalSince1970: 1_793_100_000), claim: "seven_day", overage: true))
    }

    func testHeaderless429IsNotAnAccountLimit() {
        XCTAssertEqual(RateLimitReading.read(status: 429, headers: ["retry-after": "3"], now: now).verdict, .other)
        XCTAssertEqual(RateLimitReading.read(status: 529, headers: [:], now: now).verdict, .other)
    }

    func testNormalResponseReadsUtilisation() {
        // The headers seen on a real response (docs/claude-accounts.md, result 2).
        let reading = RateLimitReading.read(status: 200, headers: [
            "anthropic-ratelimit-unified-status": "allowed_warning",
            "anthropic-ratelimit-unified-5h-utilization": "0.09",
            "anthropic-ratelimit-unified-7d-utilization": "0.92",
            "anthropic-ratelimit-unified-5h-reset": "1793031600",
            "anthropic-ratelimit-unified-7d-reset": "1793160000",
            "anthropic-ratelimit-unified-overage-status": "rejected",
        ], now: now)
        XCTAssertEqual(reading.verdict, .ok)
        XCTAssertEqual(reading.fiveHour, 0.09)
        XCTAssertEqual(reading.sevenDay, 0.92)
        XCTAssertEqual(reading.sevenDayReset, Date(timeIntervalSince1970: 1_793_160_000))
    }

    func testModelScopes() {
        XCTAssertEqual(RateLimitReading.scope(of: "seven_day_opus"), "opus")
        XCTAssertNil(RateLimitReading.scope(of: "seven_day"))
        XCTAssertNil(RateLimitReading.scope(of: "five_hour"))
        XCTAssertEqual(RateLimitReading.family(ofModel: "claude-opus-5-5"), "opus")
        XCTAssertEqual(RateLimitReading.family(ofModel: "claude-haiku-5-5"), "haiku")
        XCTAssertNil(RateLimitReading.family(ofModel: nil))
    }

    // MARK: Account state

    func testScopedLimitOnlyBlocksThatModel() {
        var state = AccountLimitState()
        state.apply(RateLimitReading.read(status: 429, headers: [
            "anthropic-ratelimit-unified-status": "rejected",
            "anthropic-ratelimit-unified-representative-claim": "seven_day_opus",
            "anthropic-ratelimit-unified-reset": "1793100000",
        ], now: now), now: now)
        XCTAssertFalse(state.isUsable(family: "opus", allowOverage: false, now: now))
        XCTAssertTrue(state.isUsable(family: "haiku", allowOverage: false, now: now))
        XCTAssertTrue(state.isUsable(family: "opus", allowOverage: false, now: Date(timeIntervalSince1970: 1_793_100_001)))
    }

    func testLimitClearsOnceServedAgain() {
        var state = AccountLimitState()
        state.limitedUntil = now.addingTimeInterval(3600)
        state.limitedClaim = "five_hour"
        XCTAssertFalse(state.isUsable(family: nil, allowOverage: false, now: now))
        state.apply(RateLimitReading.read(status: 200, headers: ["anthropic-ratelimit-unified-status": "allowed"], now: now), now: now)
        XCTAssertNil(state.limitedUntil)
        XCTAssertTrue(state.isUsable(family: nil, allowOverage: false, now: now))
    }

    func testOverageOnlyUsableWhenAllowed() {
        var state = AccountLimitState()
        state.limitedUntil = now.addingTimeInterval(3600)
        state.overage = true
        XCTAssertFalse(state.isUsable(family: nil, allowOverage: false, now: now))
        XCTAssertTrue(state.isUsable(family: nil, allowOverage: true, now: now))
    }

    // MARK: Router

    private func config(_ order: [AccountRef], accounts: [String]) -> ClaudeAccountsConfig {
        var c = ClaudeAccountsConfig()
        c.accounts = accounts.map { ClaudeAccount(uuid: $0, email: "\($0)@x", orgUUID: nil, plan: "Pro") }
        c.order = order
        return c
    }

    func testRouterFollowsPriorityAndSkipsLimited() {
        let c = config([.extra("pro"), .main], accounts: ["pro"])
        XCTAssertEqual(Router.candidates(config: c, states: [:], model: nil, mainUUID: "max", now: now), [.extra("pro"), .main])
        var limited = AccountLimitState()
        limited.limitedUntil = now.addingTimeInterval(600)
        XCTAssertEqual(Router.candidates(config: c, states: ["pro": limited], model: nil, mainUUID: "max", now: now), [.main])
        // After the reset it is first again.
        XCTAssertEqual(Router.candidates(config: c, states: ["pro": limited], model: nil, mainUUID: "max",
                                         now: now.addingTimeInterval(601)), [.extra("pro"), .main])
    }

    func testRouterKeepsMainAsLastResort() {
        let c = config([.main, .extra("pro")], accounts: ["pro"])
        var limited = AccountLimitState()
        limited.limitedUntil = now.addingTimeInterval(600)
        XCTAssertEqual(Router.candidates(config: c, states: ["max": limited, "pro": limited], model: nil, mainUUID: "max", now: now),
                       [.main])
    }

    func testConnectedMainAccountIsUsedThroughMain() {
        let c = config([.extra("max"), .extra("pro"), .main], accounts: ["max", "pro"])
        XCTAssertEqual(Router.candidates(config: c, states: [:], model: nil, mainUUID: "max", now: now), [.main, .extra("pro")])
    }

    func testNormalizeKeepsOneMainAndAddsNewAccountsFirst() {
        var c = config([.main, .main, .extra("gone")], accounts: ["new"])
        c.normalize()
        XCTAssertEqual(c.order, [.extra("new"), .main])
    }

    // MARK: settings.json

    private let original = """
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "env": {
        "API_TIMEOUT_MS": "3000000"
      },
      "permissions": {
        "allow": ["Bash(ls:*)"]
      },
      "model": "opus"
    }

    """

    func testSettingsAddBlankRemoveRoundTrips() throws {
        let added = try SettingsFile.update(original, env: [(key: "HTTPS_PROXY", value: "http://127.0.0.1:47812"),
                                                            (key: "NODE_EXTRA_CA_CERTS", value: "/a b/ca.pem")])
        XCTAssertEqual(added, original.replacingOccurrences(of: "\"API_TIMEOUT_MS\": \"3000000\"\n", with:
            "\"API_TIMEOUT_MS\": \"3000000\",\n    \"HTTPS_PROXY\": \"http://127.0.0.1:47812\",\n    \"NODE_EXTRA_CA_CERTS\": \"/a b/ca.pem\"\n"))
        XCTAssertEqual(SettingsFile.env(in: added)["NODE_EXTRA_CA_CERTS"], "/a b/ca.pem")

        let blanked = try SettingsFile.update(added, env: [(key: "HTTPS_PROXY", value: ""), (key: "NODE_EXTRA_CA_CERTS", value: "")])
        XCTAssertEqual(SettingsFile.env(in: blanked)["HTTPS_PROXY"], "")

        let removed = try SettingsFile.update(blanked, env: [(key: "HTTPS_PROXY", value: nil), (key: "NODE_EXTRA_CA_CERTS", value: nil)])
        XCTAssertEqual(removed, original)
    }

    func testSettingsCreatesAndRemovesEnv() throws {
        let plain = "{\n  \"model\": \"opus\"\n}\n"
        let added = try SettingsFile.update(plain, env: [(key: "HTTPS_PROXY", value: "x")])
        XCTAssertEqual(added, "{\n  \"env\": {\n    \"HTTPS_PROXY\": \"x\"\n  },\n  \"model\": \"opus\"\n}\n")
        XCTAssertEqual(try SettingsFile.update(added, env: [(key: "HTTPS_PROXY", value: nil)]), plain)
        XCTAssertEqual(SettingsFile.env(in: try SettingsFile.update("", env: [(key: "A", value: "1")])), ["A": "1"])
        XCTAssertEqual(SettingsFile.env(in: try SettingsFile.update("{}", env: [(key: "A", value: "1")])), ["A": "1"])
    }

    func testSettingsReplacesNonObjectEnv() throws {
        let out = try SettingsFile.update("{\n  \"env\": null,\n  \"model\": \"opus\"\n}\n", env: [(key: "A", value: "1")])
        XCTAssertEqual(SettingsFile.env(in: out), ["A": "1"])
        XCTAssertEqual(out.components(separatedBy: "\"env\"").count, 2)
    }

    func testClaudeCodeProcessPaths() {
        XCTAssertTrue(ClientProcess.isClaudeCode(path: "/Users/x/Library/Application Support/Claude/claude-code/2.1.308/a/claude.app/Contents/MacOS/claude"))
        XCTAssertTrue(ClientProcess.isClaudeCode(path: "/Users/x/.local/share/claude/versions/2.1.310"))
        XCTAssertFalse(ClientProcess.isClaudeCode(path: "/usr/bin/curl"))
        XCTAssertFalse(ClientProcess.isClaudeCode(path: "/opt/homebrew/bin/node"))
    }

    func testDechunk() {
        XCTAssertEqual(Upstream.dechunk(Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)), Data("Wikipedia".utf8))
    }

    func testSettingsRefusesNonJSON() {
        XCTAssertThrowsError(try SettingsFile.update("{ // comment\n}", env: [(key: "A", value: "1")]))
    }

    // MARK: HTTP framing

    func testChunkedScannerStopsAtEndOfBody() {
        var scanner = ChunkedScanner()
        let body = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        let next = Data("HTTP/1.1 200 OK\r\n".utf8)
        XCTAssertEqual(scanner.feed(body.prefix(7)), 7)
        XCTAssertFalse(scanner.isDone)
        XCTAssertEqual(scanner.feed(Data(body.dropFirst(7)) + next), body.count - 7)
        XCTAssertTrue(scanner.isDone)
    }

    func testHeadParsesAndEdits() {
        var head = HTTPHead.parse(Data("POST /v1/messages?beta=true HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer a\r\nContent-Length: 2".utf8))!
        XCTAssertEqual(head.path, "/v1/messages")
        XCTAssertEqual(head.contentLength, 2)
        head.set("authorization", "Bearer b")
        XCTAssertEqual(head.value("Authorization"), "Bearer b")
        XCTAssertEqual(head.headers.count, 3)
        XCTAssertEqual(RelayServer.split("api.anthropic.com:443").0, "api.anthropic.com")
        XCTAssertEqual(RelayServer.split("[::1]:8443").1, 8443)
    }

    // MARK: OAuth

    func testRefreshKeepsOldRefreshTokenWhenNotRotated() {
        let login = ClaudeOAuth.login(from: ["access_token": "new", "expires_in": 3600], previousRefresh: "old", now: now)
        XCTAssertEqual(login?.refreshToken, "old")
        XCTAssertEqual(login?.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(ClaudeOAuth.login(from: ["access_token": "a", "refresh_token": "rotated"], previousRefresh: "old")?.refreshToken, "rotated")
    }

    func testProfileParsing() {
        let profile = ClaudeOAuth.profile(from: [
            "account": ["uuid": "u1", "email": "me@x"],
            "organization": ["uuid": "o1", "organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"],
        ])
        XCTAssertEqual(profile?.uuid, "u1")
        XCTAssertEqual(profile?.plan, "Max 20x")
    }

    // MARK: Failover, end to end on loopback

    func testLimitedAccountFailsOverToMainWithinOneRequest() async throws {
        let server = try await FakeAnthropic.start()
        var deps = RelayEngine.Dependencies()
        var c = config([.extra("pro"), .main], accounts: ["pro"])
        c.routing = true
        deps.fixedConfig = c
        deps.persist = false
        deps.token = { _, _ in "pro-token" }
        deps.profile = { _ in ClaudeOAuth.Profile(uuid: "max", email: "max@x", orgUUID: nil, plan: "Max 20x") }
        deps.upstream = { Upstream(host: "127.0.0.1", port: server.port, tls: false) }
        let engine = RelayEngine(deps)
        let front = try await Front.start(engine: engine)

        func send() async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(front.port)/v1/messages?beta=true")!)
            request.httpMethod = "POST"
            request.setValue("Bearer max-token", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"model":"claude-haiku-5-5","messages":[]}"#.utf8)
            let (data, response) = try await HTTP.session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }

        let (status, body) = try await send()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "served by max-token")
        XCTAssertEqual(server.seen, ["pro-token", "max-token"])   // tried Pro, then Main, in one request
        let state = engine.snapshot
        XCTAssertEqual(state.inUse, "max")
        XCTAssertNotNil(state.accounts["pro"]?.limitedUntil)
        XCTAssertEqual(state.accounts["max"]?.sevenDay, 0.5)

        // The next request skips Pro until its reset.
        _ = try await send()
        XCTAssertEqual(server.seen, ["pro-token", "max-token", "max-token"])
        front.stop()
        server.stop()
    }

    /// Main is out and the only account left can't sign in: Claude Code gets Main's own "limit
    /// reached" (with its reset time), not the other account's 401.
    func testOutOfOptionsPassesOnTheLimitNotA401() async throws {
        let server = try await FakeAnthropic.start(limitedToken: "max-token", unauthorizedToken: "pro-token")
        var deps = RelayEngine.Dependencies()
        var c = config([.main, .extra("pro")], accounts: ["pro"])
        c.routing = true
        deps.fixedConfig = c
        deps.persist = false
        deps.token = { _, _ in "pro-token" }
        deps.profile = { _ in ClaudeOAuth.Profile(uuid: "max", email: nil, orgUUID: nil, plan: nil) }
        deps.upstream = { Upstream(host: "127.0.0.1", port: server.port, tls: false) }
        let engine = RelayEngine(deps)
        let front = try await Front.start(engine: engine)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(front.port)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer max-token", forHTTPHeaderField: "Authorization")
        request.setValue("100-continue", forHTTPHeaderField: "Expect")
        request.httpBody = Data(#"{"model":"claude-opus-5-5"}"#.utf8)
        let (data, response) = try await HTTP.session.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 429)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("rate_limit_error"))
        // Main once, Pro twice (once more after a refresh), and nothing sent twice otherwise.
        XCTAssertEqual(server.seen, ["max-token", "pro-token", "pro-token"])
        XCTAssertEqual(server.expects, 0)
        XCTAssertTrue(engine.snapshot.accounts["pro"]?.signInNeeded == true)
        front.stop()
        server.stop()
    }
}

/// Answers `/v1/messages` like Anthropic: 429 "limit reached" for `pro-token`, 200 for anything else.
private final class FakeAnthropic: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    private let lock = NSLock()
    private var _seen: [String] = []
    private var _expects = 0
    var seen: [String] { lock.withLock { _seen } }
    var expects: Int { lock.withLock { _expects } }
    let limitedToken: String
    let unauthorizedToken: String?

    private init(_ listener: NWListener, limitedToken: String, unauthorizedToken: String?) {
        self.listener = listener
        self.limitedToken = limitedToken
        self.unauthorizedToken = unauthorizedToken
    }

    static func start(limitedToken: String = "pro-token", unauthorizedToken: String? = nil) async throws -> FakeAnthropic {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = FakeAnthropic(try NWListener(using: params), limitedToken: limitedToken, unauthorizedToken: unauthorizedToken)
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task { await server.serve(ByteStream(connection)) }
        }
        try await server.ready()
        return server
    }

    private func ready() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { cont.resume() }
                if case .failed(let e) = state, once.claim() { cont.resume(throwing: e) }
            }
            listener.start(queue: .global())
        }
    }

    private func serve(_ stream: ByteStream) async {
        while let head = try? await stream.readHead(), (try? await stream.readBody(of: head)) != nil {
            let token = head.value("authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            lock.withLock {
                _seen.append(token)
                if head.value("expect") != nil { _expects += 1 }
            }
            let response: String
            if token == unauthorizedToken {
                response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
            } else if token == limitedToken {
                let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit exceeded"}}"#
                response = "HTTP/1.1 429 Too Many Requests\r\nanthropic-ratelimit-unified-status: rejected\r\n"
                    + "anthropic-ratelimit-unified-representative-claim: five_hour\r\n"
                    + "anthropic-ratelimit-unified-reset: \(Int(Date().timeIntervalSince1970) + 3600)\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
            } else {
                let body = "served by \(token)"
                response = "HTTP/1.1 200 OK\r\nanthropic-ratelimit-unified-status: allowed\r\n"
                    + "anthropic-ratelimit-unified-7d-utilization: 0.5\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            }
            try? await stream.send(Data(response.utf8))
        }
        stream.close()
    }

    func stop() { listener.cancel() }
}

/// Plain-HTTP front door that hands each connection to the engine, as the TLS listener does.
private final class Front: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }

    private init(_ listener: NWListener) { self.listener = listener }

    static func start(engine: RelayEngine) async throws -> Front {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let front = Front(try NWListener(using: params))
        front.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task { await engine.serve(ByteStream(connection), from: ClientProcess(pid: 0, path: "claude", startedAt: Date())) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            front.listener.stateUpdateHandler = { state in
                if case .ready = state, once.claim() { cont.resume() }
                if case .failed(let e) = state, once.claim() { cont.resume(throwing: e) }
            }
            front.listener.start(queue: .global())
        }
        return front
    }

    func stop() { listener.cancel() }
}
