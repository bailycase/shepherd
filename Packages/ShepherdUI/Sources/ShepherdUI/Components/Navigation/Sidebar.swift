import SwiftUI

/// The sidebar column (SHNavigation, `SHSidebar`): the 44pt top bar (room for the window
/// controls, then Search and Hide sidebar at its trailing end; it drags the window), the
/// destinations and lists, and the footer behind a 1px rule. On `bgBase`; the caller draws the
/// trailing edge.
public struct SHSidebar<Content: View, Footer: View>: View {
    let topBar: SHSidebarTopBar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    public init(topBar: SHSidebarTopBar, @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder footer: @escaping () -> Footer) {
        self.topBar = topBar
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            content()
                .frame(maxHeight: .infinity, alignment: .top)
            footer()
        }
        .background(Color.sh.bgBase)
    }
}

extension SHSidebar where Footer == EmptyView {
    public init(topBar: SHSidebarTopBar, @ViewBuilder content: @escaping () -> Content) {
        self.init(topBar: topBar, content: content, footer: { EmptyView() })
    }
}

/// The sidebar's fixed measures (SHNavigation). Row heights follow `SHDensity`.
public enum SHSidebarMetrics {
    /// The top bar: room for the window controls, unified with the title bar (the toolbar
    /// beside it is as tall).
    public static let topBarHeight: CGFloat = 44
    /// The top bar's Search and Hide sidebar buttons: 26pt circles 4pt apart, 8pt from the edge.
    public static let topBarButton: CGFloat = 26
    public static let topBarButtonGap: CGFloat = 4
    public static let topBarTrailing: CGFloat = 8
    /// The destinations and lists sit 8pt in from the column's sides, rows 1pt apart.
    public static let listInset: CGFloat = 8
    public static let rowSpacing: CGFloat = 1
    /// The destinations' stack is padded 2pt above and below.
    public static let destinationsPadding: CGFloat = 2
    /// A destination is 2pt taller than a list row at the same density (30 against 28, 24
    /// against 22).
    public static let destinationExtra: CGFloat = 2
    /// A destination's icon slot, and the New thread circle in it.
    public static let destinationIconSlot: CGFloat = 20
    /// More's rows (Hosts, Extensions) lead 22pt in instead of 8.
    public static let destinationChildLeading: CGFloat = 22
    /// A list row's leading slot (a dot or a kind's glyph).
    public static let rowSlot: CGFloat = 14
    /// The footer's avatar and Settings button.
    public static let footerAvatar: CGFloat = 26
    /// The footer's rule is 6pt below its top edge (ProjectLead boards: 848 to 854), then 9pt to the avatar and 10pt beneath it.
    public static let footerAboveRule: CGFloat = 6
    public static let footerRuleToContent: CGFloat = 9
    public static let footerBottom: CGFloat = 10
    /// The trailing reason a Needs you row shows ("retention?") is cut to this many characters.
    public static let reasonLength = 14
}

/// The measures that change with the row density: Standard is the boards' value, Compact the
/// Compact sample's; Comfortable takes Standard's spacing at its own height.
extension SHDensity {
    /// A row's side padding and the gap after its leading slot.
    public var sidebarRowPadding: CGFloat { self == .compact ? SH.Space.s : SH.Space.m }
    public var sidebarRowGap: CGFloat { self == .compact ? 7 : 9 }
    /// A section header's top padding.
    public var sidebarHeaderTop: CGFloat { self == .compact ? 10 : 14 }
    /// A destination's title and icon.
    @MainActor public var destinationFont: Font { self == .compact ? .shSans(12) : .shSans(13) }
    @MainActor public func destinationFont(weight: Font.Weight) -> Font {
        self == .compact ? .shSans(12, weight) : .shSans(13, weight)
    }
    public var destinationIcon: CGFloat { self == .compact ? 13 : 15 }
    /// A list row's glyph (an automation's bolt).
    public var rowGlyph: CGFloat { self == .compact ? 11 : 13 }
    /// A destination's height at the current density scale.
    @MainActor public var destinationHeight: CGFloat { rowHeight + SHSidebarMetrics.destinationExtra }
}

