import SwiftUI

// The subagent tray (SubagentTray, NWAgents boards): subagents dock above the composer while
// they run, one row each, and share one card with Up next (`NWDockStack`). A row answers,
// steers, stops or opens its run; the thread keeps two lines for them (`NWSubagentRecordLine`).
// The app hands every value in, derived once per change.

/// The tray's three sizes: the Mac's pointer rows, and touch rows on iPad and iPhone
/// (SubagentTray › iPad and iPhone).
public enum NWSubagentTraySize: Sendable {
    case pointer, pad, phone

    var metrics: NWSubagentTrayMetrics {
        switch self {
        case .pointer: .pointer
        case .pad: .pad
        case .phone: .phone
        }
    }
}

public struct NWSubagentTrayMetrics: Sendable {
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

    public static let pointer = NWSubagentTrayMetrics(
        headerHeight: 32, headerLeading: NW.Space.l, headerTrailing: NW.Space.s, headerGlyph: 12, titleSize: 12,
        headerButton: NW.Height.controlS, rowHeight: 36, rowSpacing: 9, rowLeading: NW.Space.l, rowTrailing: NW.Space.s,
        stateSlot: 13, nameWidth: 72, nameSize: 12, textSize: 12.5, subjectSize: 11.5, trailingSlot: NW.Height.controlS,
        showsDiff: true, cardRadius: NW.Radius.m)
    public static let pad = NWSubagentTrayMetrics(
        headerHeight: 40, headerLeading: 14, headerTrailing: NW.Space.xs, headerGlyph: 13, titleSize: 13,
        headerButton: 34, rowHeight: NW.Height.touch, rowSpacing: 10, rowLeading: 14, rowTrailing: NW.Space.xs,
        stateSlot: 14, nameWidth: 80, nameSize: 13, textSize: 13.5, subjectSize: 12.5, trailingSlot: 34,
        showsDiff: true, cardRadius: NW.Radius.l)
    public static let phone = NWSubagentTrayMetrics(
        headerHeight: 38, headerLeading: 14, headerTrailing: NW.Space.xs, headerGlyph: 13, titleSize: 13,
        headerButton: 34, rowHeight: NW.Height.touch, rowSpacing: 10, rowLeading: 14, rowTrailing: NW.Space.xs,
        stateSlot: 14, nameWidth: 68, nameSize: 13.5, textSize: 14, subjectSize: 13, trailingSlot: 34,
        showsDiff: false, cardRadius: NW.Radius.l)

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
public struct NWSubagentTrayRun: Equatable, Identifiable, Sendable {
    public enum Line: Equatable, Sendable {
        /// What a live run is doing: the verb, then what it acts on in mono. `live` while its call
        /// runs: the words shimmer.
        case working(verb: String, subject: String?, live: Bool)
        /// Queued, or paused before its next model request.
        case waiting(String)
        /// Its question, after "asks: ".
        case asks(String)
        /// What it did.
        case result(String)
        /// Why it failed.
        case failed(String)
    }

    public var id: String
    public var name: String
    public var state: AgentState
    public var line: Line
    public var added: Int?
    public var removed: Int?
    /// The figure: live from `since`, or `until − since` once finished; none without `since`.
    public var since: Date?
    public var until: Date?
    public var accessibilityLabel: String

    public init(id: String, name: String, state: AgentState, line: Line, added: Int? = nil, removed: Int? = nil,
                since: Date? = nil, until: Date? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.line = line
        self.added = added
        self.removed = removed
        self.since = since
        self.until = until
        self.accessibilityLabel = accessibilityLabel ?? name
    }

    /// Still going: it can be steered and stopped.
    public var isLive: Bool { state == .running || state == .queued || state == .attention }
}

/// The header: "3 subagents", a cell per run, and the tally.
public struct NWSubagentTraySummary: Equatable, Sendable {
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

    /// "3 subagents, 1 needs you, 1 running, 1 done"
    public var accessibilityLabel: String { ([title] + tally.map(\.text)).joined(separator: ", ") }
}

/// What a row's controls do. nil hides a control.
public struct NWSubagentTrayActions {
    public var open: () -> Void
    public var answer: (() -> Void)?
    public var steer: (() -> Void)?
    public var stop: (() -> Void)?

