import SwiftUI

// The Mac's Automations page (NavAutomations): a table row with its switch, what it starts,
// its host and how its last run went, and a run in the detail pane's history. Plain values in;
// what a switch or a row does is the caller's.

/// How an automation's last run reads in a table or history row.
public struct SHRunOutcome: Equatable, Sendable {
    public var text: String
    /// Colors the dot and the words; nil is quiet (stopped, off, host offline): a hollow
    /// `textTertiary` dot and `textTertiary` words.
    public var state: AgentState?
    /// A live run counts up; a finished one says how long ago it moved.
    public var clock: SHRowClock?

    public init(_ text: String, state: AgentState? = nil, clock: SHRowClock? = nil) {
        self.text = text
        self.state = state
        self.clock = clock
    }
}

/// The outcome as the table's Last run draws it (NavAutomations' `.lr`): plain words, "Passed, 6h
/// ago", colored by how the run went (`textSecondary` done, `lanternText` asking, `failed`, quiet
/// `textTertiary` for stopped, off or host offline). No dot: the words carry it.
public struct SHRunOutcomeLabel: View, Equatable {
    let outcome: SHRunOutcome

    public init(_ outcome: SHRunOutcome) { self.outcome = outcome }

    public var body: some View {
        words
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var color: Color {
        switch outcome.state {
        case nil: Color.sh.textTertiary
        case .done?: Color.sh.textSecondary
        case let state?: state.textColor
        }
    }

    @ViewBuilder private var words: some View {
        switch outcome.clock {
        case .none:
            Text(outcome.text)
        case .elapsed(let since)?:
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(outcome.text + ", " + SHDuration.text(context.date.timeIntervalSince(since)))
            }
        case .ago(let at)?:
            TimelineView(SHElapsedSchedule(start: at)) { context in
                Text(outcome.text + ", " + SHDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }
}

/// The table's column labels (NavAutomations' `.ath`): 30pt, `caption` in `textTertiary`, on the rows' columns.
public struct SHAutomationHead: View {
    let labels: [String]
    let columns: [SHTableColumns.Column]

    public init(_ labels: [String], columns: [SHTableColumns.Column]) {
        self.labels = labels
        self.columns = columns
    }

    public var body: some View {
        SHTableColumns(columns, spacing: SHAutomationTableMetrics.columnGap) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SHAutomationTableMetrics.rowInset)
        .frame(height: SHAutomationTableMetrics.headHeight)
        .accessibilityHidden(true)
    }
}

/// The Automations table's own measures (NavAutomations).
public enum SHAutomationTableMetrics {
    /// A row (`.atr`): 44pt at radius 10, 12pt in, 12pt between columns.
    public static let rowHeight: CGFloat = 44
    public static let rowRadius: CGFloat = 10
    public static let rowInset: CGFloat = SH.Space.l
    public static let columnGap: CGFloat = SH.Space.l
    public static let headHeight: CGFloat = 30
    /// The switch (`.tgl`): 26×16, in a 36pt column.
    public static let switchColumn: CGFloat = 36
    /// The Host column.
    public static let hostColumn: CGFloat = 76
    /// A trigger's glyph, and its gap to the words.
    public static let triggerGlyph: CGFloat = 14
    public static let triggerGap: CGFloat = 7
    /// The columns: switch, name 1.3fr, trigger 1.5fr, host 76, last run 1.1fr.
    public static let columns: [SHTableColumns.Column] = [.fixed(switchColumn), .flex(1.3), .flex(1.5), .fixed(hostColumn), .flex(1.1)]
}

/// One automation in the page's table: its switch and name, what starts it, its host, and its
/// last run, on the table's columns. The row selects on a click (its detail shows beside the
/// table); the switch turns it on or off without selecting it.
public struct SHAutomationTableRow: View, Equatable {
    let name: String
    let isOn: Bool
    let switchEnabled: Bool
    let starts: String
    let startsGlyph: String
    /// A line under the name: how a trigger stands ("Paused · gh isn't signed in", "2 waiting"),
    /// colored by `noteState` (nil is `textTertiary`).
    let note: String?
    let noteState: AgentState?
    /// Runs finished or asking that nobody opened yet.
    let unread: Int
    let host: String
    let outcome: SHRunOutcome?
    let selected: Bool
    let toggle: ((Bool) -> Void)?
    /// Whether it has a switch, for `==` (closures are the main actor's).
    private let togglable: Bool
    let select: () -> Void

    public init(_ name: String, isOn: Bool, switchEnabled: Bool = true, starts: String = "thread",
                startsGlyph: String = "text.bubble", note: String? = nil, noteState: AgentState? = nil, unread: Int = 0,
                host: String, outcome: SHRunOutcome?, selected: Bool,
                toggle: ((Bool) -> Void)?, select: @escaping () -> Void) {
        self.name = name
        self.isOn = isOn
        self.switchEnabled = switchEnabled
        self.starts = starts
        self.startsGlyph = startsGlyph
        self.note = note
        self.noteState = noteState
        self.unread = unread
        self.host = host
        self.outcome = outcome
        self.selected = selected
        self.toggle = toggle
        togglable = toggle != nil
        self.select = select
    }

    public nonisolated static func == (a: SHAutomationTableRow, b: SHAutomationTableRow) -> Bool {
        a.name == b.name && a.isOn == b.isOn && a.switchEnabled == b.switchEnabled && a.starts == b.starts
            && a.startsGlyph == b.startsGlyph && a.note == b.note && a.noteState == b.noteState && a.unread == b.unread
            && a.host == b.host && a.outcome == b.outcome && a.selected == b.selected && a.togglable == b.togglable
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHAutomationTableMetrics.self
        // The row is a button under the cells, so a click anywhere selects and the switch
        // (above it) flips without selecting.
        ZStack {
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.shRow(selected: selected, radius: M.rowRadius))
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(selected ? .isSelected : [])
            SHTableColumns(M.columns, spacing: M.columnGap) {
                SHAutomationSwitch(name, isOn: isOn, toggle: switchEnabled ? toggle : nil)
                    .environment(\.shControlScale, .tweak)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    HStack(spacing: SH.Space.s) {
                        Text(name)
                            .font(.sh(.ui, weight: .medium))
                            .foregroundStyle(isOn ? sh.textPrimary : sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if unread > 0 { SHCountBadge(unread) }
                    }
                    if let note {
                        Text(note)
                            .font(.sh(.caption))
                            .foregroundStyle(noteState?.textColor ?? sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                HStack(spacing: M.triggerGap) {
                    Image(systemName: startsGlyph)
                        .font(.shSans(M.triggerGlyph))
                        .frame(width: M.triggerGlyph)
                        .accessibilityHidden(true)
                    Text(starts).font(.sh(.ui, weight: .regular)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(sh.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                Text(host)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                Group {
                    if let outcome { SHRunOutcomeLabel(outcome) } else { Color.clear.frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .padding(.horizontal, M.rowInset)
        }
        .frame(minHeight: M.rowHeight)
    }

    private var accessibilityText: String {
        [name, isOn ? "on" : "off", unread > 0 ? "\(unread) unread" : nil, note, starts, "on \(host)", outcome?.text]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// One run in the Automations detail's history (the boards' 28pt rows): its outcome's dot, when
/// it started in mono, what happened, and how long it took. A run whose thread still exists
/// opens it on a click.
public struct SHAutomationRunLine: View, Equatable {
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

    public nonisolated static func == (a: SHAutomationRunLine, b: SHAutomationRunLine) -> Bool {
        a.started == b.started && a.word == b.word && a.state == b.state && a.duration == b.duration
            && a.opens == b.opens
    }

    public var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.shRow(radius: SH.Radius.s))
                .accessibilityHint("Opens its thread")
        } else {
            content
        }
    }

    private var content: some View {
        let sh = Color.sh
        let M = SHAutomationDetailMetrics.self
        return HStack(spacing: M.runGap) {
            Text(started)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .lineLimit(1)
                .frame(width: M.runDateColumn, alignment: .leading)
            Text(word)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(state == .failed ? sh.failed : sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let duration {
                Text(duration).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize()
            }
        }
        .padding(.vertical, M.runVertical)
        .padding(.horizontal, M.side)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The Automations detail card's measures (NavAutomations' `.dcard`).
public enum SHAutomationDetailMetrics {
    public static let width: CGFloat = 380
    public static let radius: CGFloat = SH.Radius.xl
    /// The card's title (`.dch b`: 15 over the ramp's 13) and the menu's chevron.
    public static let titleSize: CGFloat = 15
    public static let chevron: CGFloat = 10
    public static let side: CGFloat = SH.Space.xl
    /// The header: 14 above, 2 below; its subtitle 2 under the name.
    public static let headerTop: CGFloat = 14
    public static let headerBottom: CGFloat = SH.Space.xxs
    /// A label (Prompt, Recent runs): 14 above, 6 below.
    public static let labelTop: CGFloat = 14
    public static let labelBottom: CGFloat = SH.Space.s
    /// The prompt: 10 and 12 in, radius 10, a line 1pt over the ui ramp's.
    public static let promptVertical: CGFloat = 10
    public static let promptHorizontal: CGFloat = SH.Space.l
    public static let promptRadius: CGFloat = 10
    public static let promptLineSpacing: CGFloat = 1
    /// The facts: a 76pt label column, 6 between rows, 14 above.
    public static let factLabel: CGFloat = 76
    public static let factGap: CGFloat = SH.Space.s
    /// A run: a 104pt date column, 10 between, 4 above and below.
    public static let runDateColumn: CGFloat = 104
    public static let runGap: CGFloat = 10
    public static let runVertical: CGFloat = SH.Space.xs
    /// The actions: 16 apart, 12 above, 10 below; the card ends 4 under them.
    public static let actionGap: CGFloat = SH.Space.xl
    public static let actionTop: CGFloat = SH.Space.l
    public static let actionBottom: CGFloat = 10
    public static let cardBottom: CGFloat = SH.Space.xs
    /// The glyph before Run now.
    public static let actionGlyph: CGFloat = SH.Space.l
}
