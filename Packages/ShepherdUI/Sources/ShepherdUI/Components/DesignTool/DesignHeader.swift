import SwiftUI

/// A pill after a design header's title: a system's sync state ("Synced", done).
public struct SHDesignHeaderStatus: Equatable, Sendable {
    public let state: AgentState
    public let label: String

    public init(_ state: AgentState, label: String) {
        self.state = state
        self.label = label
    }
}

/// The Design tool's header (DZStart, DZCanvas, DZSystem): a sidebar button while the sidebar is
/// not docked, the breadcrumb (the nib in 14pt `textTertiary`, the section, "Designs" or "Design
/// systems", in 13 `textTertiary`, "/", then the page in 13 semibold, and a status pill after it
/// on a system's page), a spacer and the trailing controls, 8pt apart. As a page (New design) it
/// takes the page header's height and inset; over a design, the toolbar's. The section goes back
/// to the Designs page. Its empty area drags the window.
public struct SHDesignHeader<Trailing: View>: View {
    public enum Style: Sendable {
        /// A destination page's header (52pt).
        case page
        /// The toolbar over a design (44pt).
        case toolbar
    }

    public typealias Status = SHDesignHeaderStatus

    let title: String
    let style: Style
    let section: String
    let status: Status?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarShortcut: String?
    let designs: () -> Void
    /// Centered between the breadcrumb and the trailing controls (JumpInContext's field).
    let center: AnyView?
    let trailing: Trailing
    /// The trailing capsule's width on the Mac, which the centered Jump field keeps clear of.
    @State private var capsuleWidth: CGFloat = 0

    public init(_ title: String, style: Style, section: String = "Designs", status: Status? = nil, leadingInset: CGFloat = 0,
                sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil, designs: @escaping () -> Void,
                center: AnyView? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.center = center
        self.title = title
        self.style = style
        self.section = section
        self.status = status
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarShortcut = sidebarShortcut
        self.designs = designs
        self.trailing = trailing()
    }

    public var body: some View {
        #if os(macOS)
        if style == .toolbar { toolbar } else { page }
        #else
        page
        #endif
    }

    private var page: some View {
        HStack(spacing: SH.Space.l) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar", shortcut: sidebarShortcut)
                    .accessibilityLabel("Show sidebar")
            }
            HStack(spacing: SH.Space.m) {
                Image(systemName: "pencil.tip")
                    .font(.shSans(SHDesignMetrics.headerGlyph))
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
                Button(action: designs) {
                    Text(section).foregroundStyle(Color.sh.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section)
                Text("/")
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.shSans(SHDesignMetrics.headerTextSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                    .shContentTransition(.crossFade)
                    .shAnimation(.content, value: title)
                if let status {
                    SHStatusPill(status.state, label: status.label)
                        .shTransition(.content)
                }
            }
            .font(.shSans(SHDesignMetrics.headerTextSize))
            .shAnimation(.content, value: status)
            Spacer(minLength: SH.Space.l)
            // The board's field sits between two equal spacers; it narrows (to 80pt) before
            // the breadcrumb or the trailing controls give way.
            if let center {
                center.layoutPriority(0.5)
                Spacer(minLength: SH.Space.l)
            }
            HStack(spacing: SH.Space.m) { trailing }
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.leading, (style == .page ? SHPageMetrics.headerLeading : SHToolbarMetrics.leadingPadding) + leadingInset)
        .padding(.trailing, style == .page ? SHPageMetrics.headerTrailing : SH.Space.l)
        .frame(height: style == .page ? SHPageMetrics.headerHeight : SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
        .contentShape(Rectangle())
        .shWindowDrag()
    }
}

#if os(macOS)
extension SHDesignHeader {
    /// The toolbar over a design (DZCanvas), as the thread's toolbar is drawn: no rule under it, the
    /// breadcrumb ("Designs / name", 13) leading, the Jump field at its middle, and the trailing
    /// controls in one raised capsule.
    fileprivate var toolbar: some View {
        let M = SHDesignChrome.self
        return HStack(spacing: SH.Space.m) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar", shortcut: sidebarShortcut)
                    .accessibilityLabel("Show sidebar")
                    .padding(.trailing, SH.Space.l)
            }
            HStack(spacing: SH.Space.m) {
                Button(action: designs) { Text(section).foregroundStyle(Color.sh.textTertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section)
                Text("/")
                    .foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                    .shContentTransition(.crossFade)
                    .shAnimation(.content, value: title)
                if let status {
                    // A word, not a pill (DZSystem): "Synced", or the working word shimmering.
                    Text(status.label)
                        .foregroundStyle(Color.sh.textTertiary)
                        .shShimmer(active: status.state == .running)
                        .shTransition(.content)
                }
            }
            .font(.shSans(M.toolbarTextSize))
            .shAnimation(.content, value: status)
            Spacer(minLength: SH.Space.l)
            if Trailing.self != EmptyView.self {
                SHToolbarCapsule { trailing }
                    .layoutPriority(1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { capsuleWidth = $0 }
            }
        }
        .padding(.leading, (sidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + leadingInset)
        // Over the whole column, the card beside the canvas starts under the capsule, which keeps the window's 8pt and the board's 4.
        .padding(.trailing, SHToolbarMetrics.trailingPadding + SHDesignChrome.stageInset)
        .frame(height: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        // The field is centered on the toolbar, not on what the breadcrumb leaves: it narrows (to 80pt)
        // before it would cover either end.
        .overlay {
            if let center {
                center.padding(.horizontal, max(M.jumpClearance, capsuleWidth + SH.Space.xxl))
            }
        }
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .shWindowDrag()
    }
}

/// A text button in the toolbar's capsule (DZCanvas' `.gdz-chip`): an optional 14pt glyph in
/// `textTertiary` before the words in 13, 28pt tall with the hover fill on its round ends.
public struct SHDesignToolbarChip: View {
    let title: String
    let symbol: String?
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, symbol: String? = nil, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        let M = SHDesignChrome.self
        Button(action: action) {
            SHDesignToolbarChipLabel(hovering: hovering || isOn) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.shSans(M.chipGlyph))
                        .foregroundStyle(Color.sh.textTertiary)
                }
                Text(title).font(.shSans(M.toolbarTextSize)).lineLimit(1)
            }
            .opacity(enabled ? 1 : SHControlMetrics.disabledOpacity)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel(title)
    }
}

