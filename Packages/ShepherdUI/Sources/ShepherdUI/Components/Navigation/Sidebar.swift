import SwiftUI

/// The sidebar panel (the redesign boards' `.side`): a 14pt rounded glass panel with a 1px line,
/// a 1px shine along its top and a soft shadow, holding the 44pt top bar (room for the window
/// controls, then Hide sidebar and Search; it drags the window), the destinations and lists, and
/// the 44pt footer. The caller insets it from the window.
public struct SHSidebar<TopBar: View, Content: View, Footer: View>: View {
    let topBar: TopBar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    /// `topBar` is the Mac's `SHSidebarTopBar`, or the touch client's own bar of the same height.
    public init(topBar: TopBar, @ViewBuilder content: @escaping () -> Content,
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
        .shGlassPanel()
    }
}

extension View {
    /// The boards' glass panel (`.side`): `bgGlass` in a 14pt rounded rectangle, a 1px `lineSubtle`
    /// border, a 1px shine inside its top edge, and the far `lift` shadow (light only). No live
    /// blur: nothing scrolls behind the sidebar, so the fill alone looks the same and costs nothing.
    public func shGlassPanel(radius: CGFloat = SH.Radius.xl) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return clipShape(shape)
            .background {
                #if os(macOS)
                // From a path set at layout, so dragging the sidebar's edge draws no shadow offscreen.
                SHShadowFill(shape: shape, fill: .sh.bgGlass,
                             shadows: [SHShadowSpec(color: .sh.liftFar, radius: SHSidebarMetrics.panelShadowRadius, y: SHSidebarMetrics.panelShadowOffset)])
                #else
                shape.fill(Color.sh.bgGlass)
                    .shadow(color: .sh.liftFar, radius: SHSidebarMetrics.panelShadowRadius, y: SHSidebarMetrics.panelShadowOffset)
                #endif
            }
            .overlay {
                shape.strokeBorder(Color.sh.glassShine, lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: radius / 2) }
                    .allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(Color.sh.lineSubtle, lineWidth: 1).allowsHitTesting(false) }
    }
}

extension SHSidebar where Footer == EmptyView {
    public init(topBar: TopBar, @ViewBuilder content: @escaping () -> Content) {
        self.init(topBar: topBar, content: content, footer: { EmptyView() })
    }
}

/// The sidebar's fixed measures (SHNavigation). Row heights follow `SHDensity`.
public enum SHSidebarMetrics {
    /// The panel sits this far in from the window's leading, top and bottom edges.
    public static let panelInset: CGFloat = 8
    /// The panel's soft shadow (the boards' 0 6 20).
    public static let panelShadowRadius: CGFloat = 10
    public static let panelShadowOffset: CGFloat = 6
    /// The top bar: room for the window controls, unified with the title bar (the toolbar
    /// beside it is as tall).
    public static let topBarHeight: CGFloat = 44
    /// The top bar's Hide sidebar and Search buttons: 28pt rounded squares 4pt apart, 10pt from the edge.
    public static let topBarButton: CGFloat = 28
    public static let topBarButtonGap: CGFloat = 4
    public static let topBarTrailing: CGFloat = 10
    /// The destinations and lists sit 8pt in from the column's sides, rows 1pt apart.
    public static let listInset: CGFloat = 8
    public static let rowSpacing: CGFloat = 1
    /// The destinations' stack is padded 2pt above and below.
    public static let destinationsPadding: CGFloat = 2
    /// A destination is as tall as a list row.
    public static let destinationExtra: CGFloat = 0
    /// A destination's 16pt icon slot.
    public static let destinationIconSlot: CGFloat = 16
    /// More's rows (Hosts, Extensions) lead 22pt in instead of 8.
    public static let destinationChildLeading: CGFloat = 22
    /// A list row's leading slot (a dot or a kind's glyph).
    public static let rowSlot: CGFloat = 14
    /// The footer's buttons.
    public static let footerAvatar: CGFloat = 28
    /// The footer line: 44pt, padded 16 before and 10 after.
    public static let footerHeight: CGFloat = 44
    public static let footerLeading: CGFloat = 16
    public static let footerGlyph: CGFloat = 16
    /// A row with a second line is padded this much above and below, at least 38pt tall.
    public static let subtitleRowPadding: CGFloat = 5
    public static let subtitleRowHeight: CGFloat = 38
    /// A thread under the thread that sent it sits this far in.
    public static let sentLeading: CGFloat = 26
    /// The trailing reason a Needs you row shows ("retention?") is cut to this many characters.
    public static let reasonLength = 14

