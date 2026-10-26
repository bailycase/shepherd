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

extension SHDesignHeader where Trailing == EmptyView {
    public init(_ title: String, style: Style, section: String = "Designs", status: Status? = nil, leadingInset: CGFloat = 0,
                sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil, designs: @escaping () -> Void) {
        self.init(title, style: style, section: section, status: status, leadingInset: leadingInset, sidebar: sidebar,
                  sidebarShortcut: sidebarShortcut, designs: designs) { EmptyView() }
    }
}

/// The design's chat pane tabs (DZCanvas): a 40pt row (18pt leading, 12pt trailing padding) with
/// a hairline under it; tabs 18pt apart in 12.5, the current one `textPrimary` semibold over a
/// 2pt `textPrimary` underline, the others `textSecondary`, a count in mono 10 `textTertiary`.
/// On iPad (`.touch`, iPadDesign) the tabs are 44pt tall in 14, 16pt in, their counts in the
/// tab's own type ("Comments 3").
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
        let touch = size == .touch
        HStack(spacing: touch ? 0 : SHDesignMetrics.paneTabSpacing) {
            ForEach(tabs) { tab in
                let current = tab.id == selection
                Button { select(tab.id) } label: {
                    HStack(spacing: SH.Space.xs) {
                        if touch {
                            Text(tab.count.map { "\(tab.title) \($0)" } ?? tab.title)
                                .font(.shSans(SHDesignMetrics.touchPaneTabTextSize, .regular))
                                .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                        } else {
                            Text(tab.title)
                                .font(.shSans(SHDesignMetrics.paneTabTextSize, current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.sh.textPrimary : Color.sh.textSecondary)
                            if let count = tab.count {
                                Text("\(count)")
                                    .font(.shMono(SHDesignMetrics.paneTabCountSize))
                                    .foregroundStyle(Color.sh.textTertiary)
                            }
                        }
                    }
                    // iPadDesign: the touch tabs share the pane's width under a lantern line.
                    .frame(maxWidth: touch ? .infinity : nil)
                    .frame(height: touch ? SHDesignMetrics.touchPaneTabHeight : nil)
                    .frame(maxHeight: touch ? nil : .infinity)
                    .overlay(alignment: .bottom) {
                        if current {
                            Rectangle().fill(touch ? Color.sh.lantern : Color.sh.textPrimary).frame(height: SHDesignMetrics.paneTabUnderline)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            if !touch { Spacer(minLength: 0) }
        }
        .padding(.leading, touch ? 0 : SHDesignMetrics.paneTabsLeading)
        .padding(.trailing, touch ? 0 : SH.Space.l)
        .frame(height: touch ? nil : SHDesignMetrics.paneTabsHeight, alignment: .bottom)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}
