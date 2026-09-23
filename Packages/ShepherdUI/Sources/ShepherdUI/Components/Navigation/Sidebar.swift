import SwiftUI

/// The sidebar column (Navigation board): a 44pt top bar that leaves room for the window
/// controls and holds the compose button, the "Jump to…" field, the scrolling tree, and a
/// footer behind a 1px rule. On `bgBase`; the caller draws the trailing edge.
public struct NWSidebar<Content: View, Footer: View>: View {
    let compose: (() -> Void)?
    let composeLabel: String
    let composeShortcut: String?
    let jump: (() -> Void)?
    let jumpShortcut: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    public init(compose: (() -> Void)? = nil, composeLabel: String = "New agent", composeShortcut: String? = nil,
                jump: (() -> Void)? = nil, jumpShortcut: String? = nil,
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder footer: @escaping () -> Footer) {
        self.compose = compose
        self.composeLabel = composeLabel
        self.composeShortcut = composeShortcut
        self.jump = jump
        self.jumpShortcut = jumpShortcut
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).nwWindowDrag()
                if let compose {
                    Button(action: compose) { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.nwIcon(size: 26))
                        .nwHelp(composeLabel, shortcut: composeShortcut)
                        .accessibilityLabel(composeLabel)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, NW.Space.m)
            .frame(height: NWSidebarMetrics.topBarHeight)
            if let jump {
                NWSidebarJumpButton(shortcut: jumpShortcut, action: jump)
                    .padding(.horizontal, NW.Space.m)
                    .padding(.bottom, NW.Space.xs)
            }
            content()
                .frame(maxHeight: .infinity, alignment: .top)
            footer()
        }
        .background(Color.nw.bgBase)
    }
}

extension NWSidebar where Footer == EmptyView {
    public init(compose: (() -> Void)? = nil, composeLabel: String = "New agent", composeShortcut: String? = nil,
                jump: (() -> Void)? = nil, jumpShortcut: String? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.init(compose: compose, composeLabel: composeLabel, composeShortcut: composeShortcut, jump: jump,
                  jumpShortcut: jumpShortcut, content: content, footer: { EmptyView() })
    }
}

/// The sidebar's fixed measures (Navigation board).
public enum NWSidebarMetrics {
    /// The top bar: window controls and compose, unified with the title bar.
    public static let topBarHeight: CGFloat = 44
    /// Horizontal inset of the tree inside the column.
    public static let treeInset: CGFloat = 6
    /// The tree's rows sit 1pt apart.
    public static let rowSpacing: CGFloat = 1
    /// Leading padding of a row's content, and the step each nesting level adds.
    public static let rowPadding: CGFloat = 8
    public static let indentStep: CGFloat = 14
    /// Gap between a row's dot and its title.
    public static let rowGap: CGFloat = 9
}

/// "Jump to…" under the window controls: a quiet search-shaped button that opens the command
/// palette, with the palette's real shortcut.
public struct NWSidebarJumpButton: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    public init(_ title: String = "Jump to…", shortcut: String?, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.nw.textTertiary)
                Text(title)
                    .font(.nwSans(12))
                    .foregroundStyle(.nw.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.xs)
                if let shortcut { NWKeycap(shortcut) }
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: 26)
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .nwBorder(.nw.lineSubtle, radius: NW.Radius.s)
        }
        .buttonStyle(NWPlainPressStyle())
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Opens the command palette, \($0)" } ?? "Opens the command palette")
    }
}

/// What a sidebar section header shows after its label.
public enum NWSidebarSectionDetail: Equatable, Sendable {
    case none
    case count(Int)
    /// A connection or attention word, colored by `tone` when it carries one.
    case text(String, tone: AgentState?)
}

/// A section label with its count or state ("THIS MAC 19", "HORIZON Unreachable"). Clicking the
/// label toggles the section; `accessory` (a hover `+`) sits beside it as its own button.
public struct NWSidebarSection<Accessory: View>: View {
    public typealias Detail = NWSidebarSectionDetail

    let title: String
    let detail: Detail
    let collapsed: Bool
    let hoverHint: String?
    let toggle: (() -> Void)?
    @ViewBuilder let accessory: () -> Accessory
    @State private var hovering = false
    /// The accessory's width once laid out; zero while it draws nothing (a disconnected host).
    @State private var accessoryWidth: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    public init(_ title: String, detail: Detail = .none, collapsed: Bool = false, hoverHint: String? = nil,
                toggle: (() -> Void)? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.detail = detail
        self.collapsed = collapsed
        self.hoverHint = hoverHint
        self.toggle = toggle
        self.accessory = accessory
    }