    /// A row's height: the density's, and on a touch screen never under the 44pt minimum.
    @MainActor public static func rowHeight(_ density: SHDensity) -> CGFloat {
        #if os(iOS)
        max(density.rowHeight, SH.Height.touch)
        #else
        density.rowHeight
        #endif
    }
}

/// The measures that change with the row density: Standard is the boards' value, Compact the
/// Compact sample's; Comfortable takes Standard's spacing at its own height.
extension SHDensity {
    /// A row's side padding and the gap after its leading slot.
    public var sidebarRowPadding: CGFloat { self == .compact ? SH.Space.s : SH.Space.m }
    public var sidebarRowGap: CGFloat { self == .compact ? SH.Space.s : SH.Space.m }
    /// A section header's top margin.
    public var sidebarHeaderTop: CGFloat { self == .compact ? SH.Space.m : 10 }
    /// A destination's title and icon.
    @MainActor public var destinationFont: Font { self == .compact ? .shSans(12) : .sh(.ui) }
    @MainActor public func destinationFont(weight: Font.Weight) -> Font {
        self == .compact ? .shSans(12, weight) : .sh(.ui, weight: weight)
    }
    public var destinationIcon: CGFloat { self == .compact ? 13 : 15 }
    /// A list row's glyph (an automation's bolt).
    public var rowGlyph: CGFloat { self == .compact ? 11 : 13 }
    /// A destination's height at the current density scale.
    @MainActor public var destinationHeight: CGFloat { SHSidebarMetrics.rowHeight(self) + SHSidebarMetrics.destinationExtra }
}

// MARK: Top bar

