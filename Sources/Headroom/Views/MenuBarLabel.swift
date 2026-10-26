import AppKit
import SwiftUI

/// One provider's menu bar item: its logo plus the Session %, the Weekly %, or both stacked.
struct MenuBarLabel: View {
    let id: ProviderID
    let snapshot: UsageSnapshot?
    let mode: MenuBarMode

    var body: some View {
        Image(nsImage: Self.render(content))
    }

    private func percent(_ label: String) -> String {
        guard let used = snapshot?.windows.first(where: { $0.label == label })?.usedPercent else { return "–" }
        return "\(Int(used.rounded()))%"
    }

    private var content: some View {
        HStack(spacing: 4) {
            Image(nsImage: Logos.image(id))
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
            switch mode {
            case .session, .weekly:
                Text(percent(mode == .session ? "Session" : "Weekly"))
                    .font(.system(size: 13, weight: .medium))
            case .both:
                VStack(alignment: .trailing, spacing: -1) {
                    Text(percent("Session"))
                    Text(percent("Weekly"))
                }
                .font(.system(size: 9, weight: .semibold))
            }
        }
        .monospacedDigit()
        .foregroundStyle(.black)
        .frame(height: 22)
    }

    /// MenuBarExtra labels only lay out one line, so draw the label into a template image.
    @MainActor private static func render(_ view: some View) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
