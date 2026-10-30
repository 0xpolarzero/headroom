import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Updates from GitHub releases: finds a newer release, downloads its zip, checks it (SHA-256, this app at that version,
/// signed by the same certificate as the running copy), then swaps the bundle in place and relaunches.
/// Running subagents aren't touched: they're Claude Code's processes, and the app quitting doesn't stop them.
@Observable
@MainActor
final class Updater {
    enum Phase: Equatable {
        case idle
        case available
        case downloading
        /// Verified and unpacked, waiting for a restart.
        case ready
        case installing
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Release: Equatable, Sendable {
        let version: String
        let zip: URL
        let checksum: URL?
        let page: URL
    }

    static let repo = "amontlabs/lastdrop"
    /// The release asset, the same name in every release, so `releases/latest/download/lastdrop.zip` always works.
    nonisolated static let asset = "lastdrop.zip"
    static let interval: TimeInterval = 3600
    /// Where the latest release is read. `LASTDROP_UPDATE_FEED` points it elsewhere, for trying a whole update on this
    /// Mac: a release from there must still be signed like the running app.
    nonisolated private static var feed: URL {
        ProcessInfo.processInfo.environment["LASTDROP_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase == .ready, let version = release?.version { onReady(version) } }
    }
    private(set) var release: Release?
    /// The download's progress in whole percents (0...1).
    private(set) var fraction = 0.0
    private(set) var checking = false
    private(set) var lastCheck: Date?
    /// Why the last check you asked for failed.
    private(set) var checkError: String?

    /// Asked before each automatic check, and whether a found version was skipped.
    @ObservationIgnored var automatic: () -> Bool = { true }
    @ObservationIgnored var skipped: () -> String? = { nil }
    @ObservationIgnored var onSkip: (String) -> Void = { _ in }
    /// A release was downloaded and verified.
    @ObservationIgnored var onReady: (String) -> Void = { _ in }
    /// Looks up the newest release; tests swap it for a canned one.
    @ObservationIgnored var latest: () async throws -> Release = Updater.latest
    /// Swaps the app in and quits; tests stand in for it.
    @ObservationIgnored var installer: (URL) throws -> Void = Updater.swapIn
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var staged: URL?
    var stagedPath: String? { staged?.path }
    @ObservationIgnored private var progress: NSKeyValueObservation?
    /// The zip in flight, so Skip can stop the transfer and not only the task waiting on it.
    @ObservationIgnored private var transfer: URLSessionDownloadTask?
    @ObservationIgnored private var wake: NSObjectProtocol?
    /// Downloads started by an automatic check fail quietly and are tried again at the next check, unless the
    /// failure says the release can't be trusted (see `UpdateError.untrusted`).
    @ObservationIgnored private var quiet = false

    let current: String
    private var forceRelease: Bool

    /// `current` and `forceRelease` let `--update` pretend to be an older release.
    init(current: String? = nil, forceRelease: Bool = false) {
        self.current = current ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        self.forceRelease = forceRelease
    }

    /// Builds from source (`0.0.0-dev`, or not a bundle) never update themselves.
    var isRelease: Bool {
        forceRelease || (Bundle.main.bundleIdentifier != nil && Version(current) != nil && !current.contains("dev"))
    }

    /// Whether the panel has something to say: a background download stays silent until it's ready, or until it's
    /// left to you.
    var showsInPanel: Bool {
        guard release != nil else { return false }
        switch phase {
        case .available, .ready, .installing, .failed: return true
        case .downloading: return !quiet
        case .idle: return false
        }
    }

    /// Checks shortly after launch, every hour and on wake from sleep.
    func start() {
        guard isRelease, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if let self, self.automatic() { await self.update(manual: false) }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if let self, self.automatic() { await self.update(manual: false) }
            }
        }
    }

    /// Checks, then fetches and verifies anything new in the background.
    func update(manual: Bool) async {
        await check(manual: manual)
        // A download that failed without a staged app is tried again, as a quiet one was before it was shown.
        if case .failed = phase, staged == nil, release != nil { phase = .available }
        guard phase == .available else { return }
        quiet = !manual
        download()
    }

    // MARK: Check

    func check(manual: Bool) async {
        guard isRelease, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let found = try await latest()
            lastCheck = Date()
            checkError = nil
            guard let new = Version(found.version), let old = Version(current), new > old else {
                if case .available = phase { phase = .idle }
                if phase == .idle { release = nil }
                return
            }
            // What's being fetched or installed finishes first: a newer release waits for the next check.
            if phase == .downloading || phase == .installing { return }
            // Don't drop a staged update for the same release.
            if release == found, phase != .idle, phase != .available { return }
            if !manual, skipped() == found.version { return }
            release = found
            phase = .available
        } catch {
            if manual { checkError = error.localizedDescription }
        }
    }

    private nonisolated static func latest() async throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.session.data(for: request)
        // A feed on this disk has no status.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("GitHub didn't answer (\(http.statusCode))") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name == asset }) else {
            throw UpdateError("The latest release has no app to download")
        }
        let checksum = payload.assets.first { $0.name == zip.name + ".sha256" }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, zip: zip.browser_download_url, checksum: checksum?.browser_download_url, page: payload.html_url)
    }

    // MARK: Download

    /// Downloads and verifies the release; the panel then offers a restart.
    func download() {
        guard let release, work == nil else { return }
        fraction = 0
        // Whatever was verified for an older release is not this one.
        staged = nil
        phase = .downloading
        work = Task {
            // Skipped meanwhile (`skip()` has cleared `work` and said where things stand): nothing here may publish.
            defer { if !Task.isCancelled { work = nil; progress = nil; transfer = nil } }
            do {
                // Without a checksum there's nothing to check the download against: don't even fetch it.
                guard let checksum = release.checksum else { throw UpdateError("The release has no checksum to verify the download", untrusted: true) }
                let zip = try await fetch(release.zip)
                defer { try? FileManager.default.removeItem(at: zip) }
                try Task.checkCancellation()
                try await Self.verifyChecksum(of: zip, against: checksum)
                // Unpacking and checking the signature take a while: not on the main thread.
                let target = Bundle.main.bundleURL
                let app = try await Task.detached(priority: .utility) { try Self.unpack(zip, version: release.version, beside: target) }.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                    return
                }
                staged = app
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                phase = quiet && (error as? UpdateError)?.untrusted != true ? .available : .failed(error.localizedDescription)
            }
            quiet = false
        }
    }

    /// The `.sha256` asset holds `<hex digest>  <file name>`; the zip must hash to that digest.
    nonisolated static func verifyChecksum(of zip: URL, against checksum: URL) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTP.session.data(from: checksum)
        } catch {
            throw UpdateError("Couldn't read the release checksum", untrusted: true)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("Couldn't read the release checksum", untrusted: true) }
        let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw UpdateError("The download is corrupted (checksum mismatch)", untrusted: true) }
    }

    private func report(_ completed: Double) {
        let percent = (completed * 100).rounded(.down) / 100
        guard phase == .downloading, fraction != percent else { return }
        fraction = percent
    }

    private func fetch(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let task = HTTP.session.downloadTask(with: url) { file, response, error in
                if let error { return continuation.resume(throwing: error) }
                let failed = (response as? HTTPURLResponse).map { $0.statusCode != 200 } ?? false
                guard let file, !failed else { return continuation.resume(throwing: UpdateError("The download failed")) }
                // The file is deleted when this handler returns.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("lastdrop-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: file, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let completed = p.fractionCompleted
                Task { @MainActor in self?.report(completed) }
            }
            transfer = task
            task.resume()
        }
    }

    /// Unzips the release on the volume of the app it replaces (the swap only works within a volume), and checks
    /// it's this app, at that version, signed like the running one.
    nonisolated static func unpack(_ zip: URL, version: String, beside target: URL, requirement: SecRequirement? = nil,
                                   bundleID: String? = Bundle.main.bundleIdentifier) throws -> URL {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            let app = dir.appendingPathComponent("lastdrop.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
                throw UpdateError("The download isn't lastdrop", untrusted: true)
            }
            guard bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError("The download isn't version \(version)", untrusted: true)
            }
            try verifySignature(app, requirement ?? ownRequirement())
            return app
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// What a release must satisfy: the running app's designated requirement, i.e. its certificate. An ad-hoc copy has
    /// no certificate to compare, and a hash of itself as its requirement, so it can't tell a real release from another.
    nonisolated private static func ownRequirement() throws -> SecRequirement {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopySigningInformation(meStatic, [], &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else {
            throw UpdateError("The download's signature can't be checked", untrusted: true)
        }
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            throw UpdateError("This copy isn't signed, so it can't verify updates: download the new one by hand", untrusted: true)
        }
        var requirement: SecRequirement?
        SecCodeCopyDesignatedRequirement(meStatic, [], &requirement)
        guard let requirement else { throw UpdateError("The download's signature can't be checked", untrusted: true) }
        return requirement
    }

    nonisolated static func verifySignature(_ app: URL, _ requirement: SecRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download isn't signed", untrusted: true)
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed by lastdrop's certificate", untrusted: true)
        }
    }

    // MARK: Install

    /// Swaps the bundle in and restarts into it.
    func install() {
        // Failed: the restart itself did, so the verified app is still here to try again with.
        guard phase == .ready || phase.isFailed, let staged else { return }
        // The system clears its temporary folders, and an update can wait a while for its restart.
        guard FileManager.default.fileExists(atPath: staged.path) else {
            self.staged = nil
            quiet = false
            return download()
        }
        phase = .installing
        do {
            try installer(staged)
        } catch {
            // Damaged while it waited: the next try fetches it again.
            if (error as? UpdateError)?.untrusted == true {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                self.staged = nil
            }
            phase = .failed(error.localizedDescription)
        }
    }

    private static func swapIn(_ staged: URL) throws {
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") {
            throw UpdateError("Move lastdrop to Applications (and clear its quarantine) to update it")
        }
        // Checked again: it may have lost files in the temporary folder since it was downloaded.
        try verifySignature(staged, ownRequirement())
        try swap(staged, target)
        // After the swap `staged` is the old app, which this process is still running from.
        let script = """
        while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2"
        /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
        /usr/bin/open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), staged.deletingLastPathComponent().path, target.path]
        do {
            try process.run()
        } catch {
            try swap(staged, target)
            throw error
        }
        NSApplication.shared.terminate(nil)
    }

    /// Exchanges two bundles in one step: a failure leaves both where they were, and `lastdrop --agent-run`, which
    /// Claude Code can start at any moment, never finds the app missing.
    nonisolated static func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == EACCES || errno == EPERM {
                throw UpdateError("Can't write to \(b.deletingLastPathComponent().path): download the new version by hand")
            }
            throw UpdateError("Couldn't replace the app (\(String(cString: strerror(errno))))")
        }
    }

    /// Screenshots: show a release in a given phase without touching the network.
    func preview(_ phase: Phase, version: String = "0.3.0", fraction: Double = 0, staged: URL? = nil) {
        let page = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(version)")!
        forceRelease = true
        release = Release(version: version, zip: page, checksum: nil, page: page)
        lastCheck = Date().addingTimeInterval(-600)
        self.phase = phase
        self.fraction = fraction
        self.staged = staged
    }

    // MARK: Actions

    /// The one thing to do next: download, retry, or restart.
    func advance() {
        switch phase {
        case .available: quiet = false; download()
        case .failed: quiet = false; staged == nil ? download() : install()
        case .ready: install()
        case .idle, .downloading, .installing: break
        }
    }

    func skip() {
        guard let release else { return }
        work?.cancel()
        transfer?.cancel()
        work = nil
        progress = nil
        quiet = false
        onSkip(release.version)
        self.release = nil
        phase = .idle
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the download") }
    }
}

/// `lastdrop --update <version> [--install]`: pretends to be that version, then checks, downloads and verifies the latest
/// release, and with `--install` swaps it in and opens it. Run it from the app bundle so the bundle and signature checks apply.
enum UpdateCheck {
    static func main(as version: String, install: Bool) -> Never {
        Task { @MainActor in
            let updater = Updater(current: version, forceRelease: true)
            await updater.check(manual: true)
            print("current:", version, "latest:", updater.release?.version ?? "-", "phase:", updater.phase, updater.checkError ?? "")
            guard updater.phase == .available else { exit(updater.checkError == nil ? 0 : 1) }
            updater.download()
            while updater.phase == .downloading { try? await Task.sleep(for: .milliseconds(100)) }
            print("phase:", updater.phase, updater.stagedPath ?? "")
            guard updater.phase == .ready else { exit(1) }
            guard install else { exit(0) }
            updater.install()
            print("phase:", updater.phase)
            exit(updater.phase == .installing ? 0 : 1)
        }
        dispatchMain()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    /// The release failed a check: shown even when a check started the download, not retried in silence.
    let untrusted: Bool
    init(_ message: String, untrusted: Bool = false) {
        self.message = message
        self.untrusted = untrusted
    }
    var errorDescription: String? { message }
}

/// `1.2.3` style versions, compared numerically (a leading `v` is ignored).
struct Version: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