    /// `hovering` starts the header hovered, for previews and tests.
    init(_ title: String, detail: Detail = .none, collapsed: Bool = false, hoverHint: String? = nil,
         toggle: (() -> Void)? = nil, hovering: Bool, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(title, detail: detail, collapsed: collapsed, hoverHint: hoverHint, toggle: toggle, accessory: accessory)
        _hovering = State(initialValue: hovering)
    }

    /// Hovering never moves or resizes the header: the hint and the accessory are always laid
    /// out and only fade, and the accessory (taller than the label) floats over the count's slot
    /// instead of joining the row. Always shown for VoiceOver.
    public var body: some View {
        let showsAccessory = accessoryWidth > 0 && (hovering || voiceOver)
        Button { toggle?() } label: {
            HStack(spacing: NW.Space.s) {
                Text(title).nwSectionLabel().lineLimit(1)
                    .opacity(collapsed ? 0.7 : 1)
                Spacer(minLength: NW.Space.xs)
                if let hoverHint {
                    Text(hoverHint).font(.nw(.micro, weight: .regular)).foregroundStyle(.nw.textTertiary)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                detailView
                    .opacity(showsAccessory ? 0 : 1)
                    .frame(minWidth: accessoryWidth, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NWPlainPressStyle())
        .disabled(toggle == nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
        .overlay(alignment: .trailing) {
            accessory()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessoryWidth = $0 }
                .opacity(showsAccessory ? 1 : 0)
                .allowsHitTesting(showsAccessory)
                .accessibilityHidden(!showsAccessory)
        }
        .padding(EdgeInsets(top: NW.Space.l, leading: NW.Space.m, bottom: NW.Space.xs, trailing: NW.Space.m))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }

    @ViewBuilder private var detailView: some View {
        switch detail {
        case .none:
            EmptyView()
        case .count(let count):
            if count > 0 {
                Text("\(count)").font(.nw(.micro, weight: .regular)).foregroundStyle(.nw.textTertiary).monospacedDigit()
            }
        case .text(let text, let tone):
            Text(text).font(.nwSans(11, .medium)).foregroundStyle(tone?.textColor ?? .nw.textTertiary).lineLimit(1)
        }
    }

    private var accessibilityText: String {
        var parts = [title]
        switch detail {
        case .count(let count) where count > 0: parts.append("\(count)")
        case .text(let text, _): parts.append(text)
        default: break
        }
        if toggle != nil { parts.append(collapsed ? "collapsed" : "expanded") }
        return parts.joined(separator: ", ")
    }
}

extension NWSidebarSection where Accessory == EmptyView {
    public init(_ title: String, detail: Detail = .none, collapsed: Bool = false, hoverHint: String? = nil,
                toggle: (() -> Void)? = nil) {
        self.init(title, detail: detail, collapsed: collapsed, hoverHint: hoverHint, toggle: toggle) { EmptyView() }
    }
}

/// One agent, subagent, or automation in the tree (Navigation board, `NWSidebarRow`). Its look
/// follows the state: a 6pt dot (hollow while idle, glowing while it needs you), the title
/// (semibold when selected), and one trailing accessory. Rows nest by `depth`; height is the
/// environment's `nwDensity`, as a minimum. Interaction is the caller's.
public struct NWSidebarRow: View, Equatable {
    public enum Accessory: Equatable, Sendable {
        case none
        /// Needs you: "ASK" in lantern text.
        case ask
        /// Live elapsed time since a moment ("4m"), in tertiary, or `failed` for a stuck or
        /// failed run.
        case elapsed(since: Date, tone: AgentState)
        /// A fixed duration or word ("41m", "done", "3 sub").
        case text(String, tone: AgentState? = nil)
        /// The ⌘-digit hint while ⌘ is held.
        case shortcut(String)
    }

    let title: String
    let state: AgentState
    let selected: Bool
    let depth: Int
    let worktree: Bool
    let dimmed: Bool
    let accessory: Accessory
    @Environment(\.nwDensity) private var density
    @State private var hovering = false

    public init(_ title: String, state: AgentState, selected: Bool = false, depth: Int = 0, worktree: Bool = false,
                dimmed: Bool = false, accessory: Accessory = .none) {
        self.title = title
        self.state = state
        self.selected = selected
        self.depth = depth
        self.worktree = worktree
        self.dimmed = dimmed
        self.accessory = accessory
    }

    public nonisolated static func == (a: NWSidebarRow, b: NWSidebarRow) -> Bool {
        a.title == b.title && a.state == b.state && a.selected == b.selected && a.depth == b.depth
            && a.worktree == b.worktree && a.dimmed == b.dimmed && a.accessory == b.accessory
    }

    public var body: some View {
        HStack(spacing: NWSidebarMetrics.rowGap) {
            NWSidebarDot(state: state)
            if worktree {
                Text("⎇").font(.nw(.micro)).foregroundStyle(.nw.textSecondary).accessibilityHidden(true)
            }
            Text(title)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            NWSidebarAccessoryView(accessory: accessory)
        }
        .padding(.leading, NWSidebarMetrics.rowPadding + CGFloat(depth) * NWSidebarMetrics.indentStep)
        .padding(.trailing, NWSidebarMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: selected, hovering: hovering)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .opacity(dimmed ? 0.55 : 1)
    }
}

/// The row dot: hollow while idle or queued, glowing while it needs you.
struct NWSidebarDot: View {
    let state: AgentState

    var body: some View {
        if state == .idle || state == .queued {
            Circle().strokeBorder(Color.nw.textTertiary, lineWidth: 1)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        } else {
            NWStatusDot(state)
        }
    }
}

private struct NWSidebarAccessoryView: View {
    let accessory: NWSidebarRow.Accessory

    var body: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .ask:
            Text("ASK").font(.nwMono(10, .medium)).foregroundStyle(.nw.lanternText).fixedSize()
        case .elapsed(let since, let tone):
            TimelineView(NWElapsedSchedule(start: since)) { context in
                Text(NWDuration.text(context.date.timeIntervalSince(since)))
                    .font(.nwMono(10)).foregroundStyle(color(tone)).monospacedDigit().fixedSize()
            }
        case .text(let text, let tone):
            Text(text).font(.nwMono(10)).foregroundStyle(tone.map(color) ?? .nw.textTertiary).fixedSize()
        case .shortcut(let text):
            Text(text).font(.nw(.micro, weight: .regular)).foregroundStyle(.nw.textTertiary).fixedSize()
        }
    }

    private func color(_ tone: AgentState) -> Color {
        switch tone {
        case .failed, .stuck: .nw.failed
        case .attention: .nw.lanternText
        default: .nw.textTertiary
        }
    }
}

/// A group row that discloses the rows under it (a space): chevron, name, and a trailing slot
/// for counts and a hover `+`.
public struct NWSidebarDisclosureRow<Trailing: View>: View {
    let title: String
    let expanded: Bool
    let depth: Int
    @ViewBuilder let trailing: (_ hovering: Bool) -> Trailing
    @Environment(\.nwDensity) private var density
    @State private var hovering = false

