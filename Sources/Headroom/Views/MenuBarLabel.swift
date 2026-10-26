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

    private func left(_ label: String) -> String {
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