/// The design's system in the toolbar's capsule: up to three of its colors as 9pt squares, then its
/// name in 13. It opens the system's page; without an action it is a label.
public struct SHDesignToolbarSystem: View {
    let name: String
    let colors: [Color]
    let action: (() -> Void)?
    @State private var hovering = false

    public init(_ name: String, colors: [Color] = [], action: (() -> Void)? = nil) {
        self.name = name
        self.colors = colors
        self.action = action
    }

    public var body: some View {
        let M = SHDesignChrome.self
        Button { action?() } label: {
            SHDesignToolbarChipLabel(hovering: hovering && action != nil) {
                if !colors.isEmpty {
                    HStack(spacing: M.chipSwatchGap) {
                        ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: M.chipSwatchRadius)
                                .fill(color)
                                .frame(width: M.chipSwatch, height: M.chipSwatch)
                                .overlay { RoundedRectangle(cornerRadius: M.chipSwatchRadius).strokeBorder(Color.sh.lineSubtle, lineWidth: 1) }
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(name).font(.shSans(M.toolbarTextSize)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .help(action == nil ? name : "Open \(name)")
        .accessibilityLabel("Design system \(name)")
    }
}

/// A chip's face: its parts 6pt apart in a 28pt row on the capsule's round ends.
private struct SHDesignToolbarChipLabel<Content: View>: View {
    let hovering: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: SHDesignChrome.chipGap) { content }
            .foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SHDesignChrome.chipPadding)
            .frame(height: SHDesignChrome.chipHeight)
            .background(hovering ? Color.sh.bgHover : .clear, in: Capsule())
            .contentShape(Capsule())
    }
}

/// The 1px rule between the capsule's groups (`.vs`).
public struct SHDesignCapsuleDivider: View {
    public init() {}

    public var body: some View {
        SHHairline(.vertical)
            .frame(height: SHDesignChrome.dividerHeight)
            .padding(.horizontal, SHDesignChrome.dividerMargin)
            .accessibilityHidden(true)
    }
}
#endif

extension SHDesignHeader where Trailing == EmptyView {
    public init(_ title: String, style: Style, section: String = "Designs", status: Status? = nil, leadingInset: CGFloat = 0,
                sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil, designs: @escaping () -> Void) {
        self.init(title, style: style, section: section, status: status, leadingInset: leadingInset, sidebar: sidebar,
                  sidebarShortcut: sidebarShortcut, designs: designs) { EmptyView() }
    }
}

/// The design's chat pane tabs (DZCanvas). On the Mac they are the side pane's strip: 44pt over a
/// hairline, 28pt tab pills 2pt apart in 13 (the current one on `bgSelected`, medium, in
/// `textPrimary`; the others `textSecondary`), a count in 12 `textTertiary`; the pane's ⋯ menu
/// (`SHOptionsMenu`) is laid over its trailing end by the caller. On iPad (`.touch`, iPadDesign) the tabs are 44pt tall in 14, 16pt in,
/// their counts in the tab's own type ("Comments 3").
public struct SHDesignPaneTabs: View {
    public enum Size: Sendable {
        case regular, touch
    }

