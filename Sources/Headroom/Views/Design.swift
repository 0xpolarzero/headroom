import AppKit
import SwiftUI

// Headroom's window design, shared by Settings and first-launch setup.
//
// Glass is for navigation and controls only (the sidebar, setup's bottom bar), and only where content moves under it;
// content is opaque. Sections are a title and rows sitting on the page, split by hairlines; the one boxed container is the
// nest, for a list's items. Controls are the system's, which take on Liquid Glass on macOS 26 by themselves.

enum Design {
    /// The widest a page's column gets; past that it centers.
    static let column: CGFloat = 600
    /// Setup's column.
    static let setupColumn: CGFloat = 540
    static let pageInset: CGFloat = 32
    static let sectionGap: CGFloat = 28
    static let headerGap: CGFloat = 8
    static let rowPad: CGFloat = 9
    static let nestRadius: CGFloat = 12
    /// The sidebar's distance from the window's edges, and its width.
    static let sidebarInset: CGFloat = 8
    static let sidebarWidth: CGFloat = 196
    /// Where the sidebar's rows start: below the window's buttons.
    static let titleBar: CGFloat = 52
    /// A page's title bar, its title level with the window's buttons.
    static let pageBar: CGFloat = 52
    static let hairline = Color.primary.opacity(0.08)
    static let ring = Color.primary.opacity(0.1)

    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let pageTitle = Font.system(size: 15, weight: .semibold)

    /// The scroll edge bars; renders (`HEADROOM_GLASS=0`) can't draw a scroll view under them.
    static var liveBars: Bool { ProcessInfo.processInfo.environment["HEADROOM_GLASS"] != "0" }

    /// Liquid Glass: macOS 26, unless Reduce Transparency is on (or `HEADROOM_GLASS=0`, which renders use).
    static var glass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && ProcessInfo.processInfo.environment["HEADROOM_GLASS"] != "0"
    }
}

/// A surface on glass, or without it the sidebar's own fill with a hairline: the same view either way.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *), Design.glass {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(Color.primary.opacity(0.035)))
                .overlay(shape.strokeBorder(Design.ring, lineWidth: 1))
        }
    }
}

extension View {
    func glassSurface(_ shape: some InsettableShape) -> some View { modifier(GlassSurface(shape: shape)) }
}

/// A page: its title on a bar the content scrolls under, then its sections in a centered column.
struct Page<Content: View, Action: View>: View {
    let title: String
    var info: String?
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionGap) { content() }
                .frame(maxWidth: Design.column, alignment: .leading)
                .padding(.horizontal, Design.pageInset)
                .padding(.top, 4)
                .padding(.bottom, Design.pageInset)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .topBar {
            HStack(spacing: 6) {
                Text(title).font(Design.pageTitle)
                if let info { InfoTip(info) }
                Spacer()
                action()
            }
            .frame(maxWidth: Design.column)
            .padding(.horizontal, Design.pageInset)
            .frame(height: Design.pageBar)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Page where Action == EmptyView {
    init(title: String, info: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, info: info, action: { EmptyView() }, content: content)
    }
}

extension View {
    /// A bar the content scrolls under: on macOS 26 with the system's soft edge, before it on the window's color.
    @ViewBuilder func topBar(@ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *), Design.liveBars {
            safeAreaBar(edge: .top) { bar() }.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar().background(Color(nsColor: .windowBackgroundColor)) }
        }
    }

    @ViewBuilder func bottomBar(@ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *), Design.liveBars {
            safeAreaBar(edge: .bottom) { bar() }.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                bar().background(Color(nsColor: .windowBackgroundColor)).overlay(alignment: .top) { Divider() }
            }
        }
    }
}

/// A section: its title (with an ⓘ and an action at the end), then its rows straight on the page.
struct PageSection<Content: View, Action: View>: View {
    var title: String?
    var info: String?
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || Action.self != EmptyView.self {
                HStack(spacing: 6) {
                    if let title { Text(title).font(Design.sectionTitle) }
                    if let info { InfoTip(info) }
                    Spacer()
                    action().controlSize(.small)
                }
                .frame(minHeight: 22)
                .padding(.bottom, Design.headerGap)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageSection where Action == EmptyView {
    init(_ title: String? = nil, info: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, info: info, action: { EmptyView() }, content: content)
    }
}

extension PageSection {
    init(_ title: String?, info: String? = nil, @ViewBuilder action: @escaping () -> Action, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, info: info, action: action, content: content)
    }
}

/// The hairline between a section's rows.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Design.hairline).frame(height: 1).accessibilityHidden(true) }
}

/// A setting: an icon in a fixed column, its title (and ⓘ), a line under it, and its control at the end.
struct Row<Leading: View, Control: View>: View {
    var title: String
    var info: String?
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                    if let info { InfoTip(info) }
                }
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(detailColor).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, Design.rowPad)
    }
}

extension Row where Leading == RowIcon {
    init(icon: String, color: Color = .secondary, title: String, info: String? = nil, detail: String? = nil,
         detailColor: Color = .secondary, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, info: info, detail: detail, detailColor: detailColor, leading: { RowIcon(name: icon, color: color) },
                  control: control)
    }
}

struct RowIcon: View {
    let name: String
    var color: Color = .secondary

    var body: some View {
        Image(systemName: name).font(.system(size: 14)).foregroundStyle(color).frame(width: 22)
    }
}

/// A row's switch: the system's, small, labelled for accessibility by the row.
struct RowSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

/// A list's items, straight on the page: no box, so they get the column's whole width.
struct Nest<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small grey label inside a nest, over the rows it names.
struct NestLabel: View {
    let text: String
    var info: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let info { InfoTip(info) }
        }
        .padding(.top, 10)
    }
}

/// The window's three buttons, centered on the 52pt title line (as on macOS 26's sidebar windows) instead of AppKit's
/// 28pt one, so they sit inside the inset sidebar with room around them. Placed again after a resize or full screen.
@MainActor
enum TrafficLights {
    static let spacing: CGFloat = 20

    static func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height = Design.titleBar
        container.frame = NSRect(x: container.frame.minX, y: window.frame.height - height, width: container.frame.width, height: height)
        let inset = ((height - close.frame.height) / 2).rounded()
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            window.standardWindowButton(kind)?.setFrameOrigin(NSPoint(x: inset + CGFloat(i) * spacing, y: inset))
        }
    }
}

/// Headroom's mark: a gauge on a blue squircle.
struct AppMark: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x3E8BFF), Color(hex: 0x5A4BF5)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .overlay(Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: Color(hex: 0x3E5BFF).opacity(0.3), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}