/// The 44pt top bar: the window controls' room, a spacer that drags the window, then Hide
/// sidebar (⇧⌘S) and Search (⌘K) as 28pt icon buttons.
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
            if let hide {
                button("sidebar.left", label: "Hide sidebar", shortcut: hideShortcut, action: hide)
            }
            if let search {
                button("magnifyingglass", label: "Search", shortcut: searchShortcut, action: search)
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

/// A destination (the boards' nav rows): New thread with its chord, Designs, Automations, Issues &
/// PRs. A row tall (28), radius 7, a 16pt icon slot in `textSecondary`, the title in `ui`. The
/// selected one is `bgSelected`; hover is `bgHover`. A button; compared without its action.
public struct SHSidebarDestination: View, Equatable {
    public enum Icon: Equatable, Sendable {
        /// A 15pt (13) stroke in `textSecondary`.
        case symbol(String)
        /// New thread's compose glyph.
        case newThread
        /// More's chevron in `textTertiary`: right while closed, down while open.
        case disclosure(open: Bool)
    }

    public enum Trailing: Equatable, Sendable {
        case none
        /// A chord ("⌘N") in `caption` `textTertiary`.
        case keycaps(String)
        /// A problem in mono 10 `failed` ("1 offline").
        case alert(String)
        /// Things not opened yet (Automations' unread runs), as a neutral count badge.
        case count(Int)
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
                    .font(density.destinationFont(weight: .regular))
                    .foregroundStyle(.sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.xs)
                trailingView
            }
            .padding(.leading, child ? SHSidebarMetrics.destinationChildLeading : density.sidebarRowPadding)
            .padding(.trailing, density.sidebarRowPadding)
            .frame(maxWidth: .infinity, minHeight: density.destinationHeight, alignment: .leading)
            .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.s)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
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
                .font(.system(size: density.destinationIcon - 1, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
                .accessibilityHidden(true)
        case .newThread:
            Image(systemName: "square.and.pencil")
                .font(.system(size: density.destinationIcon - 1, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
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
            Text(chord).font(.sh(.caption)).foregroundStyle(.sh.textTertiary).fixedSize()
        case .alert(let text):
            Text(text).font(.sh(.caption)).foregroundStyle(.sh.failed).lineLimit(1).fixedSize()
                .shContentTransition(.numeric())
        case .count(let count):
            Text("\(count)").font(.sh(.caption)).foregroundStyle(.sh.textSecondary).monospacedDigit().fixedSize()
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

/// One thread in a list (the boards' `.row.thr`): the title in the row font (semibold while it is
/// unseen) and one trailing accessory in `caption`. No leading slot: the section says the state,
/// and the accessory says why ("retention?", "failed", "2m"). The density's height (a minimum),
/// radius 7; hover `bgHover`, selected `bgSelected`. Interaction is the caller's.
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

    /// A short mono 10 label before the accessory, in its own color: a thread's pull request ("#31").
    public struct Badge: Equatable, Sendable {
        public let text: String
        public let color: Color

        public init(_ text: String, color: Color) {
            self.text = text
            self.color = color
        }
    }

    /// A second line under the title in `caption` (FleetSubthreads): "3 sent · 1 back", "mini · delivering". Sans, `textTertiary` unless its
    /// tone says more.
    public struct Subtitle: Equatable, Sendable {
        public enum Tone: Equatable, Sendable {
            case quiet
            /// Work in progress: `running`.
            case running
            /// Waiting on you: `lanternText`.
            case attention
            case failed
        }

        public let text: String
        public let tone: Tone
        /// When set, the line ends with how long since then ("mini · running 4m"), counting on by itself.
        public let since: Date?

        public init(_ text: String, tone: Tone = .quiet, since: Date? = nil) {
            self.text = text
            self.tone = tone
            self.since = since
        }
    }

    /// A chevron at the row's trailing edge that folds what is under it (a thread's sent threads): its own button, so a tap on it never opens the
    /// row. Compared by `open` alone.
    public struct Fold: Equatable {
        public let open: Bool
        public let toggle: () -> Void

        public init(open: Bool, toggle: @escaping () -> Void) {
            self.open = open
            self.toggle = toggle
        }

        public nonisolated static func == (a: Fold, b: Fold) -> Bool { a.open == b.open }
    }

    let title: String
    let leading: Leading
    let selected: Bool
    let dimmed: Bool
    let accessory: Accessory
    let hasGoal: Bool
    let nested: Bool
    let badge: Badge?
    let elbow: Bool
    let subtitle: Subtitle?
    let fold: Fold?
    let unseen: Bool
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    /// `nested` is a thread inside a project of the project tree: its title sits under the
    /// project's (`SHDensity.treeChildLeading`). `elbow` marks a thread under the thread that sent it
    /// to another Mac: it sits `sentLeading` in. `unseen` sets the title semibold (a finished thread not opened yet).
    public init(_ title: String, leading: Leading, selected: Bool = false, dimmed: Bool = false, accessory: Accessory = .none,
                hasGoal: Bool = false, nested: Bool = false, badge: Badge? = nil, elbow: Bool = false, subtitle: Subtitle? = nil,
                fold: Fold? = nil, unseen: Bool = false) {
        self.unseen = unseen
        self.subtitle = subtitle
        self.fold = fold
        self.elbow = elbow
        self.badge = badge
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
                hasGoal: Bool = false, nested: Bool = false, badge: Badge? = nil, elbow: Bool = false, subtitle: Subtitle? = nil,
                fold: Fold? = nil, unseen: Bool = false) {
        self.init(title, leading: .dot(state), selected: selected, dimmed: dimmed, accessory: accessory, hasGoal: hasGoal, nested: nested,
                  badge: badge, elbow: elbow, subtitle: subtitle, fold: fold, unseen: unseen)
    }

    public nonisolated static func == (a: SHSidebarRow, b: SHSidebarRow) -> Bool {
        a.title == b.title && a.leading == b.leading && a.selected == b.selected && a.dimmed == b.dimmed
            && a.accessory == b.accessory && a.hasGoal == b.hasGoal && a.nested == b.nested && a.badge == b.badge && a.elbow == b.elbow
            && a.subtitle == b.subtitle && a.fold == b.fold && a.unseen == b.unseen
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.row")
        // A status report, a settled name, or ⌘ held changes one part in place (`.content`);
        // selection is not animated here, so it lands at once.
        HStack(spacing: density.sidebarRowGap) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(density.rowTitleFont(weight: unseen ? .semibold : .regular))
                    .foregroundStyle(.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shContentTransition(.crossFade)
                    .shAnimation(.content, value: title)
                if let subtitle { SHSidebarSubtitleView(subtitle: subtitle) }
            }
            Spacer(minLength: SH.Space.xs)
            if hasGoal { SHGoalGlyph().foregroundStyle(Color.sh.textTertiary) }
            if let badge {
                Text(badge.text).font(.sh(.caption)).foregroundStyle(badge.color).monospacedDigit().lineLimit(1).fixedSize()
                    .shAnimation(.content, value: badge)
            }
            SHSidebarAccessoryView(accessory: accessory)
                .shAnimation(.content, value: accessory.motionKey)
            // An open sender's chevron shows while the pointer is over it, so its title keeps its room.
            if let fold, !fold.open || hovering || SHPlatform.showsHoverDetails {
                Button(action: fold.toggle) {
                    SHTurningChevron(isOpen: fold.open)
                        .font(.sh(.micro, weight: .semibold))
                        .foregroundStyle(.sh.textSecondary)
                        .frame(width: SHSidebarMetrics.rowSlot, height: SHSidebarMetrics.rowSlot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fold.open ? "Hide threads it started" : "Show threads it started")
            }
        }
        .padding(.leading, nested ? density.treeChildLeading : elbow ? SHSidebarMetrics.sentLeading : density.sidebarRowPadding)
        .padding(.trailing, density.sidebarRowPadding)
        .padding(.vertical, subtitle == nil ? 0 : SHSidebarMetrics.subtitleRowPadding)
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? SHSidebarMetrics.rowHeight(density) : SHSidebarMetrics.subtitleRowHeight,
               alignment: subtitle == nil ? .leading : .topLeading)
        .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.s)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
    }
}

/// A row's second line.
private struct SHSidebarSubtitleView: View {
    let subtitle: SHSidebarRow.Subtitle
    /// While the sidebar cannot be seen its clock stops ticking, and starts again when it shows.
    @Environment(\.shMotionPaused) private var motionPaused

    var body: some View {
        if let since = subtitle.since {
            TimelineView(SHElapsedSchedule(start: since, aligned: true, paused: motionPaused)) { context in
                let _ = SHRenderProbe.tick("sidebar.clock")
                text("\(subtitle.text) \(SHDuration.text(max(0, context.date.timeIntervalSince(since))))")
            }
        } else {
            text(subtitle.text)
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(.sh(.caption, weight: .regular))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The boards set every second line in `textTertiary`; a failure keeps its red.
    private var color: Color {
        subtitle.tone == .failed ? .sh.failed : .sh.textTertiary
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

extension SHSidebarRow.Accessory {
    /// The accessory as far as motion is concerned. A sparkline redrawn with new samples is not
    /// a change to ease (its path does not animate), so every sparkline reads the same.
    var motionKey: Self {
        if case .activity = self { .activity([]) } else { self }
    }
}

private struct SHSidebarAccessoryView: View {
    let accessory: SHSidebarRow.Accessory
    /// While the sidebar cannot be seen its clocks stop ticking, and start again when it shows.
    @Environment(\.shMotionPaused) private var motionPaused

    /// A ZStack, so the old and new accessory cross-fade in one slot; nothing at all without
    /// one, so the row's spacing leaves the title its room.
    var body: some View {
        if accessory != .none {
            ZStack(alignment: .trailing) { content }
        }
    }

    @ViewBuilder private var content: some View {
        switch accessory {
        case .none, .activity:
            // The boards draw nothing after a working thread: its section already says it works.
            EmptyView()
        case .reason(let text):
            word(text, color: .sh.textSecondary)
        case .elapsed(let since):
            TimelineView(SHElapsedSchedule(start: since, aligned: true, paused: motionPaused)) { context in
                let _ = SHRenderProbe.tick("sidebar.clock")
                word(SHDuration.text(context.date.timeIntervalSince(since))).monospacedDigit()
            }
        case .age(let since):
            TimelineView(SHElapsedSchedule(start: since, aligned: true, paused: motionPaused)) { context in
                let _ = SHRenderProbe.tick("sidebar.clock")
                word(SHDuration.text(max(0, context.date.timeIntervalSince(since)))).monospacedDigit()
            }
        case .text(let text, let tone):
            word(text, color: tone == .attention ? .sh.textSecondary : .sh.textTertiary)
        case .tag(let name):
            word(name)
        case .shortcut(let text):
            word(text)
        }
    }

    /// The boards' `.ac`: `caption` in `textTertiary` (`textSecondary` when it asks you).
    private func word(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(.sh(.caption)).foregroundStyle(color ?? .sh.textTertiary).lineLimit(1).fixedSize()
    }
}

// MARK: Footer

/// The sidebar's footer (the boards' `.foot`): a 44pt line with the Mac glyph, where it runs in
/// `caption` `textSecondary` ("This Mac · demo-mac"), and the Settings gear. While an update is
/// ready (`updateVersion`), `SHUpdateButton` takes the gear's place.
public struct SHSidebarFooter: View, Equatable {
    let name: String
    let detail: String
    let settingsShortcut: String?
    let updateVersion: String?
    let settings: () -> Void
    let update: () -> Void
    /// The detail line as a button (the iPhone and iPad's Fleet line opens Fleet); the Mac's is plain text.
    let openDetail: (() -> Void)?

    public init(name: String, detail: String, settingsShortcut: String? = nil, updateVersion: String? = nil,
                openDetail: (() -> Void)? = nil, settings: @escaping () -> Void, update: @escaping () -> Void = {}) {
        self.openDetail = openDetail
        self.name = name
        self.detail = detail
        self.settingsShortcut = settingsShortcut
        self.updateVersion = updateVersion
        self.settings = settings
        self.update = update
    }

    public nonisolated static func == (a: SHSidebarFooter, b: SHSidebarFooter) -> Bool {
        a.name == b.name && a.detail == b.detail && a.settingsShortcut == b.settingsShortcut && a.updateVersion == b.updateVersion
    }

    /// The avatar's letter: the name's first, capitalized.
    public static func initial(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            if detail.isEmpty {
                EmptyView()
            } else if let openDetail {
                Button(action: openDetail) { line }
                    .buttonStyle(.plain)
            } else {
                line
            }
            Spacer(minLength: 0)
            if let updateVersion {
                SHUpdateButton(version: updateVersion, action: update)
            } else {
                Button(action: settings) { Image(systemName: "gearshape") }
                    .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar))
                    .shHelp("Settings", shortcut: settingsShortcut)
                    .accessibilityLabel("Settings")
            }
        }
        .padding(.leading, SHSidebarMetrics.footerLeading)
        .padding(.trailing, SHSidebarMetrics.topBarTrailing)
        .frame(height: SHSidebarMetrics.footerHeight)
    }
}

extension SHSidebarFooter {
    /// The Mac glyph and the detail words.
    @ViewBuilder fileprivate var line: some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: SHSidebarMetrics.footerGlyph - 2))
                .foregroundStyle(.sh.textSecondary)
                .frame(width: SHSidebarMetrics.footerGlyph)
                .accessibilityHidden(true)
            Text(detail).font(.sh(.caption)).foregroundStyle(.sh.textSecondary).lineLimit(1)
                .accessibilityLabel(name.isEmpty ? detail : "\(name), \(detail)")
        }
        .frame(minHeight: SHSidebarMetrics.footerHeight)
        .contentShape(Rectangle())
    }
}

/// An update is ready (UpdateFooterStates, UpdateButton): `square.and.arrow.down` in the attention orange, on the
/// hover fill when hovered, in the footer gear's 28pt place. It stands in for the gear in `SHSidebarFooter`
/// and the Fleet corner; the action brings up the update.
public struct SHUpdateButton: View {
    let version: String
    let action: () -> Void

    public init(version: String, action: @escaping () -> Void) {
        self.version = version
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Image(systemName: "square.and.arrow.down") }
            .buttonStyle(.shIcon(size: SHSidebarMetrics.footerAvatar, tint: .sh.lantern))
            .shHelp("Update to \(version)…")
            .accessibilityLabel("Update Shepherd to \(version)")
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