// MARK: Top bar

/// The 44pt top bar: the window controls' room, a spacer that drags the window, then Search
/// (⌘K) and Hide sidebar (⇧⌘S) as 26pt circular icon buttons with 14pt glyphs.
public struct SHSidebarTopBar: View {
    let searchShortcut: String?
    let hideShortcut: String?
    let search: (() -> Void)?
    let hide: (() -> Void)?

    public init(searchShortcut: String? = nil, hideShortcut: String? = nil, search: (() -> Void)?, hide: (() -> Void)?) {
        self.searchShortcut = searchShortcut
        self.hideShortcut = hideShortcut
        self.search = search
        self.hide = hide
    }

    public var body: some View {
        HStack(spacing: SHSidebarMetrics.topBarButtonGap) {
            Color.clear
                .contentShape(Rectangle())
                .shWindowDrag()
            if let search {
                button("magnifyingglass", label: "Search", shortcut: searchShortcut, action: search)
            }
            if let hide {
                button("sidebar.left", label: "Hide sidebar", shortcut: hideShortcut, action: hide)
            }
        }
        .padding(.trailing, SHSidebarMetrics.topBarTrailing)
        .frame(height: SHSidebarMetrics.topBarHeight)
    }

    private func button(_ symbol: String, label: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.shIcon(size: SHSidebarMetrics.topBarButton))
            .shHelp(label, shortcut: shortcut)
            .accessibilityLabel(label)
    }
}

// MARK: Destinations

/// A destination (SHNavigation, `SHSidebarDestination`): New thread with its chord, Automations,
/// More and More's rows. 30pt (24 in Compact), radius 8, a 20pt icon slot, the title in Geist 13
/// (12). The selected one is `bgSelected` with its title in semibold and its icon in
/// `textPrimary`; hover is `bgHover`. A button; compared without its action.
public struct SHSidebarDestination: View, Equatable {
    public enum Icon: Equatable, Sendable {
        /// A 15pt (13) stroke in `textSecondary`.
        case symbol(String)
        /// New thread's `plus` in a 20pt `bgSelected` circle.
        case newThread
        /// More's chevron in `textTertiary`: right while closed, down while open.
        case disclosure(open: Bool)
    }

    public enum Trailing: Equatable, Sendable {
        case none
        /// A chord as keycaps ("⌘N").
        case keycaps(String)
        /// A problem in mono 10 `failed` ("1 offline").
        case alert(String)
    }

    let title: String
    let icon: Icon
    let selected: Bool
    let child: Bool
    let trailing: Trailing
    let action: () -> Void
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    /// `child` indents one of More's rows.
    public init(_ title: String, icon: Icon, selected: Bool = false, child: Bool = false, trailing: Trailing = .none,
                action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.child = child
        self.trailing = trailing
        self.action = action
    }

    public nonisolated static func == (a: SHSidebarDestination, b: SHSidebarDestination) -> Bool {
        a.title == b.title && a.icon == b.icon && a.selected == b.selected && a.child == b.child && a.trailing == b.trailing
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.destination")
        Button(action: action) {
            HStack(spacing: density.sidebarRowGap) {
                iconView
                    .frame(width: SHSidebarMetrics.destinationIconSlot, height: SHSidebarMetrics.destinationIconSlot)
                Text(title)
                    .font(density.destinationFont(weight: selected ? .semibold : .regular))
                    .foregroundStyle(.sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.xs)
                trailingView
            }
            .padding(.leading, child ? SHSidebarMetrics.destinationChildLeading : density.sidebarRowPadding)
            .padding(.trailing, density.sidebarRowPadding)
            .frame(maxWidth: .infinity, minHeight: density.destinationHeight, alignment: .leading)
            .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .buttonStyle(SHPlainPressStyle())
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: density.destinationIcon - 2, weight: .regular))
                .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                .accessibilityHidden(true)
        case .newThread:
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.sh.textPrimary)
                .frame(width: SHSidebarMetrics.destinationIconSlot, height: SHSidebarMetrics.destinationIconSlot)
                .background(Color.sh.bgSelected, in: Circle())
                .accessibilityHidden(true)
        case .disclosure(let open):
            Image(systemName: "chevron.right")
                .font(.system(size: density.destinationIcon - 5, weight: .semibold))
                .foregroundStyle(.sh.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .shAnimation(.disclosure, value: open)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .keycaps(let chord):
            SHKeycap(chord)
        case .alert(let text):
            Text(text).font(.shMono(10)).foregroundStyle(.sh.failed).lineLimit(1).fixedSize()
                .shContentTransition(.numeric())
        }
    }
}

