import SwiftUI

// The Mac's Automations page (NavAutomations): a table row with its switch, what it starts,
// its host and how its last run went, and a run in the detail pane's history. Plain values in;
// what a switch or a row does is the caller's.

/// How an automation's last run reads in a table or history row.
public struct NWRunOutcome: Equatable, Sendable {
    public var text: String
    /// Colors the dot and the words; nil is quiet (stopped, off, host offline): a hollow
    /// `textTertiary` dot and `textTertiary` words.
    public var state: AgentState?
    /// A live run counts up; a finished one says how long ago it moved.
    public var clock: NWRowClock?

    public init(_ text: String, state: AgentState? = nil, clock: NWRowClock? = nil) {
        self.text = text
        self.state = state
        self.clock = clock
    }
}

/// The outcome's dot and words ("finished · 6h ago" in `done`, "asked you · 1h ago" in
/// `lanternText` with a glowing dot, "host offline" quiet).
public struct NWRunOutcomeLabel: View, Equatable {
    let outcome: NWRunOutcome

    public init(_ outcome: NWRunOutcome) { self.outcome = outcome }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            if let state = outcome.state {
                NWStatusDot(state, size: NWPageMetrics.dot)
            } else {
                Circle().strokeBorder(Color.nw.textTertiary, lineWidth: 1)
                    .frame(width: NWPageMetrics.dot, height: NWPageMetrics.dot)
                    .accessibilityHidden(true)
            }
            words
                .font(.nwSans(12))
                .foregroundStyle(outcome.state?.textColor ?? Color.nw.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var words: some View {
        switch outcome.clock {
        case .none:
            Text(outcome.text)
        case .elapsed(let since)?:
            TimelineView(NWElapsedSchedule(start: since)) { context in
                Text(outcome.text + " · " + NWDuration.text(context.date.timeIntervalSince(since)))
            }
        case .ago(let at)?:
            TimelineView(NWElapsedSchedule(start: at)) { context in
                Text(outcome.text + " · " + NWDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }
}

/// One automation in the page's table: its switch and name, what each run starts (a thread),
/// its host, and its last run, on the table's columns. The row selects on a click (its detail
/// shows beside the table); the switch turns it on or off without selecting it.
public struct NWAutomationTableRow: View, Equatable {
    let name: String
    let isOn: Bool
    let switchEnabled: Bool
    let starts: String
    let host: String
    let outcome: NWRunOutcome?
    let selected: Bool
    let columns: [NWTableColumns.Column]
    let toggle: ((Bool) -> Void)?
    /// Whether it has a switch, for `==` (closures are the main actor's).
    private let togglable: Bool
    let select: () -> Void

    public init(_ name: String, isOn: Bool, switchEnabled: Bool = true, starts: String = "thread", host: String,
                outcome: NWRunOutcome?, selected: Bool, columns: [NWTableColumns.Column],
                toggle: ((Bool) -> Void)?, select: @escaping () -> Void) {
        self.name = name
        self.isOn = isOn
        self.switchEnabled = switchEnabled
        self.starts = starts
        self.host = host
        self.outcome = outcome
        self.selected = selected
        self.columns = columns
        self.toggle = toggle
        togglable = toggle != nil
        self.select = select
    }

    public nonisolated static func == (a: NWAutomationTableRow, b: NWAutomationTableRow) -> Bool {
        a.name == b.name && a.isOn == b.isOn && a.switchEnabled == b.switchEnabled && a.starts == b.starts
            && a.host == b.host && a.outcome == b.outcome && a.selected == b.selected && a.columns == b.columns
            && a.togglable == b.togglable
    }

    public var body: some View {
        let nw = Color.nw
        // The row is a button under the cells, so a click anywhere selects and the switch
        // (above it) flips without selecting.
        ZStack {
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.nwRow(selected: selected, radius: 0))
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(selected ? .isSelected : [])
            NWTableColumns(columns) {
                HStack(spacing: NWPageMetrics.switchGap) {
                    NWAutomationSwitch(name, isOn: isOn, toggle: switchEnabled ? toggle : nil)
                    Text(name)
                        .font(.nwSans(13, .semibold))
                        .foregroundStyle(nw.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Label {
                    Text(starts).font(.nwSans(12)).foregroundStyle(nw.textSecondary).lineLimit(1)
                } icon: {
                    Image(systemName: "text.bubble")
                        .font(.nwSans(11))
                        .foregroundStyle(nw.textTertiary)
                }
                .labelStyle(NWPageCellLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                Text(host)
                    .font(.nwMono(11))
                    .foregroundStyle(nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                Group {
                    if let outcome { NWRunOutcomeLabel(outcome) } else { Color.clear.frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .padding(.horizontal, NWPageMetrics.sideInset)
            .padding(.vertical, NWPageMetrics.rowVertical)
        }
        .overlay(alignment: .top) { NWHairline() }
    }

    private var accessibilityText: String {
        [name, isOn ? "on" : "off", "on \(host)", outcome?.text].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A glyph 6pt before a cell's words.
private struct NWPageCellLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.s) {
            configuration.icon
            configuration.title
        }
    }
}

/// One run in the Automations detail's history (the boards' 28pt rows): its outcome's dot, when
/// it started in mono, what happened, and how long it took. A run whose thread still exists
/// opens it on a click.
public struct NWAutomationRunLine: View, Equatable {
    let started: String
    let word: String
    let state: AgentState?
    let duration: String?
    let open: (() -> Void)?
    /// Whether it opens a thread, for `==` (closures are the main actor's).
    private let opens: Bool

    public init(started: String, word: String, state: AgentState?, duration: String? = nil, open: (() -> Void)? = nil) {
        self.started = started
        self.word = word
        self.state = state
        self.duration = duration
        self.open = open
        opens = open != nil
    }

    public nonisolated static func == (a: NWAutomationRunLine, b: NWAutomationRunLine) -> Bool {
        a.started == b.started && a.word == b.word && a.state == b.state && a.duration == b.duration
            && a.opens == b.opens
    }

    public var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.nwRow(radius: NW.Radius.s))
                .accessibilityHint("Opens its thread")
        } else {
            content
        }
    }

    private var content: some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            if let state {
                NWStatusDot(state, size: NWPageMetrics.dot)
            } else {
                Circle().strokeBorder(nw.textTertiary, lineWidth: 1)
                    .frame(width: NWPageMetrics.dot, height: NWPageMetrics.dot)
                    .accessibilityHidden(true)
            }
            Text(started).font(.nwMono(12)).foregroundStyle(nw.textSecondary).fixedSize()
            Text(word).font(.nwSans(12)).foregroundStyle(nw.textTertiary).lineLimit(1)
            Spacer(minLength: NW.Space.s)
            if let duration {
                Text(duration).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, minHeight: NW.Height.controlM, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
