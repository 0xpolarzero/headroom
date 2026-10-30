import Foundation

/// A time span the Stats tab can show.
enum StatsPeriod: String, CaseIterable, Sendable {
    case today = "Today"
    case week = "7 days"
    case month = "30 days"

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// One row of a Stats table.
struct StatsRow: Identifiable, Equatable, Sendable {
    var name: String
    var provider: ProviderID?
    var agents = 0
    var usd = 0.0
    var tokens: Int64 = 0
    var id: String { name }
}

/// One bar: a day, or an hour of today.
struct StatsBar: Equatable, Sendable {
    var start: Int32
    var label: String?
    var hover: String
    var claude = 0.0
    var codex = 0.0
    var antigravity = 0.0
    var total: Double { claude + codex + antigravity }
}

/// Everything the Stats tab shows at once.
struct StatsPage: Equatable, Sendable {
    var usd = 0.0
    var tokens: Int64 = 0
    var agents = 0
    var sessions = 0
    /// Against the same span just before; nil without history that far back.
    var change: Double?
    var bars: [StatsBar] = []
    var projects: [StatsRow] = []
    var accounts: [StatsRow] = []
    var models: [StatsRow] = []
    /// A project's split: its agents, then its user.
    var work: [StatsRow] = []
    var note: String?
}

/// What's on screen.
struct StatsSelection: Equatable, Sendable {
    var period = StatsPeriod.week
    /// The first hour of a picked bar.
    var day: Int32?
    var project: String?
}

/// The last two months of usage, in memory, in the compact form every click reads. All the Stats tab's answers
/// come from one pass over these rows, without a query or a dictionary, so changing period, day or project takes
/// microseconds, and there's nothing to invalidate but this.
struct UsageCube: Sendable {
    struct Row: Sendable {
        var hour: Int32
        var session: Int32
        var usd: Float
        var tokens: Int64
        var model: UInt16
        var project: UInt16
        var account: UInt16
        var provider: UInt8
        var agent: Bool
    }

    /// Sorted by hour.
    var rows: [Row] = []
    var sessionCount = 0
    var models: [(name: String, provider: ProviderID?)] = []
    var projects: [String] = []
    var accounts: [(name: String, provider: ProviderID?)] = []
    /// The first hour each provider has any rows.
    var firstHour: [Int32] = Array(repeating: .max, count: 3)

    var isEmpty: Bool { rows.isEmpty }

    static let providers: [ProviderID] = [.claude, .codex, .antigravity]

    private static func provider(ofModel name: String) -> ProviderID? {
        if name.hasPrefix("claude") { return .claude }
        if name.hasPrefix("gpt") || name.hasPrefix("codex") { return .codex }
        if name.hasPrefix("gemini") { return .antigravity }
        return nil
    }

    /// Reads the index on a connection of its own, which doesn't wait for a scan in progress.
    static func load(path: String = UsageIndex.defaultPath, sinceHour: Int32, accountName: @Sendable (String) -> String) -> UsageCube? {
        guard let db = SQLite(path: path, readOnly: true),
              let nameQuery = db.prepare("SELECT id, kind, text FROM name ORDER BY id"),
              let query = db.prepare("""
              SELECT u.hour, u.session, s.agent, u.model, u.size, u.project, u.account, u.input, u.write, u.write_long, u.read, u.output
              FROM usage u JOIN session s ON s.id = u.session WHERE u.hour >= ? ORDER BY u.hour
              """) else { return nil }
        var cube = UsageCube()

        // Names to small indexes, merging what reads the same: one model's dated versions, one account's two folders.
        var modelIndex: [Int64: UInt16] = [:], projectIndex: [Int64: UInt16] = [:], accountIndex: [Int64: UInt16] = [:]
        var prices: [Int64: UsagePrice?] = [:]
        var isReview: Set<Int64> = []
        var accountProvider: [Int64: UInt8] = [:]
        func intern<T: Equatable>(_ value: T, _ list: inout [T]) -> UInt16 {
            if let i = list.firstIndex(of: value) { return UInt16(i) }
            list.append(value)
            return UInt16(list.count - 1)
        }
        var modelNames: [String] = [], accountNames: [String] = []
        while nameQuery.next() {
            let id = nameQuery.int(0), text = nameQuery.text(2) ?? ""
            switch nameQuery.int(1) {
            case 0:
                let name = accountName(text)
                accountIndex[id] = intern(name, &accountNames)
                let provider = ProviderID(rawValue: String(text.prefix { $0 != "." }))
                if Int(accountIndex[id]!) == cube.accounts.count { cube.accounts.append((name, provider)) }
                accountProvider[id] = UInt8(provider.flatMap(providers.firstIndex(of:)) ?? 0)
            case 1:
                let name = text == "gemini" ? "Gemini" : UsagePrice.displayName(text)
                modelIndex[id] = intern(name, &modelNames)
                if Int(modelIndex[id]!) == cube.models.count { cube.models.append((name, provider(ofModel: text))) }
                prices[id] = UsagePrice.of(text)
                if text == "codex-auto-review" { isReview.insert(id) }
            default:
                projectIndex[id] = intern(text, &cube.projects)
            }
        }

        query.bind(.int(Int64(sinceHour)))
        var sessions: [Int64: Int32] = [:]
        cube.rows.reserveCapacity(1 << 14)
        while query.next() {
            let hour = Int32(truncatingIfNeeded: query.int(0)), session = query.int(1), model = query.int(3), account = query.int(6)
            let tokens = UsageTokens(input: query.int(7), cacheWrite: query.int(8), cacheWriteLong: query.int(9), cacheRead: query.int(10), output: query.int(11))
            let index = sessions[session] ?? {
                let next = Int32(sessions.count)
                sessions[session] = next
                return next
            }()
            let usd = prices[model]??.rates(sizeClass: query.int(4), hour: hour).cost(tokens) ?? 0
            let provider = accountProvider[account] ?? 0
            cube.firstHour[Int(provider)] = min(cube.firstHour[Int(provider)], hour)
            cube.rows.append(Row(hour: hour, session: index, usd: Float(usd), tokens: tokens.total, model: modelIndex[model] ?? 0,
                                 project: projectIndex[query.int(5)] ?? 0, account: accountIndex[account] ?? 0, provider: provider,
                                 agent: query.int(2) != 0 && !isReview.contains(model)))
        }
        cube.sessionCount = sessions.count
        return cube
    }

