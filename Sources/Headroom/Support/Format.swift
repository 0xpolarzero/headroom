import Foundation

enum Format {
    /// "12m", "2h 15m", "3d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        if h < 24 { return m == 0 ? "\(h)h" : "\(h)h \(m)m" }
        let d = h / 24, rh = h % 24
        return rh == 0 ? "\(d)d" : "\(d)d \(rh)h"
    }

    static func resets(_ date: Date, now: Date = .now) -> String {
        let left = date.timeIntervalSince(now)
        return left <= 0 ? "Resetting now" : "Resets in \(duration(left))"
    }

    static func used(_ window: UsageWindow) -> String {
        if let detail = window.detail { return detail }
        guard let p = window.usedPercent else { return "—" }
        return "\(Int(p.rounded()))% used"
    }

    /// "14:30" today, "Tue 14:30" otherwise.
    static func clock(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
