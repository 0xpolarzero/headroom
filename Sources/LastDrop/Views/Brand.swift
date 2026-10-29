import AppKit
import SwiftUI

/// lastdrop's colors and mark. Water blues on a deep night ink: the accent is Water, lighter in dark mode so it reads
/// on dark surfaces.
enum Brand {
    static let ink = Color(hex: 0x0B1B2B)
    static let night = Color(hex: 0x17324D)
    static let water = Color(hex: 0x2B6FE6)
    static let shallow = Color(hex: 0x8FD0FF)
    static let mist = Color(hex: 0xF3F5F7)

    /// Controls, selection and meters.
    static let accent = Color(nsColor: NSColor(name: "lastdropAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x5A / 255, green: 0x9B / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x2B / 255, green: 0x6F / 255, blue: 0xE6 / 255, alpha: 1)
    })

    static let waterGradient = LinearGradient(colors: [shallow, water], startPoint: .top, endPoint: .bottom)
    static let nightGradient = LinearGradient(colors: [night, ink], startPoint: .top, endPoint: .bottom)
}

/// The drop, in a 100-point square: its tip at the top, round at the bottom.
struct DropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(50, 16))
        path.addCurve(to: p(26, 61), control1: p(50, 16), control2: p(26, 44))
        path.addCurve(to: p(50, 85), control1: p(26, 74.25), control2: p(36.75, 85))
        path.addCurve(to: p(74, 61), control1: p(63.25, 85), control2: p(74, 74.25))
        path.addCurve(to: p(50, 16), control1: p(74, 44), control2: p(50, 16))
        path.closeSubpath()
        return path
    }
}

/// The level line through the drop, in the same 100-point square.
struct LevelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(22, 59))
        path.addCurve(to: p(52, 58), control1: p(32, 52), control2: p(42, 64))
        path.addCurve(to: p(80, 56), control1: p(62, 52), control2: p(70, 62))
        return path
    }
}

/// The mark alone: the drop with its level line cut out, in one color (the menu bar's template image, the wordmark).
struct DropGlyph: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        ZStack {
            DropShape().fill(color)
            LevelShape().stroke(style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round)).blendMode(.destinationOut)
        }
        .compositingGroup()
        // The drop fills 16…85 of the square: scaled up a little so the glyph uses its box like other menu bar icons.
        .frame(width: size * 1.12, height: size * 1.12)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app icon: the drop in water blues, the level line in the night ink, on a night squircle.
struct AppIconView: View {
    var size: CGFloat = 1024

    var body: some View {
        let unit = size / 100
        ZStack {
            RoundedRectangle(cornerRadius: 22.5 * unit, style: .continuous).fill(Brand.nightGradient)
            RoundedRectangle(cornerRadius: 22.5 * unit, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: max(1, 0.5 * unit))
            // The level line cut through the drop, not past its edges.
            ZStack {
                DropShape().fill(Brand.waterGradient)
                LevelShape().stroke(style: StrokeStyle(lineWidth: 5 * unit, lineCap: .round)).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .frame(width: size, height: size)
    }
}

/// lastdrop's mark as setup shows it.
struct AppMark: View {
    var size: CGFloat = 56

    var body: some View {
        AppIconView(size: size)
            .shadow(color: Brand.water.opacity(0.25), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

@MainActor
enum BrandImages {
    /// The menu bar's icon when no account shows numbers: the drop, as a template image.
    static func menuBarGlyph() -> NSImage {
        let renderer = ImageRenderer(content: DropGlyph(size: 16, color: .black).padding(.vertical, 3))
        renderer.scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "lastdrop"
        return image
    }

    /// `lastdrop --app-icon <folder.iconset>`: the icon at every size `iconutil` takes, for the build script.
    static func writeIconSet(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                // Apple's icon grid: the shape takes 824 of 1024, centered, with room for its shadow.
                let renderer = ImageRenderer(content: AppIconView(size: CGFloat(points) * 824 / 1024)
                    .shadow(color: .black.opacity(0.3), radius: CGFloat(points) * 0.012, y: CGFloat(points) * 0.01)
                    .frame(width: CGFloat(points), height: CGFloat(points)))
                renderer.scale = CGFloat(scale)
                guard let image = renderer.cgImage else { continue }
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
            }
        }
    }
}