// MARK: Lists

/// A list's header (SHNavigation, `SHSidebarSection`): "Needs you" in Geist 11.5 medium
/// `lanternText` with its count in mono 10.5, or "Pinned" or "Recents" in `textTertiary`; in the project tree
/// grouped by host, a host's name in `textTertiary` with "unreachable" in mono 10 `failed` while
/// it is not connected (SidebarTree, `SHSidebarSection(host)`). Padded 14pt (10) above, 4pt
/// below, and 8pt (6) at the sides.
public struct SHSidebarSection: View, Equatable {
    public enum Kind: Equatable, Sendable {
        case needsYou(count: Int)
        /// The threads the user pinned, above Recents (SidebarPinned).
        case pinned
        case recents
        case host(String, unreachable: Bool)
    }

    let kind: Kind
    @Environment(\.shDensity) private var density

    public init(_ kind: Kind) { self.kind = kind }

    public nonisolated static func == (a: SHSidebarSection, b: SHSidebarSection) -> Bool { a.kind == b.kind }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.header")
        let attention = if case .needsYou = kind { true } else { false }
        let tone = attention ? Color.sh.lanternText : Color.sh.textTertiary
        HStack(spacing: SH.Space.s) {
            Text(title)
                .font(.shSans(11.5, .medium))
                .foregroundStyle(tone)
                .lineLimit(1)
            Spacer(minLength: SH.Space.xs)
            switch kind {
            case .needsYou(let count):
                Text("\(count)")
                    .font(.shMono(10.5))
                    .foregroundStyle(tone)
                    .monospacedDigit()
                    .shContentTransition(.numeric())
                    .shAnimation(.content, value: count)
            case .host(_, unreachable: true):
                Text("unreachable").font(.shMono(10)).foregroundStyle(.sh.failed).lineLimit(1).fixedSize()
            case .pinned, .recents, .host:
                EmptyView()
            }
        }
        .padding(EdgeInsets(top: density.sidebarHeaderTop, leading: density.sidebarRowPadding, bottom: SH.Space.xs,
                            trailing: density.sidebarRowPadding))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        switch kind {
        case .needsYou: "Needs you"
        case .pinned: "Pinned"
        case .recents: "Recents"
        case .host(let name, _): name
        }
    }
}

/// One item in Needs you or Recents (SHNavigation, `SHSidebarRow`): a 14pt leading slot (the
/// thread's state dot, or the kind's glyph), the title in the row font (semibold when selected),
/// and one trailing accessory. The density's height (a minimum), radius 8; hover `bgHover`,
/// selected `bgSelected`. Interaction is the caller's.
public struct SHSidebarRow: View, Equatable {
    public enum Leading: Equatable, Sendable {
        /// The state dot: hollow while idle, glowing while it needs you.
        case dot(AgentState)
        /// A kind's glyph (an automation's bolt): `lanternText` while it needs you, else
        /// `textTertiary`.
        case glyph(String, attention: Bool)        /// A clock in `textSecondary`: a restored agent the first launch's copy from your pi holds
        /// (PiAuthStates' `.waiting`).
        case waiting
    }

    public enum Accessory: Equatable, Sendable {
        case none
        /// Why it needs you, in mono 10 `lanternText` ("retention?", "ASK").
        case reason(String)
        /// Live elapsed time since a moment ("4m"), in `textTertiary`.
        case elapsed(since: Date)
        /// Completion age, using the same bounded minute/hour schedule as elapsed time.
        case age(since: Date)
        /// Measured activity, a 28 × 12 blue sparkline.
        case activity([Double])
        /// A word in mono 10, `textTertiary` or its tone's color ("done", "failed").
        case text(String, tone: AgentState? = nil)
        /// A remote host's name as a tag: mono 10 `textTertiary` in a 1pt `lineSubtle` border.
        case tag(String)
        /// The ⌘-digit hint while ⌘ is held.
        case shortcut(String)
    }