    public init(open: @escaping () -> Void, answer: (() -> Void)? = nil, steer: (() -> Void)? = nil, stop: (() -> Void)? = nil) {
        self.open = open
        self.answer = answer
        self.steer = steer
        self.stop = stop
    }
}

// MARK: Tray

/// The tray's section of the dock: its header, then its rows (each draws the hairline above
/// it, so a long list can sit in a lazy stack). Collapsed it is the header alone, whose cells
/// and tally still say who needs you.
public struct NWSubagentTray<Rows: View>: View {
    let summary: NWSubagentTraySummary
    let size: NWSubagentTraySize
    let collapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let rows: () -> Rows

    public init(_ summary: NWSubagentTraySummary, size: NWSubagentTraySize = .pointer, collapsed: Bool,
                onToggle: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows) {
        self.summary = summary
        self.size = size
        self.collapsed = collapsed
        self.onToggle = onToggle
        self.rows = rows
    }

    public var body: some View {
        VStack(spacing: 0) {
            NWSubagentTrayHeader(summary, size: size, collapsed: collapsed, onToggle: onToggle)
            if !collapsed {
                rows().nwTransition(.disclosure)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "3 subagents", its cells, "1 needs you · 1 running · 1 done", and Collapse.
public struct NWSubagentTrayHeader: View {
    let summary: NWSubagentTraySummary
    let size: NWSubagentTraySize
    let collapsed: Bool
    let onToggle: () -> Void

    public init(_ summary: NWSubagentTraySummary, size: NWSubagentTraySize = .pointer, collapsed: Bool, onToggle: @escaping () -> Void) {
        self.summary = summary
        self.size = size
        self.collapsed = collapsed
        self.onToggle = onToggle
    }

    public var body: some View {
        let nw = Color.nw
        let m = size.metrics
        HStack(spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                NWBranchGlyph(.idle, size: m.headerGlyph, color: nw.textTertiary)
                Text(summary.title).font(.nwSans(m.titleSize, .semibold)).foregroundStyle(nw.textSecondary)
                    .lineLimit(1).fixedSize()
                    .nwContentTransition(.numeric())
                HStack(spacing: NWSubagentTrayMetrics.cellSpacing) {
                    ForEach(Array(summary.cells.enumerated()), id: \.offset) { _, state in
                        RoundedRectangle(cornerRadius: NWSubagentTrayMetrics.cellRadius)
                            .fill(state.isHollow ? nw.lineStrong : state.color)
                            .frame(width: NWSubagentTrayMetrics.cellSize, height: NWSubagentTrayMetrics.cellSize)
                    }
                }
                .fixedSize()
                tally.lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.m)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .nwComponentAnimation(.disclosure, value: collapsed)
            }
            .buttonStyle(.nwIcon(size: m.headerButton))
            .help(collapsed ? "Show the subagents" : "Collapse the subagents")
            .accessibilityLabel(collapsed ? "Show the subagents" : "Collapse the subagents")
        }
        .nwComponentAnimation(.content, value: summary)
        .padding(.leading, m.headerLeading)
        .padding(.trailing, m.headerTrailing)
        .frame(height: m.headerHeight)
    }

    private var tally: Text {
        let nw = Color.nw
        var text = Text("")
        for (index, part) in summary.tally.enumerated() {
            if index > 0 { text = text + Text(" · ").foregroundColor(nw.textTertiary) }
            let color: Color = switch part.state {
            case .attention: nw.lanternText
            case .some(let state): state.color
            case nil: nw.textTertiary
            }
            text = text + Text(part.text).foregroundColor(color)
        }
        return text.font(.nwMono(11)).monospacedDigit()
    }
}

/// One run: its state, name, what it is doing (or asks, or did), its diff and time, then
/// Answer for a question, Steer · Stop · Open while the pointer is over a live run, else a
/// chevron. The whole row opens the run in the inspector; the open row wears the selection.
public struct NWSubagentTrayRow: View {
    let run: NWSubagentTrayRun
    let size: NWSubagentTraySize
    let selected: Bool
    let enabled: Bool
    let actions: NWSubagentTrayActions
    @State private var hovering: Bool

    /// `hovering` seeds the pointer state (previews); `enabled` is whether the run takes
    /// commands (its thread is on screen and its host controls subagents).
    public init(_ run: NWSubagentTrayRun, size: NWSubagentTraySize = .pointer, selected: Bool = false, enabled: Bool = true,
                hovering: Bool = false, actions: NWSubagentTrayActions) {
        self.run = run
        self.size = size
        self.selected = selected
        self.enabled = enabled
        self.actions = actions
        _hovering = State(initialValue: hovering)
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("tray.row")
        let nw = Color.nw
        let m = size.metrics
        let asks = run.state == .attention
        HStack(spacing: m.rowSpacing) {
            stateMark(m)
            Text(run.name).font(.nwMono(m.nameSize, .semibold)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: m.nameWidth, alignment: .leading)
            line(m).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NW.Space.m) {
                if m.showsDiff, let added = run.added, let removed = run.removed {
                    NWDiffStat(added: added, removed: removed, font: .nwMono(11))
                }
                if let since = run.since {
                    NWElapsedText(since: since, until: run.until).font(.nwMono(11)).foregroundStyle(nw.textTertiary).fixedSize()
                }
            }
            trailing(m, asks: asks)
        }
        .padding(.leading, m.rowLeading)
        .padding(.trailing, m.rowTrailing)
        .frame(minHeight: m.rowHeight)
        .background { background(nw, asks: asks) }
        .overlay(alignment: .top) { NWHairline() }
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.open)
        .onHover { inside in if hovering != inside { hovering = inside } }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { actions.open() }
    }

