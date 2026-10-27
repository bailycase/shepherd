import SwiftUI

// The subagent tray (SubagentTray, SHAgents boards): subagents dock above the composer while
// they run, one row each, and share one card with Up next (`SHDockStack`). A row steers, stops
// or opens its run; a run that asked its parent a question only says so, quietly: the user is
// never asked by a subagent. The thread keeps two lines for them (`SHSubagentRecordLine`).
// The app hands every value in, derived once per change.

/// The tray's three sizes: the Mac's pointer rows, and touch rows on iPad and iPhone
/// (SubagentTray › iPad and iPhone).
public enum SHSubagentTraySize: Sendable {
    case pointer, pad, phone

    var metrics: SHSubagentTrayMetrics {
        switch self {
        case .pointer: .pointer
        case .pad: .pad
        case .phone: .phone
        }
    }
}

public struct SHSubagentTrayMetrics: Sendable {
    public var headerHeight: CGFloat
    public var headerLeading: CGFloat
    public var headerTrailing: CGFloat
    public var headerGlyph: CGFloat
    public var titleSize: CGFloat
    public var headerButton: CGFloat
    public var rowHeight: CGFloat
    public var rowSpacing: CGFloat
    public var rowLeading: CGFloat
    public var rowTrailing: CGFloat
    /// The state's slot: a 7pt dot, or the finished glyph.
    public var stateSlot: CGFloat
    public var nameWidth: CGFloat
    public var nameSize: CGFloat
    public var textSize: CGFloat
    public var subjectSize: CGFloat
    /// The trailing slot: the chevron, or one hover action.
    public var trailingSlot: CGFloat
    /// The diff stat shows (it drops on a phone).
    public var showsDiff: Bool
    public var cardRadius: CGFloat

    public static let pointer = SHSubagentTrayMetrics(
        headerHeight: 32, headerLeading: SH.Space.l, headerTrailing: SH.Space.s, headerGlyph: 12, titleSize: 12,
        headerButton: SH.Height.controlS, rowHeight: 36, rowSpacing: 9, rowLeading: SH.Space.l, rowTrailing: SH.Space.s,
        stateSlot: 13, nameWidth: 72, nameSize: 12, textSize: 12.5, subjectSize: 11.5, trailingSlot: SH.Height.controlS,
        showsDiff: true, cardRadius: SH.Radius.m)
    public static let pad = SHSubagentTrayMetrics(
        headerHeight: 40, headerLeading: 14, headerTrailing: SH.Space.xs, headerGlyph: 13, titleSize: 13,
        headerButton: 34, rowHeight: SH.Height.touch, rowSpacing: 10, rowLeading: 14, rowTrailing: SH.Space.xs,
        stateSlot: 14, nameWidth: 80, nameSize: 13, textSize: 13.5, subjectSize: 12.5, trailingSlot: 34,
        showsDiff: true, cardRadius: SH.Radius.l)
    public static let phone = SHSubagentTrayMetrics(
        headerHeight: 38, headerLeading: 14, headerTrailing: SH.Space.xs, headerGlyph: 13, titleSize: 13,
        headerButton: 34, rowHeight: SH.Height.touch, rowSpacing: 10, rowLeading: 14, rowTrailing: SH.Space.xs,
        stateSlot: 14, nameWidth: 68, nameSize: 13.5, textSize: 14, subjectSize: 13, trailingSlot: 34,
        showsDiff: false, cardRadius: SH.Radius.l)

    /// The state cells in the header.
    public static let cellSize: CGFloat = 6
    public static let cellRadius: CGFloat = 2
    public static let cellSpacing: CGFloat = 2
    public static let dotSize: CGFloat = 7
    /// A finished row's chevron.
    public static let chevron: CGFloat = 10
    /// "Show N more" starts under the names.
    public static let moreHeight: CGFloat = 30
    public static let moreLeading: CGFloat = 34
    /// The selected row's rule on its leading edge.
    public static let selectionRule: CGFloat = 2
}

// MARK: Values