    // MARK: Pages

    /// A list of hours split into bars, from a calendar: days aren't always 24 hours.
    private struct Buckets {
        var starts: [Int32]
        var end: Int32

        func index(of hour: Int32) -> Int? {
            guard hour >= starts[0], hour < end else { return nil }
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= hour { low = middle } else { high = middle - 1 }
            }
            return low
        }
    }

    private static func hour(_ date: Date) -> Int32 { Int32(floor(date.timeIntervalSince1970 / 3600)) }

    func page(_ selection: StatsSelection, now: Date = Date(), calendar: Calendar = .current) -> StatsPage {
        let today = calendar.startOfDay(for: now)
        let period = selection.period
        let first = calendar.date(byAdding: .day, value: 1 - period.days, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let project = selection.project.flatMap { projects.firstIndex(of: $0) }.map(UInt16.init)
        var page = StatsPage()

        let days = (0..<period.days).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        let end = Self.hour(tomorrow)
        let buckets = Buckets(starts: period == .today ? Array(stride(from: Self.hour(today), to: end, by: 1)) : days.map(Self.hour), end: end)
        page.bars = buckets.starts.indices.map { i in
            let date = Date(timeIntervalSince1970: Double(buckets.starts[i]) * 3600)
            return StatsBar(start: buckets.starts[i], label: Self.label(i, count: buckets.starts.count, date: date, period: period, calendar: calendar),
                            hover: Self.hover(date, period: period))
        }
        // Bars keep the whole period; the numbers follow a picked bar.
        let span = selection.day.flatMap { day in buckets.starts.firstIndex(of: day).map { i in
            (day, i + 1 < buckets.starts.count ? buckets.starts[i + 1] : buckets.end)
        } } ?? (buckets.starts[0], buckets.end)
        fill(&page, buckets: buckets, span: span, project: project)

        if selection.day == nil, period != .today {
            let before = calendar.date(byAdding: .day, value: -period.days, to: first)!
            let spent = usd(from: Self.hour(before), to: buckets.starts[0], project: project)
            if firstHour.min() ?? .max <= Self.hour(before), spent > 0 { page.change = page.usd / spent - 1 }
        }
        if period == .month {
            page.note = zip(Self.providers, firstHour).first { $0.1 != .max && $0.1 > buckets.starts[0] + 24 }.map { provider, hour in
                "\(provider.displayName) history starts \(Self.shortDate(Date(timeIntervalSince1970: Double(hour) * 3600)))"
            }
        }
        return page
    }

    private func rowRange(_ start: Int32, _ end: Int32) -> Range<Int> {
        func lowerBound(_ hour: Int32) -> Int {
            var low = 0, high = rows.count
            while low < high {
                let middle = (low + high) / 2
                if rows[middle].hour < hour { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return lowerBound(start)..<lowerBound(end)
    }

    private func usd(from start: Int32, to end: Int32, project: UInt16?) -> Double {
        var total = 0.0
        for row in rows[rowRange(start, end)] where project == nil || row.project == project { total += Double(row.usd) }
        return total
    }

    /// One pass. A table's agent counts are distinct sessions per group, kept in bit sets, so nothing hashes.
    private func fill(_ page: inout StatsPage, buckets: Buckets, span: (Int32, Int32), project: UInt16?) {
        var byProject = [StatsRow](repeating: StatsRow(name: ""), count: projects.count)
        var byAccount = [StatsRow](repeating: StatsRow(name: ""), count: accounts.count)
        var byModel = [StatsRow](repeating: StatsRow(name: ""), count: models.count)
        var work = [StatsRow(name: "Agents"), StatsRow(name: "You")]
        let words = (sessionCount + 63) / 64
        var projectAgents = [UInt64](repeating: 0, count: words * projects.count)
        var accountAgents = [UInt64](repeating: 0, count: words * accounts.count)
        var modelAgents = [UInt64](repeating: 0, count: words * models.count)
        var seenAgents = [UInt64](repeating: 0, count: words), seenSessions = seenAgents

        @inline(__always) func mark(_ bits: inout [UInt64], group: Int, session: Int) -> Bool {
            let word = group * words + session >> 6, bit = UInt64(1) << UInt64(session & 63)
            let isNew = bits[word] & bit == 0
            bits[word] |= bit
            return isNew
        }

        for row in rows[rowRange(buckets.starts[0], buckets.end)] where project == nil || row.project == project {
            let usd = Double(row.usd)
            if let i = buckets.index(of: row.hour) {
                switch row.provider {
                case 0: page.bars[i].claude += usd
                case 1: page.bars[i].codex += usd
                default: page.bars[i].antigravity += usd
                }
            }
            guard row.hour >= span.0, row.hour < span.1 else { continue }
            let session = Int(row.session)
            page.usd += usd
            page.tokens += row.tokens
            byProject[Int(row.project)].usd += usd
            byProject[Int(row.project)].tokens += row.tokens
            byAccount[Int(row.account)].usd += usd
            byAccount[Int(row.account)].tokens += row.tokens
            if project == nil || row.agent {   // A project's model table is its agents'.
                byModel[Int(row.model)].usd += usd
                byModel[Int(row.model)].tokens += row.tokens
            }
            work[row.agent ? 0 : 1].usd += usd
            work[row.agent ? 0 : 1].tokens += row.tokens
            if row.agent {
                if mark(&seenAgents, group: 0, session: session) { page.agents += 1; work[0].agents += 1 }
                if mark(&projectAgents, group: Int(row.project), session: session) { byProject[Int(row.project)].agents += 1 }
                if mark(&accountAgents, group: Int(row.account), session: session) { byAccount[Int(row.account)].agents += 1 }
                if mark(&modelAgents, group: Int(row.model), session: session) { byModel[Int(row.model)].agents += 1 }
            } else if mark(&seenSessions, group: 0, session: session) {
                page.sessions += 1
            }
        }

        func finish(_ list: [StatsRow], names: (Int) -> (String, ProviderID?)) -> [StatsRow] {
            var rows: [StatsRow] = []
            for (i, var row) in list.enumerated() where row.tokens > 0 {
                (row.name, row.provider) = names(i)
                rows.append(row)
            }
            return rows.sorted { ($0.usd, $1.name) > ($1.usd, $0.name) }
        }
        page.projects = finish(byProject) { (projects[$0], nil) }
        page.accounts = finish(byAccount) { accounts[$0] }
        page.models = finish(byModel) { models[$0] }
        page.work = work.filter { $0.tokens > 0 }
    }

    private static func label(_ i: Int, count: Int, date: Date, period: StatsPeriod, calendar: Calendar) -> String? {
        switch period {
        case .today: i % 6 == 0 ? String(format: "%02d", calendar.component(.hour, from: date)) : nil
        case .week: date.formatted(.dateTime.weekday(.abbreviated).locale(english))
        case .month: i == count - 1 ? "Today" : i == 0 || i == 15 ? shortDate(date) : nil
        }
    }

    private static func hover(_ date: Date, period: StatsPeriod) -> String {
        period == .today ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(english))
            : date.formatted(.dateTime.weekday(.abbreviated).day().month().locale(english))
    }

    /// The app is in English; its dates shouldn't follow the Mac's language alone.
    private static let english = Locale(identifier: "en_GB")

    private static func shortDate(_ date: Date) -> String { date.formatted(.dateTime.day().month().locale(english)) }
}