    @ViewBuilder private func stateMark(_ m: NWSubagentTrayMetrics) -> some View {
        Group {
            switch run.state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: m.stateSlot - 4, weight: .semibold)).foregroundStyle(Color.nw.done)
            case .failed:
                Image(systemName: "xmark").font(.system(size: m.stateSlot - 5, weight: .semibold)).foregroundStyle(Color.nw.failed)
            default:
                NWStatusDot(run.state, size: NWSubagentTrayMetrics.dotSize)
            }
        }
        .frame(width: m.stateSlot)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func line(_ m: NWSubagentTrayMetrics) -> some View {
        let nw = Color.nw
        switch run.line {
        case .working(let verb, let subject, let live):
            // One run of text, so the verb and its subject truncate together at the tail.
            let verbText = Text(verb).font(.nwSans(m.textSize)).foregroundStyle(nw.textSecondary)
            Group {
                if let subject {
                    Text("\(verbText) \(Text(subject).font(.nwMono(m.subjectSize)).foregroundStyle(nw.textPrimary))")
                } else {
                    verbText
                }
            }
            .lineLimit(1).truncationMode(.tail)
            // The words shimmer while the call runs, as the thread's live line does (LiveText).
            .nwShimmer(active: live)
        case .waiting(let text), .result(let text):
            Text(text).font(.nwSans(m.textSize)).foregroundStyle(nw.textSecondary).lineLimit(1).truncationMode(.tail)
        case .asks(let question):
            Text("asks: " + question).font(.nwSans(m.textSize)).foregroundStyle(nw.lanternText).lineLimit(1).truncationMode(.tail)
        case .failed(let reason):
            Text(reason).font(.nwSans(m.textSize)).foregroundStyle(nw.failed).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private func trailing(_ m: NWSubagentTrayMetrics, asks: Bool) -> some View {
        if asks, !selected, let answer = actions.answer {
            Button("Answer", action: answer)
                .buttonStyle(.nw(.primary, size: size == .pointer ? .s : .m))
                .disabled(!enabled)
        } else if size == .pointer, hovering, run.isLive, !asks {
            HStack(spacing: NW.Space.xxs) {
                if let steer = actions.steer {
                    icon("arrow.turn.down.right", "Steer \(run.name)", m, action: steer)
                }
                if let stop = actions.stop {
                    icon("stop.fill", "Stop \(run.name)", m, action: stop, small: true)
                }
                icon("chevron.right", "Open \(run.name)", m, action: actions.open)
            }
            .disabled(!enabled)
            .nwTransition(.hover)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: NWSubagentTrayMetrics.chevron - 1, weight: .semibold))
                .foregroundStyle(Color.nw.textTertiary)
                .frame(width: m.trailingSlot)
                .accessibilityHidden(true)
        }
    }

    private func icon(_ symbol: String, _ label: String, _ m: NWSubagentTrayMetrics, action: @escaping () -> Void,
                      small: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol).imageScale(small ? .small : .medium)
        }
        .buttonStyle(.nwIcon(size: m.trailingSlot))
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func background(_ nw: NWPalette, asks: Bool) -> some View {
        let fill: Color = asks ? nw.lanternTint : selected ? nw.bgSelected : hovering ? nw.bgHover : .clear
        fill.overlay(alignment: .leading) {
            if selected {
                (asks ? nw.lantern : nw.running).frame(width: NWSubagentTrayMetrics.selectionRule)
            }
        }
    }
}

