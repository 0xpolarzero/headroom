import Foundation
import Observation

/// The Stats tab's state. Scans run in the background; a click only reads the cube already in memory.
@MainActor @Observable
final class StatsModel {
    /// Scanning again sooner finds too little to be worth it.
    static let scanThrottle: TimeInterval = 30
    /// Transcripts get deleted, so the index keeps up even if the panel is never opened.
    static let backgroundInterval: TimeInterval = 3600

    private(set) var selection = StatsSelection()
    private(set) var page = StatsPage()
    /// The share read so far of a long first scan.
    private(set) var progress: Double?
    private(set) var hasData = false
    /// Done reading at least once, so empty means empty.
    private(set) var isReady = false

    @ObservationIgnored private var cube = UsageCube()
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var index: UsageIndex?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var shownDay = Date.distantPast

    private func show() {
        var next = cube.page(selection)
        if let day = selection.day, !next.bars.contains(where: { $0.start == day }) {
            selection.day = nil   // The day it was has left the period.
            next = cube.page(selection)
        }
        if next != page { page = next }
        hasData = !cube.isEmpty
        shownDay = Calendar.current.startOfDay(for: Date())
    }

    func pick(_ period: StatsPeriod) {
        selection.period = period
        selection.day = nil
        show()
    }

    /// Narrows everything to one bar, or back out of it.
    func toggle(bar start: Int32) {
        selection.day = selection.day == start ? nil : start
        show()
    }

    func open(project: String?) {
        selection.project = project
        selection.day = nil
        show()
    }

    /// Reads what's new, if it's been long enough. `accounts` gives the name of each account, by id.
    func refresh(accounts: @escaping @Sendable (String) -> String, after interval: TimeInterval = StatsModel.scanThrottle) {
        guard !isDemo else { return }
        guard !scanning, Date().timeIntervalSince(lastScan) >= interval else {
            if loaded, Calendar.current.startOfDay(for: Date()) != shownDay { show() }
            return
        }
        scanning = true
        let index = index
        Task.detached(priority: .utility) { [weak self] in
            let index = index ?? UsageIndex()
            let changed = index?.update { share in
                Task { @MainActor [weak self] in self?.report(share) }
            } ?? false
            let reload = await self?.needsLoad(changed) ?? false
            let hour = Int32(Date().timeIntervalSince1970 / 3600) - Int32(UsageIndex.historyDays) * 24
            let cube = reload ? UsageCube.load(sinceHour: hour, accountName: accounts) : nil
            await self?.finished(index, cube)
        }
    }

    private func needsLoad(_ changed: Bool) -> Bool { changed || !loaded }

    /// Ignores a report that arrives after the scan it came from.
    private func report(_ share: Double) {
        if scanning { progress = share }
    }

    private func finished(_ index: UsageIndex?, _ cube: UsageCube?) {
        self.index = index
        scanning = false
        lastScan = Date()
        progress = nil
        isReady = true
        if let cube {
            self.cube = cube
            loaded = true
        }
        show()
    }

    func loadForSnapshots(path: String) {
        let hour = Int32(Date().timeIntervalSince1970 / 3600) - Int32(UsageIndex.historyDays) * 24
        cube = UsageCube.load(path: path, sinceHour: hour, accountName: AppModel.statsName(id:)) ?? cube
        show()
    }

    /// Made-up usage for screenshots: nothing is read from this Mac.
    func loadDemo() {
        isDemo = true
        var cube = UsageCube()
        cube.models = [("Opus 5.5", .claude), ("Sonnet 5.5", .claude), ("GPT-6.1 Sol", .codex), ("Gemini 4 Argon", .antigravity)]
        cube.projects = ["atlas", "harbor", "website", "research"]
        cube.accounts = [("Claude Max 20x", .claude), ("Claude Team", .claude), ("Codex Pro 200", .codex), ("Antigravity Ultra", .antigravity)]
        cube.firstHour = [0, 0, 0]
        let now = Int32(Date().timeIntervalSince1970 / 3600)
        var session: Int32 = 0
        for age in stride(from: Int32(24 * 30), through: 0, by: -3) {
            for (i, weight) in [1.0, 0.6, 0.35, 0.15].enumerated() {
                session += 1
                let wave = 1 + 0.7 * sin(Double(age) / 11 + Double(i))
                let provider = i == 0 || i == 1 ? 0 : i == 2 ? 1 : 2
                cube.rows.append(.init(hour: now - age, session: session, usd: Float(weight * wave * 14), tokens: Int64(weight * wave * 42e6),
                                       model: UInt16(i), project: UInt16((Int(session) / 3 + i) % 4), account: UInt16(i), provider: UInt8(provider), agent: age % 9 != 0))
            }
        }
        cube.sessionCount = Int(session) + 1
        self.cube = cube
        loaded = true
        isReady = true
        show()
    }
}
