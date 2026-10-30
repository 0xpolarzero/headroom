import SwiftUI

/// Usage by day and project, in tokens and API prices. Reads `StatsModel`'s page; nothing here touches the disk.
struct StatsPanel: View {
    let stats: StatsModel

    var body: some View {
        let page = stats.page
        VStack(alignment: .leading, spacing: 14) {
            if let project = stats.selection.project {
                Button { stats.open(project: nil) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(project).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            StatsPeriods(stats: stats)
            if !stats.hasData {
                StatsEmpty(stats: stats)
            } else {
                StatsHeader(page: page, days: stats.selection.period.days,
                            picked: stats.selection.day.flatMap { day in page.bars.first { $0.start == day }?.hover }) {
                    if let day = stats.selection.day { stats.toggle(bar: day) }
                }
                StatsBars(bars: page.bars, picked: stats.selection.day) { stats.toggle(bar: $0) }
                if let note = page.note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
                if stats.selection.project == nil {
                    StatsTable(title: "Projects", rows: page.projects, limit: 6) { stats.open(project: $0) }
                    StatsTable(title: "Accounts", rows: page.accounts)
                    StatsTable(title: "Models", rows: page.models, limit: 5)
                } else {
                    StatsTable(title: "Who did the work", rows: page.work)
                    StatsTable(title: "Agents by model", rows: page.models)
                }
                if let progress = stats.progress { StatsProgress(share: progress) }
            }
        }
        .padding(6)
    }
}

private struct StatsProgress: View {
    let share: Double

    var body: some View {
        ProgressView(value: share) { Text("Reading your history").font(.caption).foregroundStyle(.secondary) }
    }
}

private struct StatsEmpty: View {
    let stats: StatsModel

    var body: some View {
        Group {
            if stats.isReady {
                Text("No usage on this Mac yet.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                StatsProgress(share: stats.progress ?? 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

private struct StatsPeriods: View {
    let stats: StatsModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                let on = period == stats.selection.period
                Button { stats.pick(period) } label: {
                    Text(period.rawValue)
                        .font(.caption.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(on ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct StatsHeader: View {
    let page: StatsPage
    let days: Int
    let picked: String?
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatsFormat.usd(page.usd)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("at API prices").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let picked {
                    Button(action: clear) {
                        HStack(spacing: 4) {
                            Text(picked)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Brand.accent.opacity(0.18), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("\(StatsFormat.tokens(page.tokens)) tokens · \(StatsFormat.count(page.agents)) agents · \(StatsFormat.count(page.sessions)) sessions")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let change = page.change {
                Text("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))% on the \(days) days before").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One `Canvas`, not a view per bar: 30 stacked bars redraw in one pass, and hovering touches nothing else.
private struct StatsBars: View {
    let bars: [StatsBar]
    let picked: Int32?
    let pick: (Int32) -> Void
    @State private var hovered: Int?
    @State private var width: CGFloat = 0

    private static let height: CGFloat = 72, axis: CGFloat = 15
    private var gap: CGFloat { bars.count > 10 ? 1.5 : 5 }
    private var peak: Double { max(bars.map(\.total).max() ?? 0, 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas(rendersAsynchronously: false) { context, size in draw(&context, size) }
                .frame(height: Self.height + Self.axis)
                .overlay(alignment: .topLeading) { caption }
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { hovered = index(at: point.x) } else { hovered = nil }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    if let i = index(at: tap.location.x) { pick(bars[i].start) }
                })
            HStack(spacing: 10) {
                if bars.contains(where: { $0.claude > 0 }) { legend(.statsClaude, "Claude") }
                if bars.contains(where: { $0.codex > 0 }) { legend(.statsCodex, "Codex") }
                if bars.contains(where: { $0.antigravity > 0 }) { legend(.statsAntigravity, "Antigravity") }
            }
        }
    }

    /// The scale, or the hovered bar.
    private var caption: some View {
        Group {
            if let hovered, bars.indices.contains(hovered) {
                Text("\(bars[hovered].hover) · \(StatsFormat.usd(bars[hovered].total))").foregroundStyle(.secondary)
            } else {
                Text(StatsFormat.short(peak)).foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .allowsHitTesting(false)
    }

    private func index(at x: CGFloat) -> Int? {
        guard !bars.isEmpty, width > 0, x >= 0, x < width else { return nil }
        return min(Int(x / width * CGFloat(bars.count)), bars.count - 1)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let width = (size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
        let scale = Self.height / peak
        for (i, bar) in bars.enumerated() {
            var drawing = context
            if let picked, picked != bar.start { drawing.opacity = 0.3 } else if hovered == i { drawing.opacity = 0.8 }
            let x = CGFloat(i) * (width + gap)
            var y = Self.height
            for (value, color) in [(bar.claude, Color.statsClaude), (bar.codex, .statsCodex), (bar.antigravity, .statsAntigravity)] {
                let height = value * scale
                guard height >= 0.5 else { continue }
                y -= height
                let rect = CGRect(x: x, y: y, width: width, height: max(height, 1))
                drawing.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: .color(color))
                y -= 1
            }
        }
        context.fill(Path(CGRect(x: 0, y: Self.height, width: size.width, height: 1)), with: .color(.secondary.opacity(0.25)))
        for (i, bar) in bars.enumerated() {
            guard let label = bar.label else { continue }
            let text = context.resolve(Text(label).font(.caption2).foregroundStyle(.secondary))
            let center = (CGFloat(i) + 0.5) * (width + gap) - gap / 2
            let half = text.measure(in: size).width / 2
            context.draw(text, at: CGPoint(x: min(max(center, half), size.width - half), y: Self.height + Self.axis / 2 + 2))
        }
    }

    private func legend(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StatsTable: View {
    let title: String
    let rows: [StatsRow]
    var limit = Int.max
    var open: ((String) -> Void)?
    @State private var expanded = false

    var body: some View {
        let peak = max(rows.map(\.usd).max() ?? 0, 0.01)
        let shown = expanded ? rows[...] : rows.prefix(limit)
        VStack(alignment: .leading, spacing: 2) {
            columns(Text(title).font(.caption.weight(.semibold)), agents: "Agents", price: "Price", tokens: "Tokens", chevron: false)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(shown) { row in
                if let open {
                    Button { open(row.name) } label: { line(row, peak: peak) }.buttonStyle(.plain)
                } else {
                    line(row, peak: peak)
                }
            }
            if shown.count < rows.count {
                Button("\(rows.count - shown.count) more") { expanded = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.top, 2)
            }
        }
    }

    private func line(_ row: StatsRow, peak: Double) -> some View {
        columns(HStack(spacing: 5) {
            if let provider = row.provider { ProviderLogo(id: provider, size: 12) }
            Text(row.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }, agents: row.agents > 0 ? StatsFormat.count(row.agents) : "–", price: row.usd > 0 ? StatsFormat.usd(row.usd) : "–",
                tokens: StatsFormat.tokens(row.tokens), chevron: open != nil)
            .frame(height: 22)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Brand.accent.opacity(0.16))
                    .scaleEffect(x: max(row.usd / peak, 0.006), anchor: .leading)
            }
            .contentShape(Rectangle())
    }

    private func columns(_ name: some View, agents: String, price: String, tokens: String, chevron: Bool) -> some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            Text(agents).frame(width: 44, alignment: .trailing)
            Text(price).frame(width: 56, alignment: .trailing)
            Text(tokens).frame(width: 48, alignment: .trailing)
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, alignment: .trailing)
                    .opacity(chevron ? 1 : 0)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 5)
    }
}

private enum StatsFormat {
    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func count(_ value: Int) -> String { grouped.string(from: NSNumber(value: value)) ?? "\(value)" }

    static func usd(_ value: Double) -> String {
        if value < 10 { return String(format: "$%.2f", value) }
        return "$" + (grouped.string(from: NSNumber(value: value)) ?? "")
    }

    static func short(_ value: Double) -> String {
        value >= 1000 ? String(format: "$%.1fK", value / 1000) : String(format: "$%.0f", value)
    }

    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1e9 { return String(format: "%.1fB", number / 1e9) }
        if number >= 1e6 { return String(format: "%.0fM", number / 1e6) }
        return String(format: "%.0fK", number / 1e3)
    }
}

private extension Color {
    private static func series(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) })
    }

    // Checked with the dataviz palette validator, for color blindness too, against both surfaces.
    static let statsClaude = series(0xD9713A, 0xD4703A)
    static let statsCodex = series(0x2B6FE6, 0x4F90F5)
    static let statsAntigravity = series(0x169A6E, 0x23A574)
}