/// One run's row, as the app derives it.
public struct SHSubagentTrayRun: Equatable, Identifiable, Sendable {
    public enum Line: Equatable, Sendable {
        /// What a live run is doing: the verb, then what it acts on in mono. `live` while its call
        /// runs: the words shimmer.
        case working(verb: String, subject: String?, live: Bool)
        /// Queued, or paused before its next model request.
        case waiting(String)
        /// The question it put to its parent, which answers it or asks the user: "asked the
        /// parent: <question>", or "asked the parent" when it gave none.
        case asked(String)
        /// What it did.
        case result(String)
        /// Why it failed.
        case failed(String)
    }

    public var id: String
    public var name: String
    public var role: String?
    public var state: AgentState
    public var line: Line
    public var added: Int?
    public var removed: Int?
    /// The figure: live from `since`, or `until − since` once finished; none without `since`.
    public var since: Date?
    public var until: Date?
    public var accessibilityLabel: String

    public init(id: String, name: String, role: String? = nil, state: AgentState, line: Line, added: Int? = nil, removed: Int? = nil,
                since: Date? = nil, until: Date? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.state = state
        self.line = line
        self.added = added
        self.removed = removed
        self.since = since
        self.until = until
        self.accessibilityLabel = accessibilityLabel ?? name
    }

    /// Still going: it can be steered and stopped (a run waiting on its parent draws as queued).
    public var isLive: Bool { state == .running || state == .queued }
}

/// The header: "3 subagents", a cell per run, and the tally.
public struct SHSubagentTraySummary: Equatable, Sendable {
    public struct Part: Equatable, Sendable, Identifiable {
        public var id: String { text }
        public var text: String
        /// The part's color; nil is the quiet tertiary.
        public var state: AgentState?

        public init(_ text: String, state: AgentState? = nil) {
            self.text = text
            self.state = state
        }
    }

    public var title: String
    public var cells: [AgentState]
    public var tally: [Part]

    public init(title: String, cells: [AgentState], tally: [Part]) {
        self.title = title
        self.cells = cells
        self.tally = tally
    }

    /// "3 subagents, 1 running, 1 waiting on parent, 1 done"
    public var accessibilityLabel: String { ([title] + tally.map(\.text)).joined(separator: ", ") }
}

/// What a row's controls do. nil hides a control. `steerLabel` names the Steer control for
/// VoiceOver ("Steer worker"; "Reply to worker" on a run that asked its parent) and `steerHelp`
/// is its tooltip, which a Reply spells out; nil keeps "Steer <name>" and a tooltip that is the label.
public struct SHSubagentTrayActions {
    public var open: () -> Void
    public var steer: (() -> Void)?
    public var steerLabel: String?
    public var steerHelp: String?
    public var stop: (() -> Void)?

    public init(open: @escaping () -> Void, steer: (() -> Void)? = nil, steerLabel: String? = nil, steerHelp: String? = nil,
                stop: (() -> Void)? = nil) {
        self.open = open
        self.steer = steer
        self.steerLabel = steerLabel
        self.steerHelp = steerHelp
        self.stop = stop
    }
}

// MARK: Tray

/// The tray's section of the dock: its header, then its rows (each draws the hairline above
/// it, so a long list can sit in a lazy stack). Collapsed it is the header alone, whose cells
/// and tally still say what is running and what waits.
public struct SHSubagentTray<Rows: View>: View {
    let summary: SHSubagentTraySummary
    let size: SHSubagentTraySize
    let collapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let rows: () -> Rows

    public init(_ summary: SHSubagentTraySummary, size: SHSubagentTraySize = .pointer, collapsed: Bool,
                onToggle: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        self.summary = summary
        self.size = size
        self.collapsed = collapsed
        self.onToggle = onToggle
        self.rows = rows
    }