    public init(_ title: String, expanded: Bool, depth: Int = 0,
                @ViewBuilder trailing: @escaping (_ hovering: Bool) -> Trailing) {
        self.title = title
        self.expanded = expanded
        self.depth = depth
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.nw.textSecondary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(title)
                .font(density.rowTitleFont(weight: .medium))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            trailing(hovering)
        }
        .padding(.leading, NWSidebarMetrics.rowPadding + CGFloat(depth) * NWSidebarMetrics.indentStep)
        .padding(.trailing, NWSidebarMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: false, hovering: hovering)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
    }
}

/// A status line in place of a section's rows ("Unreachable · 3h", Retry).
public struct NWSidebarNoticeRow: View {
    let state: AgentState
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
    @Environment(\.nwDensity) private var density

    public init(_ state: AgentState, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.state = state
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: NWSidebarMetrics.rowGap) {
            NWSidebarDot(state: state)
            Text(text)
                .font(density.rowTitleFont())
                .foregroundStyle(.nw.textTertiary)
                .lineLimit(1)
            Spacer(minLength: NW.Space.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.nw(.ghost, size: .s))
            }
        }
        .padding(.horizontal, NWSidebarMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The footer row under the tree ("Automations 1"): an icon, a title, and a count badge. A
/// button: it discloses the rows it summarizes.
public struct NWSidebarFooter: View {
    let title: String
    let systemImage: String
    let count: Int
    let tone: NWCountBadge.Tone
    let expanded: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String, count: Int, tone: NWCountBadge.Tone = .neutral,
                expanded: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.tone = tone
        self.expanded = expanded
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.nw.textSecondary)
                    .frame(width: 13)
                Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(.nw.textSecondary).lineLimit(1)
                Spacer(minLength: NW.Space.xs)
                NWCountBadge(count, tone: tone)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, NW.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(NWPlainPressStyle())
        .overlay(alignment: .top) { NWHairline() }
        .accessibilityLabel("\(title), \(count), \(expanded ? "expanded" : "collapsed")")
    }
}

/// The 2pt drop line a reorder drag shows at a row's top or bottom edge.
public struct NWDropIndicator: View {
    public init() {}

    public var body: some View {
        Rectangle().fill(Color.nw.running).frame(height: 2).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A plain button that dims while pressed and draws the focus ring; for rows and fields that
/// carry their own chrome.
struct NWPlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .nwFocusRing(radius: NW.Radius.s)
    }
}

extension View {
    /// Drags the window from this view's empty area (a title bar region). No-op off macOS.
    @ViewBuilder func nwWindowDrag() -> some View {
        #if os(macOS)
        gesture(WindowDragGesture())
        #else
        self
        #endif
    }
}