    let title: String
    let leading: Leading
    let selected: Bool
    let dimmed: Bool
    let accessory: Accessory
    let hasGoal: Bool
    let nested: Bool
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    /// `nested` is a thread inside a project of the project tree: its leading slot sits under
    /// the project's folder (`SHDensity.treeChildLeading`).
    public init(_ title: String, leading: Leading, selected: Bool = false, dimmed: Bool = false, accessory: Accessory = .none,
                hasGoal: Bool = false, nested: Bool = false) {
        self.title = title
        self.leading = leading
        self.selected = selected
        self.dimmed = dimmed
        self.accessory = accessory
        self.hasGoal = hasGoal
        self.nested = nested
    }

    /// A thread's row: its state dot.
    public init(_ title: String, state: AgentState, selected: Bool = false, dimmed: Bool = false, accessory: Accessory = .none,
                hasGoal: Bool = false, nested: Bool = false) {
        self.init(title, leading: .dot(state), selected: selected, dimmed: dimmed, accessory: accessory, hasGoal: hasGoal, nested: nested)
    }

    public nonisolated static func == (a: SHSidebarRow, b: SHSidebarRow) -> Bool {
        a.title == b.title && a.leading == b.leading && a.selected == b.selected && a.dimmed == b.dimmed
            && a.accessory == b.accessory && a.hasGoal == b.hasGoal && a.nested == b.nested
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.row")
        // A status report, a settled name, or ⌘ held changes one part in place (`.content`);
        // selection is not animated here, so it lands at once.
        HStack(spacing: density.sidebarRowGap) {
            leadingView
                .frame(width: SHSidebarMetrics.rowSlot)
                .shAnimation(.content, value: leading)
            Text(title)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .shContentTransition(.crossFade)
                .shAnimation(.content, value: title)
            Spacer(minLength: SH.Space.xs)
            if hasGoal { SHGoalGlyph().foregroundStyle(Color.sh.textTertiary) }
            SHSidebarAccessoryView(accessory: accessory)
                .shAnimation(.content, value: accessory)
        }
        .padding(.leading, nested ? density.treeChildLeading : density.sidebarRowPadding)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .dot(let state):
            SHSidebarDot(state: state)
        case .glyph(let name, let attention):
            Image(systemName: name)
                .font(.system(size: density.rowGlyph - 1, weight: .regular))
                .foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textTertiary)
                .accessibilityHidden(true)
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: density.rowGlyph - 2, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

/// The row dot: hollow while idle or queued, glowing while it needs you.
struct SHSidebarDot: View {
    let state: AgentState

    /// A ZStack, so a hollow dot and a filled one cross-fade in one place.
    var body: some View {
        ZStack {
            if state == .idle || state == .queued {
                Circle().strokeBorder(Color.sh.textTertiary, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            } else {
                SHStatusDot(state)
            }
        }
    }
}

private struct SHSidebarAccessoryView: View {
    let accessory: SHSidebarRow.Accessory

    /// A ZStack, so the old and new accessory cross-fade in one slot; nothing at all without
    /// one, so the row's spacing leaves the title its room.
    var body: some View {
        if accessory != .none {
            ZStack(alignment: .trailing) { content }
        }
    }