    public var body: some View {
        VStack(spacing: 0) {
            SHSubagentTrayHeader(summary, size: size, collapsed: collapsed, onToggle: onToggle)
            if !collapsed {
                rows().shTransition(.disclosure)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "3 subagents", its cells, "1 running · 1 waiting on parent · 1 done", and Collapse.
public struct SHSubagentTrayHeader: View {
    let summary: SHSubagentTraySummary
    let size: SHSubagentTraySize
    let collapsed: Bool
    let onToggle: () -> Void

    public init(_ summary: SHSubagentTraySummary, size: SHSubagentTraySize = .pointer, collapsed: Bool, onToggle: @escaping () -> Void) {
        self.summary = summary
        self.size = size
        self.collapsed = collapsed
        self.onToggle = onToggle
    }

    public var body: some View {
        let sh = Color.sh
        let m = size.metrics
        HStack(spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                SHBranchGlyph(.idle, size: m.headerGlyph, color: sh.textTertiary)
                Text(summary.title).font(.shSans(m.titleSize, .semibold)).foregroundStyle(sh.textSecondary)
                    .lineLimit(1).fixedSize()
                    .shContentTransition(.numeric())
                HStack(spacing: SHSubagentTrayMetrics.cellSpacing) {
                    ForEach(Array(summary.cells.enumerated()), id: \.offset) { _, state in
                        RoundedRectangle(cornerRadius: SHSubagentTrayMetrics.cellRadius)
                            .fill(state.isHollow ? sh.lineStrong : state.color)
                            .frame(width: SHSubagentTrayMetrics.cellSize, height: SHSubagentTrayMetrics.cellSize)
                    }
                }
                .fixedSize()
                tally.lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.m)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .shComponentAnimation(.disclosure, value: collapsed)
            }
            .buttonStyle(.shIcon(size: m.headerButton))
            .help(collapsed ? "Show the subagents" : "Collapse the subagents")
            .accessibilityLabel(collapsed ? "Show the subagents" : "Collapse the subagents")
        }
        .shComponentAnimation(.content, value: summary)
        .padding(.leading, m.headerLeading)
        .padding(.trailing, m.headerTrailing)
        .frame(height: m.headerHeight)
    }

    private var tally: Text {
        let sh = Color.sh
        var text = Text("")
        for (index, part) in summary.tally.enumerated() {
            if index > 0 { text = text + Text(" · ").foregroundColor(sh.textTertiary) }
            let color: Color = part.state?.color ?? sh.textTertiary
            text = text + Text(part.text).foregroundColor(color)
        }
        return text.font(.shMono(11)).monospacedDigit()
    }
}

/// One run: its state, name, what it is doing (or asked its parent, or did), its diff and time,
/// then Steer · Stop · Open while the pointer is over a live run, else a chevron. The whole row
/// opens the run in the inspector; the open row wears the selection.
public struct SHSubagentTrayRow: View {
    let run: SHSubagentTrayRun
    let size: SHSubagentTraySize
    let selected: Bool
    let enabled: Bool
    let actions: SHSubagentTrayActions
    @State private var hovering: Bool

    /// `hovering` seeds the pointer state (previews); `enabled` is whether the run takes
    /// commands (its thread is on screen and its host controls subagents).
    public init(_ run: SHSubagentTrayRun, size: SHSubagentTraySize = .pointer, selected: Bool = false, enabled: Bool = true,
                hovering: Bool = false, actions: SHSubagentTrayActions) {
        self.run = run
        self.size = size
        self.selected = selected
        self.enabled = enabled
        self.actions = actions
        _hovering = State(initialValue: hovering)
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("tray.row")
        let sh = Color.sh
        let m = size.metrics
        HStack(spacing: m.rowSpacing) {
            stateMark(m)
            if let role = run.role {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(run.name).font(.shMono(m.nameSize, .semibold)).foregroundStyle(sh.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(run.name)
                    HStack(spacing: SH.Space.s) {
                        Text(role).font(.shMono(m.subjectSize)).foregroundStyle(sh.textTertiary)
                            .lineLimit(1)
                        line(m)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SH.Space.xs)
            } else {
                Text(run.name).font(.shMono(m.nameSize, .semibold)).foregroundStyle(sh.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: m.nameWidth, alignment: .leading)
                line(m).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: SH.Space.m) {
                if m.showsDiff, let added = run.added, let removed = run.removed {
                    SHDiffStat(added: added, removed: removed, font: .shMono(11))
                }
                if let since = run.since {
                    SHElapsedText(since: since, until: run.until).font(.shMono(11)).foregroundStyle(sh.textTertiary).fixedSize()
                }
            }
            trailing(m)
        }
        .padding(.leading, m.rowLeading)
        .padding(.trailing, m.rowTrailing)
        .frame(minHeight: m.rowHeight)
        .background { background(sh) }
        .overlay(alignment: .top) { SHHairline() }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.open)
        .onHover { inside in if hovering != inside { hovering = inside } }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // A tap gesture has no AXPress: the default action is the open, as a Button's would be, and
        // the action menu still lists Open first, before the row's Steer, Pause and Stop.
        .accessibilityAction { actions.open() }
        .accessibilityAction(named: "Open") { actions.open() }
        .accessibilityHint("Opens the run")
    }

    @ViewBuilder private func stateMark(_ m: SHSubagentTrayMetrics) -> some View {
        SHSubagentStateMark(run.state, slot: m.stateSlot)
    }

    @ViewBuilder private func line(_ m: SHSubagentTrayMetrics) -> some View {
        let sh = Color.sh
        switch run.line {
        case .working(let verb, let subject, let live):
            // One run of text, so the verb and its subject truncate together at the tail.
            let verbText = Text(verb).font(.shSans(m.textSize)).foregroundStyle(sh.textSecondary)
            Group {
                if let subject {
                    Text("\(verbText) \(Text(subject).font(.shMono(m.subjectSize)).foregroundStyle(sh.textPrimary))")
                } else {
                    verbText
                }
            }
            .lineLimit(1).truncationMode(.tail)
            // The words shimmer while the call runs, as the thread's live line does (LiveText).
            .shShimmer(active: live)
        case .waiting(let text), .result(let text):
            Text(text).font(.shSans(m.textSize)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.tail)
        case .asked(let question):
            Text(question.isEmpty ? "asked the parent" : "asked the parent: " + question)
                .font(.shSans(m.textSize)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.tail)
        case .failed(let reason):
            Text(reason).font(.shSans(m.textSize)).foregroundStyle(sh.failed).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private func trailing(_ m: SHSubagentTrayMetrics) -> some View {
        if size == .pointer, hovering, run.isLive {
            HStack(spacing: SH.Space.xxs) {
                if let steer = actions.steer {
                    icon("arrow.turn.down.right", actions.steerLabel ?? "Steer \(run.name)", m, help: actions.steerHelp, action: steer)
                }
                if let stop = actions.stop {
                    icon("stop.fill", "Stop \(run.name)", m, action: stop, small: true)
                }
                icon("chevron.right", "Open \(run.name)", m, action: actions.open)
            }
            .disabled(!enabled)
            .shTransition(.hover)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: SHSubagentTrayMetrics.chevron - 1, weight: .semibold))
                .foregroundStyle(Color.sh.textTertiary)
                .frame(width: m.trailingSlot)
                .accessibilityHidden(true)
        }
    }

    private func icon(_ symbol: String, _ label: String, _ m: SHSubagentTrayMetrics, help: String? = nil,
                      action: @escaping () -> Void, small: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol).imageScale(small ? .small : .medium)
        }
        .buttonStyle(.shIcon(size: m.trailingSlot))
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func background(_ sh: SHPalette) -> some View {
        let fill: Color = selected ? sh.bgSelected : hovering ? sh.bgHover : .clear
        fill.overlay(alignment: .leading) {
            if selected {
                sh.running.frame(width: SHSubagentTrayMetrics.selectionRule)
            }
        }
    }
}

/// A run's state in its slot: a 7pt dot, or a `done` checkmark or a `failed` cross once finished
/// (the tray's rows and the Subagents tab's).
struct SHSubagentStateMark: View {
    let state: AgentState
    let slot: CGFloat
    /// The mark's own width, where a design gives it one narrower than the slot (the list's 7pt dot).
    let width: CGFloat
    /// The finished glyphs' base size, where a design draws them larger than the tray's (the list's).
    let glyph: CGFloat?