    public struct Tab: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let count: Int?

        public init(id: String, title: String, count: Int? = nil) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    let tabs: [Tab]
    let selection: String
    let size: Size
    let select: (String) -> Void

    public init(_ tabs: [Tab], selection: String, size: Size = .regular, select: @escaping (String) -> Void = { _ in }) {
        self.tabs = tabs
        self.selection = selection
        self.size = size
        self.select = select
    }

    public var body: some View {
        if size == .touch { segmented } else { regular }
    }

    /// iPadDesign: the tabs as a segmented capsule on `bgSelected`, 36pt tall with 3pt around its
    /// tabs, the current one a `bgRaised` capsule on the lift in `textPrimary`, the rest
    /// `textSecondary`, all in 13 medium, a count in regular `textTertiary` ("Comments 2").
    private var segmented: some View {
        HStack(spacing: SH.Space.xxs) {
            ForEach(tabs) { tab in
                let current = tab.id == selection
                Button { select(tab.id) } label: {
                    HStack(spacing: SH.Space.xs + 1) {
                        Text(tab.title).font(.shSans(SHDesignMetrics.touchPaneTabTextSize, .medium))
                        if let count = tab.count {
                            Text("\(count)").font(.shSans(SHDesignMetrics.touchPaneTabTextSize)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if current { Capsule().fill(Color.sh.bgRaised).shadow(color: .sh.liftFar, radius: SH.Space.xs, y: SH.Space.xxs) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(SH.Space.xxs + 1)
        .frame(height: SHDesignMetrics.touchPaneTabHeight)
        .background(Color.sh.bgSelected, in: Capsule())
        .padding(SH.Space.l)
    }

    @ViewBuilder private var regular: some View {
        #if os(macOS)
        pills
        #else
        underlined
        #endif
    }

    #if os(macOS)
    private var pills: some View {
        let M = SHDesignChrome.self
        return HStack(spacing: SH.Space.xxs) {
            ForEach(tabs) { tab in
                SHDesignPaneTab(tab: tab, isSelected: tab.id == selection) { select(tab.id) }
            }
            Spacer(minLength: SH.Space.m)
        }
        .padding(.leading, M.paneTabLeading)
        .padding(.trailing, M.paneTabTrailing)
        .frame(height: M.paneTabsHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Design chat tabs")
    }
    #endif

    private var underlined: some View {
        HStack(spacing: SHDesignMetrics.paneTabSpacing) {
            ForEach(tabs) { tab in
                let current = tab.id == selection
                Button { select(tab.id) } label: {
                    HStack(spacing: SH.Space.xs) {
                        Text(tab.title)
                            .font(.shSans(SHDesignMetrics.paneTabTextSize, current ? .semibold : .regular))
                            .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                        if let count = tab.count {
                            Text("\(count)")
                                .font(.shMono(SHDesignMetrics.paneTabCountSize))
                                .foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if current {
                            Rectangle().fill(Color.sh.textPrimary).frame(height: SHDesignMetrics.paneTabUnderline)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SHDesignMetrics.paneTabsLeading)
        .padding(.trailing, SH.Space.l)
        .frame(height: SHDesignMetrics.paneTabsHeight, alignment: .bottom)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

#if os(macOS)
/// One pill of the chat pane's strip: the title, a count after it, the hover and selected fills.
private struct SHDesignPaneTab: View {
    let tab: SHDesignPaneTabs.Tab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let M = SHDesignChrome.self
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SH.Space.s) {
                Text(tab.title).font(.shSans(M.paneTabTextSize, isSelected ? .medium : .regular))
                if let count = tab.count {
                    Text("\(count)")
                        .font(.shSans(M.paneCountSize))
                        .foregroundStyle(sh.textTertiary)
                        .shContentTransition(.numeric())
                }
            }
            .foregroundStyle(isSelected || hovering ? sh.textPrimary : sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, M.paneTabPadding)
            .frame(height: M.paneTabHeight)
            .background(isSelected ? sh.bgSelected : hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
