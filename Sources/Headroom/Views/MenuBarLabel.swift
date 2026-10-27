import AppKit
import SwiftUI

/// One provider in the menu bar: its logo plus what is left of the Session, the Weekly, or both stacked.
/// Providers without those windows (OpenRouter) show their own text, such as the credit balance.
struct MenuBarLabel: View {
    let id: ProviderID
    let snapshot: UsageSnapshot?
    let mode: MenuBarMode

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Logos.image(id))
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)

            if let text = snapshot?.menuBarText {
                Text(text).font(.system(size: 13, weight: .medium))
            } else {
                switch mode {
                case .session, .weekly:
                    Text(left(mode == .session ? "Session" : "Weekly"))
                        .font(.system(size: 13, weight: .medium))
                case .both:
                    VStack(alignment: .trailing, spacing: -1) {
                        Text(left("Session"))
                        Text(left("Weekly"))
                    }
                    .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.black)
        .frame(height: 22)
    }

    private func left(_ label: String) -> String { Self.left(label, in: snapshot) }

    static func left(_ label: String, in snapshot: UsageSnapshot?) -> String {
        guard let left = snapshot?.windows.first(where: { $0.label == label })?.remainingPercent else { return "–" }
        return "\(Int(left.rounded()))%"
    }

    /// Status item buttons take an image, and stacking needs two lines, so draw labels as a template.
    @MainActor static func template(_ view: some View) -> NSImage {
        let renderer = ImageRenderer(content: view)
        // Draw for the sharpest screen, not `NSScreen.main`: with a 1x external display active,
        // a 1x image would look pixelated on the Retina menu bar.
        renderer.scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// Claude with several accounts: each account's name and what is left, in the order set in Settings.
struct ClaudeMenuBarLabel: View {
    let rows: [ClaudeAccountRow]
    let mode: MenuBarMode

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: Logos.image(.claude))
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
            ForEach(rows) { row in
                HStack(spacing: 3) {
                    tag(row.name)
                    numbers(row.snapshot).fixedSize()
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.black)
        .frame(height: 22)
    }

    private func tag(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1))
            .fixedSize()
    }

    @ViewBuilder private func numbers(_ snapshot: UsageSnapshot?) -> some View {
        switch mode {
        case .session, .weekly:
            Text(MenuBarLabel.left(mode == .session ? "Session" : "Weekly", in: snapshot))
                .font(.system(size: 13, weight: .medium))
        case .both:
            VStack(alignment: .trailing, spacing: -1) {
                Text(MenuBarLabel.left("Session", in: snapshot))
                Text(MenuBarLabel.left("Weekly", in: snapshot))
            }
            .font(.system(size: 9, weight: .semibold))
        }
    }
}