    init(_ state: AgentState, slot: CGFloat, width: CGFloat? = nil, glyph: CGFloat? = nil) {
        self.state = state
        self.slot = slot
        self.width = width ?? slot
        self.glyph = glyph
    }

    var body: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: glyph ?? slot - 4, weight: .semibold)).foregroundStyle(Color.sh.done)
            case .failed:
                Image(systemName: "xmark").font(.system(size: glyph ?? slot - 5, weight: .semibold)).foregroundStyle(Color.sh.failed)
            default:
                SHStatusDot(state, size: SHSubagentTrayMetrics.dotSize)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

/// "Show 4 more" under the first rows of a long tray, "Show fewer" once open.
public struct SHSubagentTrayMoreRow: View {
    let hidden: Int
    let expanded: Bool
    let action: () -> Void

    public init(hidden: Int, expanded: Bool, action: @escaping () -> Void) {
        self.hidden = hidden
        self.expanded = expanded
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(expanded ? "Show fewer" : "Show \(hidden) more")
                .font(.shSans(12)).foregroundStyle(Color.sh.textSecondary)
                .frame(maxWidth: .infinity, minHeight: SHSubagentTrayMetrics.moreHeight, alignment: .leading)
                .padding(.leading, SHSubagentTrayMetrics.moreLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { SHHairline() }
    }
}

// MARK: The dock

/// The card above the composer (SHDockStack on SHAgents; SubagentsQueue): the subagents, then
/// Up next, in one card with one border; a `lineStrong` rule parts the two when both show.
/// Each section draws only its contents (`SHQueueStack(framed: false)`,
/// `SHTouchQueueCard(framed: false)`); the card rounds the tray's corners and leaves the
/// queue's to it, so a lifted queue row can still float past the card's edges.
public struct SHDockStack<Tray: View, Queue: View>: View {
    let size: SHSubagentTraySize
    let showsTray: Bool
    let showsQueue: Bool
    @ViewBuilder let tray: () -> Tray
    @ViewBuilder let queue: () -> Queue

