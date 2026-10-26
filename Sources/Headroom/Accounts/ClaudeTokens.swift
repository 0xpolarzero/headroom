import Foundation

/// Logins of the accounts Headroom added, in the keychain under service `Headroom`.
///
/// Both the app and the relay may need a fresh access token. Refresh tokens can rotate, so only one
/// process may refresh at a time: a file lock around read, refresh and write-back makes the second one
/// pick up the token the first one just saved instead of spending the old refresh token again.
actor ClaudeTokens {
    static let shared = ClaudeTokens()
    static let service = "Headroom"

    enum TokenError: LocalizedError {
        case missing, signInAgain, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .missing: "No saved sign-in for this account."
            case .signInAgain: "This account's sign-in has ended. Sign in again."
            case .unavailable(let s): s
            }
        }
    }

    private var cache: [String: ClaudeOAuth.Login] = [:]
    /// One refresh at a time per account in this process; later callers wait for it.
    private var inflight: [String: Task<Result<ClaudeOAuth.Login, TokenError>, Never>] = [:]

    static func keychainAccount(_ uuid: String) -> String { "claude.\(uuid)" }

    static func read(_ uuid: String) -> ClaudeOAuth.Login? {
        guard let raw = Keychain.readOwn(service: service, account: keychainAccount(uuid)) else { return nil }
        return try? JSONDecoder.headroom.decode(ClaudeOAuth.Login.self, from: Data(raw.utf8))
    }

    @discardableResult
    static func write(_ uuid: String, _ login: ClaudeOAuth.Login) -> Bool {
        guard let data = try? JSONEncoder.headroom.encode(login) else { return false }
        return Keychain.writeOwn(service: service, account: keychainAccount(uuid), value: String(decoding: data, as: UTF8.self))
    }

    static func delete(_ uuid: String) {
        Keychain.delete(service: service, account: keychainAccount(uuid))
    }

    func save(_ uuid: String, _ login: ClaudeOAuth.Login) -> Bool {
        cache[uuid] = login
        return Self.write(uuid, login)
    }

    func forget(_ uuid: String) {
        cache[uuid] = nil
        Self.delete(uuid)
    }

    /// An access token valid for at least `margin` seconds, refreshing it if needed.
    /// `rejected` is a token the server just answered 401 to: refresh even if it looks valid.
    func accessToken(_ uuid: String, margin: TimeInterval = 300, rejected: String? = nil) async throws -> String {
        if let login = cache[uuid], login.accessToken != rejected, login.expiresAt.timeIntervalSinceNow > margin {
            return login.accessToken
        }
        // A caller with a rejected token can't share a refresh started without it: that one may hand
        // back the very token the server just refused.
        let shared = rejected == nil ? inflight[uuid] : nil
        let task = shared ?? Task.detached {
            await Self.withLock {
                // Another process may have refreshed since our cache was filled.
                guard let stored = Self.read(uuid) else { return .failure(.missing) }
                if stored.accessToken != rejected, stored.expiresAt.timeIntervalSinceNow > margin { return .success(stored) }
                switch await ClaudeOAuth.refresh(stored.refreshToken) {
                case .refreshed(let login):
                    // Save before use, so a crash can't strand an already spent refresh token.
                    guard Self.write(uuid, login) else { return .failure(.unavailable("Could not save the new sign-in.")) }
                    return .success(login)
                case .revoked: return .failure(.signInAgain)
                case .unavailable(let why): return .failure(.unavailable(why))
                }
            }
        }
        if rejected == nil { inflight[uuid] = task }
        let result = await task.value
        if inflight[uuid] == task { inflight[uuid] = nil }
        switch result {
        case .success(let login):
            cache[uuid] = login
            return login.accessToken
        case .failure(let error):
            if case .signInAgain = error { cache[uuid] = nil }
            throw error
        }
    }

    /// Runs `body` holding an exclusive lock shared with the other Headroom process. Polls rather than
    /// blocks, so waiting never ties up one of the few concurrency threads the relay serves with.
    /// After 30 s it goes ahead anyway: a stuck lock must not stop every request.
    private static func withLock<T>(_ body: () async -> T) async -> T {
        HeadroomPaths.ensure(HeadroomPaths.support)
        let fd = open(HeadroomPaths.tokenLock.path, O_CREAT | O_RDWR, 0o600)
        var locked = false
        if fd >= 0 {
            for _ in 0..<600 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer {
            if locked { flock(fd, LOCK_UN) }
            if fd >= 0 { close(fd) }
        }
        return await body()
    }
}
