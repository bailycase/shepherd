import SwiftUI

/// The Designs page's own measures (NavDesigns, DZStart), as the redesign's boards draw them: a
/// 28pt page inset, 16pt between cards, cards at radius 14 on the `lift` shadow.
public enum SHDesignsHomeMetrics {
    // The page
    /// The page's side inset, and the room above its first section and under its last.
    public static let inset: CGFloat = 28
    public static let top: CGFloat = 8
    public static let bottom: CGFloat = SH.Space.xxl
    /// A section's label row (24pt), the room over it (12pt; 28pt over the second) and under it (10pt).
    public static let sectionHeight: CGFloat = SH.Space.xxl
    public static let sectionTop: CGFloat = SH.Space.l
    public static let sectionGap: CGFloat = 28
    public static let sectionBottom: CGFloat = 10
    /// Between cards, across and down.
    public static let gap: CGFloat = SH.Space.xl
    public static let sectionLinkGap: CGFloat = 5
    /// The drop target's veil over the page: `bgWindow` at 70%.
    public static let dropVeil: Double = 0.7

    // The bar (`.tbar`): a filter pill and a capsule of text buttons
    public static let filterWidth: CGFloat = 220
    public static let filterHeight: CGFloat = SH.Height.controlL
    public static let filterPadding: CGFloat = SH.Space.l
    public static let filterGlyph: CGFloat = 12
    /// Between the filter and the capsule.
    public static let barGap: CGFloat = SH.Space.m
    /// A capsule button: 28pt, 10pt in, 6pt between its glyph and words, in 12.5.
    public static let barButtonPadding: CGFloat = 10
    public static let barButtonSize: CGFloat = 12.5
    public static let barDividerHeight: CGFloat = SH.Space.xl

    // A design card
    public static let thumbnailHeight: CGFloat = 156
    public static let desktopBoard = CGSize(width: 200, height: 125)
    public static let phoneBoard = CGSize(width: 60, height: 128)
    public static let boardRadius: CGFloat = 5
    public static let cardPaddingTop: CGFloat = 10
    public static let cardPaddingBottom: CGFloat = SH.Space.l
    public static let cardPaddingHorizontal: CGFloat = 14
    public static let cardMetaTop: CGFloat = 3
    public static let cardEditedTop: CGFloat = 1
    /// The card's •••: 26pt, 8pt from its trailing edge and 12pt over its bottom.
    public static let moreSize: CGFloat = 26
    public static let moreInsetTrailing: CGFloat = SH.Space.m
    public static let moreInsetBottom: CGFloat = SH.Space.l
    public static let moreGlyph: CGFloat = 14

    // A design system card
    public static let systemHeight: CGFloat = 62
    public static let systemPaddingLeading: CGFloat = 14
    public static let systemPaddingTrailing: CGFloat = SH.Space.l
    public static let systemSpacing: CGFloat = SH.Space.l
    public static let swatch: CGFloat = 14
    public static let swatchSpacing: CGFloat = SH.Space.xxs
    public static let systemTextSize: CGFloat = 12

    // New design's starting points (DZStart)
    public static let startPaddingTop: CGFloat = SH.Space.l
    public static let startPaddingBottom: CGFloat = 13
    public static let startPaddingHorizontal: CGFloat = 14
    public static let startSpacing: CGFloat = SH.Space.l
    public static let startGlyph: CGFloat = 14
    public static let startRing: CGFloat = 1.5
    public static let startChevron: CGFloat = 10
}

/// The Designs page's toolbar (the boards' `.tbar`): 44pt, no rule, the title in `headline` 28pt in,
/// the trailing controls at the right. While the sidebar is not docked, Show sidebar leads;
/// `leadingInset` clears the window controls. Its empty area drags the window.
public struct SHDesignsBar<Trailing: View>: View {
    let title: String
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarShortcut: String?
    let trailing: Trailing

    public init(_ title: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarShortcut = sidebarShortcut
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: SHDesignsHomeMetrics.barGap) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar", shortcut: sidebarShortcut)
                    .accessibilityLabel("Show sidebar")
                    .padding(.trailing, SH.Space.l)
            }
            Text(title)
                .font(.sh(.headline))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.l)
            trailing
        }
        .padding(.leading, (sidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding)
        .frame(height: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .shWindowDrag()
    }
}