    public init(size: SHSubagentTraySize = .pointer, showsTray: Bool, showsQueue: Bool,
                @ViewBuilder tray: @escaping () -> Tray, @ViewBuilder queue: @escaping () -> Queue) {
        self.size = size
        self.showsTray = showsTray
        self.showsQueue = showsQueue
        self.tray = tray
        self.queue = queue
    }

    public var body: some View {
        let sh = Color.sh
        let radius = size.metrics.cardRadius
        VStack(spacing: 0) {
            if showsTray {
                tray()
                    .clipShape(UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                        topLeading: radius, bottomLeading: showsQueue ? 0 : radius,
                        bottomTrailing: showsQueue ? 0 : radius, topTrailing: radius)))
            }
            if showsQueue {
                queue()
                    .overlay(alignment: .top) {
                        if showsTray { SHHairline(color: sh.lineStrong) }
                    }
            }
        }
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: radius))
        .shBorder(sh.lineStrong, radius: radius)
    }
}

// MARK: The thread's record

/// A line the thread keeps for a turn's subagents (SubagentRecord): "Started 3 subagents ·
/// worker · reviewer · tests" where they started, "3 subagents finished · 45m · 7 files · +318
/// −64" where they finished. An activity line in look; it opens the runs in the inspector.
public struct SHSubagentRecordLine: View {
    let title: String
    let meta: String
    let action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, meta: String, action: (() -> Void)?) {
        self.title = title
        self.meta = meta
        self.action = action
    }

    /// A real button only when there is a run to open; otherwise its words alone (no hover,
    /// press, or focus, and VoiceOver hears no button).
    public var body: some View {
        let spoken = [title, meta].filter { !$0.isEmpty }.joined(separator: ", ")
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.shRow())
                    .accessibilityLabel(spoken)
                    .accessibilityHint("Opens the subagents")
            } else {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }
        }
        .padding(.leading, -SH.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            SHBranchGlyph(.idle, size: SHThreadMetrics.activityIcon, color: sh.textTertiary)
            Text(title)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                .layoutPriority(1)
            if !meta.isEmpty {
                Text(meta).font(.shMono(11)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.tail).monospacedDigit()
            }
            // Only a line that opens something wears the chevron; its place stays.
            Image(systemName: "chevron.right")
                .font(.system(size: SHSubagentTrayMetrics.chevron - 1, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .opacity(action == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.leading, SH.Space.xs)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: SHThreadMetrics.activityHeight)
    }
}

