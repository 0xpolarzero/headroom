import SwiftUI

/// A provider's mark in its brand colors.
struct ProviderLogo: View {
    let id: ProviderID
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Logos.image(id))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(LinearGradient(colors: id.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// The logo on a tile, as Settings lists accounts.
struct ProviderTile: View {
    let id: ProviderID

    var body: some View {
        ProviderLogo(id: id, size: 17)
            .frame(width: 28, height: 28)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// "Max 20x", "Plus": the plan beside a name.
struct PlanChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .lineLimit(1)
    }
}

/// "Limits" or "Agents" with a dot: green when it works, orange when it doesn't (the reason on hover).
struct CapabilityPill: View {
    let title: String
    let capability: Capability

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help(help)
    }

    private var color: Color {
        switch capability {
        case .ready: .green
        case .problem: .orange
        case .pending: .gray
        }
    }

    private var help: String {
        switch capability {
        case .ready: "\(title): working"
        case .problem(let reason): "\(title): \(reason)"
        case .pending: "\(title): checking…"
        }
    }
}

extension Capability {
    var problem: String? { if case .problem(let text) = self { text } else { nil } }
}

/// Small grey text under a title.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