/// "Show 4 more" under the first rows of a long tray, "Show fewer" once open.
public struct NWSubagentTrayMoreRow: View {
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
                .font(.nwSans(12)).foregroundStyle(Color.nw.textSecondary)
                .frame(maxWidth: .infinity, minHeight: NWSubagentTrayMetrics.moreHeight, alignment: .leading)
                .padding(.leading, NWSubagentTrayMetrics.moreLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { NWHairline() }
    }
}

// MARK: The dock

/// The card above the composer (NWDockStack on NWAgents; SubagentsQueue): the subagents, then
/// Up next, in one card with one border; a `lineStrong` rule parts the two when both show.
/// Each section draws only its contents (`NWQueueStack(framed: false)`,
/// `NWTouchQueueCard(framed: false)`); the card rounds the tray's corners and leaves the
/// queue's to it, so a lifted queue row can still float past the card's edges.
public struct NWDockStack<Tray: View, Queue: View>: View {
    let size: NWSubagentTraySize
    let showsTray: Bool
    let showsQueue: Bool
    @ViewBuilder let tray: () -> Tray
    @ViewBuilder let queue: () -> Queue

    public init(size: NWSubagentTraySize = .pointer, showsTray: Bool, showsQueue: Bool,
                @ViewBuilder tray: @escaping () -> Tray, @ViewBuilder queue: @escaping () -> Queue) {
        self.size = size
        self.showsTray = showsTray
        self.showsQueue = showsQueue
        self.tray = tray
        self.queue = queue
    }

    public var body: some View {
        let nw = Color.nw
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
                        if showsTray { NWHairline(color: nw.lineStrong) }
                    }
            }
        }
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: radius))
        .nwBorder(nw.lineStrong, radius: radius)
    }
}

// MARK: The thread's record

/// A line the thread keeps for a turn's subagents (SubagentRecord): "Started 3 subagents ·
/// worker · reviewer · tests" where they started, "3 subagents finished · 45m · 7 files · +318
/// −64" where they finished. An activity line in look; it opens the runs in the inspector.
public struct NWSubagentRecordLine: View {
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
                    .buttonStyle(.nwRow())
                    .accessibilityLabel(spoken)
                    .accessibilityHint("Opens the subagents")
            } else {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }
        }
        .padding(.leading, -NW.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            NWBranchGlyph(.idle, size: NWThreadMetrics.activityIcon, color: nw.textTertiary)
            Text(title)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                .layoutPriority(1)
            if !meta.isEmpty {
                Text(meta).font(.nwMono(11)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.tail).monospacedDigit()
            }
            // Only a line that opens something wears the chevron; its place stays.
            Image(systemName: "chevron.right")
                .font(.system(size: NWSubagentTrayMetrics.chevron - 1, weight: .semibold))
                .foregroundStyle(nw.textTertiary)
                .opacity(action == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.leading, NW.Space.xs)
        .padding(.trailing, NW.Space.m)
        .frame(minHeight: NWThreadMetrics.activityHeight)
    }
}

