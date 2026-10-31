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

/// One fact about an agent as a small tag: an icon and a word.
struct Badge<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 3) {
            icon
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

/// Where an agent runs, as the same three tags everywhere: provider, model, effort. Each fallback gets a line
/// of its own under them, in the order they're tried.
struct AgentBadges: View {
    let agent: AgentDefinition
    /// For the panel: the provider as its logo alone, and shorter words.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(agent.chain.enumerated()), id: \.offset) { index, attempt in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "arrow.turn.down.right").imageScale(.small).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Badge(text: compact ? "" : attempt.provider.displayName) {
                        ProviderLogo(id: attempt.provider.usageID, size: 10)
                    }
                    Badge(text: attempt.model.isEmpty ? "No model" : attempt.model) {
                        Image(systemName: "cpu").imageScale(.small)
                    }
                    Badge(text: attempt.effort.map { $0.capitalized } ?? (compact ? "Auto" : "Claude decides")) {
                        Image(systemName: "brain").imageScale(.small)
                    }
                }
            }
        }
    }
}

/// An ⓘ that explains on hover, instead of a paragraph on the page.
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .imageScale(.small)
            .hoverTip(text)
            .accessibilityLabel(text)
    }
}

/// A setting's label: an icon in a fixed column, the title with its ⓘ, and an optional line under it. Every
/// setting row uses it, so icons and titles line up from row to row.
struct SettingLabel: View {
    let icon: String
    var color: Color = .secondary
    let title: String
    var tip: String?
    var detail: String?
    var detailColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if let tip { InfoTip(tip) }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(detailColor) }
            }
        }
    }
}

/// A setting with a switch. The switch stands apart from the label: inside a Toggle's label, the ⓘ never
/// gets the pointer, so its tip never shows.
struct SettingSwitch: View {
    let label: SettingLabel
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack {
            label.opacity(disabled ? 0.5 : 1)
            Spacer()
            Toggle(label.title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
        }
    }
}
