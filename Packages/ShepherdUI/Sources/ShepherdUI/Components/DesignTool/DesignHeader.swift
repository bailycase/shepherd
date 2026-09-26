import SwiftUI

/// A pill after a design header's title: a system's sync state ("Synced", done).
public struct NWDesignHeaderStatus: Equatable, Sendable {
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
public struct NWDesignHeader<Trailing: View>: View {
    public enum Style: Sendable {
        /// A destination page's header (52pt).
        case page
        /// The toolbar over a design (44pt).
        case toolbar
    }

    public typealias Status = NWDesignHeaderStatus

    let title: String
    let style: Style
    let section: String
    let status: Status?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarShortcut: String?
    let designs: () -> Void
    let trailing: Trailing

    public init(_ title: String, style: Style, section: String = "Designs", status: Status? = nil, leadingInset: CGFloat = 0,
                sidebar: (() -> Void)? = nil, sidebarShortcut: String? = nil, designs: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing) {
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
        HStack(spacing: NW.Space.l) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.nwIcon)
                    .nwHelp("Show sidebar", shortcut: sidebarShortcut)
                    .accessibilityLabel("Show sidebar")
            }
            HStack(spacing: NW.Space.m) {
                Image(systemName: "pencil.tip")
                    .font(.nwSans(NWDesignMetrics.headerGlyph))
                    .foregroundStyle(Color.nw.textTertiary)
                    .accessibilityHidden(true)
                Button(action: designs) {
                    Text(section).foregroundStyle(Color.nw.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section)
                Text("/")
                    .foregroundStyle(Color.nw.textTertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.nwSans(NWDesignMetrics.headerTextSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                    .nwContentTransition(.crossFade)
                    .nwAnimation(.content, value: title)
                if let status {
                    NWStatusPill(status.state, label: status.label)
                        .nwTransition(.content)
                }
            }
            .font(.nwSans(NWDesignMetrics.headerTextSize))
            .nwAnimation(.content, value: status)
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.m) { trailing }
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.leading, (style == .page ? NWPageMetrics.headerLeading : NWToolbarMetrics.leadingPadding) + leadingInset)
        .padding(.trailing, style == .page ? NWPageMetrics.headerTrailing : NW.Space.l)
        .frame(height: style == .page ? NWPageMetrics.headerHeight : NWToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .contentShape(Rectangle())
        .nwWindowDrag()
    }
}

extension NWDesignHeader where Trailing == EmptyView {
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
public struct NWDesignPaneTabs: View {
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
        HStack(spacing: NWDesignMetrics.paneTabSpacing) {
            ForEach(tabs) { tab in
                let current = tab.id == selection
                Button { select(tab.id) } label: {
                    HStack(spacing: NW.Space.xs) {
                        if touch {
                            Text(tab.count.map { "\(tab.title) \($0)" } ?? tab.title)
                                .font(.nwSans(NWDesignMetrics.touchPaneTabTextSize, current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.nw.textPrimary : Color.nw.textSecondary)
                        } else {
                            Text(tab.title)
                                .font(.nwSans(NWDesignMetrics.paneTabTextSize, current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.nw.textPrimary : Color.nw.textSecondary)
                            if let count = tab.count {
                                Text("\(count)")
                                    .font(.nwMono(NWDesignMetrics.paneTabCountSize))
                                    .foregroundStyle(Color.nw.textTertiary)
                            }
                        }
                    }
                    .frame(height: touch ? NWDesignMetrics.touchPaneTabHeight : nil)
                    .frame(maxHeight: touch ? nil : .infinity)
                    .overlay(alignment: .bottom) {
                        if current {
                            Rectangle().fill(Color.nw.textPrimary).frame(height: NWDesignMetrics.paneTabUnderline)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, touch ? NWDesignMetrics.touchPaneTabsLeading : NWDesignMetrics.paneTabsLeading)
        .padding(.trailing, touch ? NWDesignMetrics.touchPaneTabsLeading : NW.Space.l)
        .frame(height: touch ? nil : NWDesignMetrics.paneTabsHeight, alignment: .bottom)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}