    @ViewBuilder private var content: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .reason(let text):
            Text(text).font(.shMono(10)).foregroundStyle(.sh.lanternText).lineLimit(1).fixedSize()
        case .elapsed(let since):
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(SHDuration.text(context.date.timeIntervalSince(since)))
                    .font(.shMono(10)).foregroundStyle(.sh.textTertiary).monospacedDigit().fixedSize()
            }
        case .activity(let samples):
            SHSidebarActivityLine(samples: samples)
                .stroke(Color.sh.running, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: SHSidebarMetrics.activityWidth, height: SHSidebarMetrics.activityHeight)
                .accessibilityHidden(true)
        case .age(let since):
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text("\(SHDuration.text(max(0, context.date.timeIntervalSince(since)))) ago")
                    .font(.shMono(SHSidebarMetrics.accessoryFont)).foregroundStyle(.sh.textTertiary).monospacedDigit().fixedSize()
            }
        case .text(let text, let tone):
            Text(text).font(.shMono(10)).foregroundStyle(color(tone)).lineLimit(1).fixedSize()
        case .tag(let name):
            Text(name)
                .font(.shMono(10))
                .foregroundStyle(.sh.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, SH.Space.xs)
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.xs)
                .fixedSize()
        case .shortcut(let text):
            Text(text).font(.sh(.micro, weight: .regular)).foregroundStyle(.sh.textTertiary).fixedSize()
        }
    }

    private func color(_ tone: AgentState?) -> Color {
        switch tone {
        case .failed?, .stuck?: .sh.failed
        case .attention?: .sh.lanternText
        default: .sh.textTertiary
        }
    }
}

// MARK: Footer

/// The sidebar's footer (SHNavigation): behind a hairline, a 26pt `bgSelected` circle with the
/// initial, the name in `ui` medium over where it runs in mono 10 `textTertiary` ("This Mac ·
/// demo-mac"), and a Settings gear. Padded 10pt above and below and 12pt at the sides.
public struct SHSidebarFooter: View, Equatable {
    let name: String
    let detail: String
    let settingsShortcut: String?
    let settings: () -> Void

    public init(name: String, detail: String, settingsShortcut: String? = nil, settings: @escaping () -> Void) {
        self.name = name
        self.detail = detail
        self.settingsShortcut = settingsShortcut
        self.settings = settings
    }

    public nonisolated static func == (a: SHSidebarFooter, b: SHSidebarFooter) -> Bool {
        a.name == b.name && a.detail == b.detail && a.settingsShortcut == b.settingsShortcut
    }

    /// The avatar's letter: the name's first, capitalized.
    public static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(Self.initial(name))
                .font(.shSans(11.5, .semibold))
                .foregroundStyle(.sh.textPrimary)
                .frame(width: SHSidebarMetrics.footerAvatar, height: SHSidebarMetrics.footerAvatar)
                .background(Color.sh.bgSelected, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.sh(.ui, weight: .medium)).foregroundStyle(.sh.textPrimary).lineLimit(1)
                Text(detail).font(.shMono(10)).foregroundStyle(.sh.textTertiary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: settings) { Image(systemName: "gearshape") }
                .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
                .shHelp("Settings", shortcut: settingsShortcut)
                .accessibilityLabel("Settings")
        }
        // The boards' footer is 52pt tall and its rule is 46pt above the bottom edge: the content is the 26pt avatar, 9pt below the rule
        // and 10pt above the bottom; 6pt of the footer's height sits above the rule.
        .frame(height: SHSidebarMetrics.footerAvatar)
        .padding(.top, SHSidebarMetrics.footerRuleToContent + 1)
        .padding(.bottom, SHSidebarMetrics.footerBottom)
        .padding(.horizontal, SH.Space.l)
        .overlay(alignment: .top) { SHHairline() }
        .padding(.top, SHSidebarMetrics.footerAboveRule)
    }
}

// MARK: Shared

/// The 2pt drop line a reorder drag shows at a row's top or bottom edge (`lantern` in the
/// composer's queue).
public struct SHDropIndicator: View {
    /// The line's height.
    public static let thickness: CGFloat = 2

    let color: Color?

    public init(color: Color? = nil) { self.color = color }

    public var body: some View {
        Rectangle().fill(color ?? Color.sh.running).frame(height: Self.thickness)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A plain button that dims while pressed and draws the focus ring; for rows and fields that
/// carry their own chrome.
struct SHPlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .shFocusRing(radius: SH.Radius.s)
    }
}

extension View {
    /// Drags the window from this view's empty area (a title bar region). No-op off macOS.
    @ViewBuilder func shWindowDrag() -> some View {
        #if os(macOS)
        gesture(WindowDragGesture())
        #else
        self
        #endif
    }
}
