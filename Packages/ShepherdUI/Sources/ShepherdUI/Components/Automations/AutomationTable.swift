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

/// The outcome's dot and words ("finished · 6h ago" in `done`, "asked you · 1h ago" in
/// `lanternText` with a glowing dot, "host offline" quiet).
public struct SHRunOutcomeLabel: View, Equatable {
    let outcome: SHRunOutcome

    public init(_ outcome: SHRunOutcome) { self.outcome = outcome }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            if let state = outcome.state {
                SHStatusDot(state, size: SHPageMetrics.dot)
            } else {
                Circle().strokeBorder(Color.sh.textTertiary, lineWidth: 1)
                    .frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot)
                    .accessibilityHidden(true)
            }
            words
                .font(.shSans(12))
                .foregroundStyle(outcome.state?.textColor ?? Color.sh.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var words: some View {
        switch outcome.clock {
        case .none:
            Text(outcome.text)
        case .elapsed(let since)?:
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(outcome.text + " · " + SHDuration.text(context.date.timeIntervalSince(since)))
            }
        case .ago(let at)?:
            TimelineView(SHElapsedSchedule(start: at)) { context in
                Text(outcome.text + " · " + SHDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }
}

/// One automation in the page's table: its switch and name, what each run starts (a thread),
/// its host, and its last run, on the table's columns. The row selects on a click (its detail
/// shows beside the table); the switch turns it on or off without selecting it.
public struct SHAutomationTableRow: View, Equatable {
    let name: String
    let isOn: Bool
    let switchEnabled: Bool
    let starts: String
    let startsGlyph: String
    /// A line under the name: how a trigger stands ("Paused · gh isn't signed in", "2 waiting ·
    /// 4/20 today"), colored by `noteState` (nil is `textTertiary`).
    let note: String?
    let noteState: AgentState?
    /// Runs finished or asking that nobody opened yet.
    let unread: Int
    let host: String
    let outcome: SHRunOutcome?
    let selected: Bool
    let columns: [SHTableColumns.Column]
    let toggle: ((Bool) -> Void)?
    /// Whether it has a switch, for `==` (closures are the main actor's).
    private let togglable: Bool
    let select: () -> Void

    public init(_ name: String, isOn: Bool, switchEnabled: Bool = true, starts: String = "thread",
                startsGlyph: String = "text.bubble", note: String? = nil, noteState: AgentState? = nil, unread: Int = 0,
                host: String, outcome: SHRunOutcome?, selected: Bool, columns: [SHTableColumns.Column],
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
        self.columns = columns
        self.toggle = toggle
        togglable = toggle != nil
        self.select = select
    }

    public nonisolated static func == (a: SHAutomationTableRow, b: SHAutomationTableRow) -> Bool {
        a.name == b.name && a.isOn == b.isOn && a.switchEnabled == b.switchEnabled && a.starts == b.starts
            && a.startsGlyph == b.startsGlyph && a.note == b.note && a.noteState == b.noteState && a.unread == b.unread
            && a.host == b.host && a.outcome == b.outcome && a.selected == b.selected && a.columns == b.columns
            && a.togglable == b.togglable
    }

    public var body: some View {
        let sh = Color.sh
        // The row is a button under the cells, so a click anywhere selects and the switch
        // (above it) flips without selecting.
        ZStack {
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.shRow(selected: selected, radius: 0))
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(selected ? .isSelected : [])
            SHTableColumns(columns) {
                HStack(spacing: SHPageMetrics.switchGap) {
                    SHAutomationSwitch(name, isOn: isOn, toggle: switchEnabled ? toggle : nil)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        HStack(spacing: SH.Space.s) {
                            Text(name)
                                .font(.shSans(13, .semibold))
                                .foregroundStyle(sh.textPrimary)
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
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Label {
                    Text(starts).font(.shSans(12)).foregroundStyle(sh.textSecondary).lineLimit(1)
                } icon: {
                    Image(systemName: startsGlyph)
                        .font(.shSans(11))
                        .foregroundStyle(sh.textTertiary)
                }
                .labelStyle(SHPageCellLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                Text(host)
                    .font(.shMono(11))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                Group {
                    if let outcome { SHRunOutcomeLabel(outcome) } else { Color.clear.frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .padding(.horizontal, SHPageMetrics.sideInset)
            .padding(.vertical, SHPageMetrics.rowVertical)
        }
        .overlay(alignment: .top) { SHHairline() }
    }

    private var accessibilityText: String {
        [name, isOn ? "on" : "off", unread > 0 ? "\(unread) unread" : nil, note, starts, "on \(host)", outcome?.text]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// A glyph 6pt before a cell's words.
private struct SHPageCellLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.s) {
            configuration.icon
            configuration.title
        }
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
        return HStack(spacing: SH.Space.m) {
            if let state {
                SHStatusDot(state, size: SHPageMetrics.dot)
            } else {
                Circle().strokeBorder(sh.textTertiary, lineWidth: 1)
                    .frame(width: SHPageMetrics.dot, height: SHPageMetrics.dot)
                    .accessibilityHidden(true)
            }
            Text(started).font(.shMono(12)).foregroundStyle(sh.textSecondary).fixedSize()
            Text(word).font(.shSans(12)).foregroundStyle(sh.textTertiary).lineLimit(1)
            Spacer(minLength: SH.Space.s)
            if let duration {
                Text(duration).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, minHeight: SH.Height.controlM, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