extension SHDesignsBar where Trailing == EmptyView {
    public init(_ title: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil) {
        self.init(title, leadingInset: leadingInset, sidebar: sidebar, sidebarShortcut: sidebarShortcut) { EmptyView() }
    }
}

/// The bar's filter (the boards' `.pgf`): a 220×32 pill on `bgRaised` with the `lift` shadow and a
/// hairline, a magnifier, the words in 13, and a clear button once there is text.
public struct SHDesignsFilterField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    public var body: some View {
        let sh = Color.sh
        let shape = Capsule()
        HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.shSans(SHDesignsHomeMetrics.filterGlyph + 1, .medium))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.lantern)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.shSans(9, .semibold))
                        .foregroundStyle(sh.textTertiary)
                        .frame(width: SH.Space.xl, height: SH.Space.xl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, SHDesignsHomeMetrics.filterPadding)
        .frame(width: SHDesignsHomeMetrics.filterWidth, height: SHDesignsHomeMetrics.filterHeight)
        .shLift(shape)
        .shBorder(sh.lineSubtle, in: shape)
        .overlay {
            Color.clear
                .shFocusRing(focused, radius: SHDesignsHomeMetrics.filterHeight / 2)
                .shComponentAnimation(.hover, value: focused)
                .allowsHitTesting(false)
        }
    }
}

/// A text button in the bar's capsule (the boards' `.pgb2`): 28pt, 12.5 in `textPrimary`, a glyph
/// 6pt before its words, the hover fill under it.
public struct SHBarButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SHBarButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == SHBarButtonStyle {
    /// `.buttonStyle(.shBar)`.
    public static var shBar: SHBarButtonStyle { SHBarButtonStyle() }
}

private struct SHBarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        configuration.label
            .font(.shSans(SHDesignsHomeMetrics.barButtonSize))
            .labelStyle(SHBarLabelStyle())
            .foregroundStyle(sh.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, SHDesignsHomeMetrics.barButtonPadding)
            .frame(height: SH.Height.controlM)
            .background(configuration.isPressed && enabled ? sh.bgSelected : hovering && enabled ? sh.bgHover : .clear, in: shape)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: SH.Radius.s)
    }
}

private struct SHBarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.s) {
            configuration.icon.foregroundStyle(Color.sh.textSecondary)
            configuration.title
        }
    }
}

/// The 1×16 line between two buttons of the bar's capsule.
public struct SHBarDivider: View {
    public init() {}

    public var body: some View {
        SHHairline(.vertical)
            .frame(height: SHDesignsHomeMetrics.barDividerHeight)
            .padding(.horizontal, SH.Space.xxs)
            .accessibilityHidden(true)
    }
}

/// A section's label row (the boards' `.gdz-sh`): the title in `body` semibold, and what the page
/// puts at the right ("Build one from a repo").
public struct SHDesignsSection<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(title)
                .font(.sh(.body, weight: .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.m)
            trailing
        }
        .frame(height: SHDesignsHomeMetrics.sectionHeight)
    }
}

extension SHDesignsSection where Trailing == EmptyView {
    public init(_ title: String) { self.init(title) { EmptyView() } }
}

/// The section's link (the boards' `.lk`): a 12pt glyph 5pt before its words in 13 `textSecondary`.
/// A label: the page makes it a button or a menu.
public struct SHDesignsSectionLink: View {
    let title: String
    let symbol: String
    let enabled: Bool
    @State private var hovering = false

    public init(_ title: String, symbol: String = "plus", enabled: Bool = true) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
    }

    public var body: some View {
        HStack(spacing: SHDesignsHomeMetrics.sectionLinkGap) {
            Image(systemName: symbol)
                .font(.shSans(SHDesignsHomeMetrics.filterGlyph, .medium))
                .accessibilityHidden(true)
            Text(title).font(.sh(.ui)).lineLimit(1)
        }
        .foregroundStyle(hovering && enabled ? Color.sh.textPrimary : Color.sh.textSecondary)
        .contentShape(Rectangle())
        .shEnabledOpacity(enabled)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
    }
}
