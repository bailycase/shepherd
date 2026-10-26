import SwiftUI

// Subagent runs for touch (MobileSubagents, MobileSubagent, iPadSteer, iPadSubagents boards):
// the run card on the subagents screen, the rows of earlier runs, the run header and the tabs
// between sibling runs. The phone and iPad ramp, 44pt targets, nothing on hover. In a thread,
// runs live in the tray above the composer (`SHSubagentTray`), as on the Mac.

/// The touch run components' own measures.
public enum SHRunTouchMetrics {
    /// The state pill.
    public static let pillHeight: CGFloat = 22
    /// Glyphs in rows and headers.
    public static let glyph: CGFloat = 16
    /// A row of earlier runs: a name over a line.
    public static let historyRowHeight: CGFloat = 56
    /// The steer field, one line tall.
    public static let steerHeight: CGFloat = 46
    /// The selection ring outside the inspected card.
    public static let ring: CGFloat = 3
    /// The tabs between sibling runs.
    public static let tabHeight: CGFloat = 32
}

/// Everything a run card shows, as values.
public struct SHRunCardValue: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// "background · fable-5-1".
    public var tags: String?
    public var state: AgentState
    /// Replaces the state's word ("Paused").
    public var stateLabel: String?
    /// One line: what it is doing, why it waits, what it did, or why it failed.
    public var detail: String
    /// "step 1 of 3", beside the progress bar.
    public var step: String?
    /// 0…1.
    public var progress: Double?
    /// What the progress measures, for VoiceOver ("Context window used").
    public var progressLabel: String?
    /// "922k", after the bar.
    public var tokens: String?
    /// The question (inline Markdown) a run put to its parent, which it waits on, and the answers
    /// it offered. The user is never asked: this is only to read.
    public var question: String?
    public var options: [String]
    /// When it started, and when it finished: the pill counts from one to the other, or to now.
    public var since: Date?
    public var until: Date?
    /// When it began waiting on its parent's answer.
    public var waitingSince: Date?
    public var added: Int?
    public var removed: Int?

    public init(id: String, name: String, tags: String? = nil, state: AgentState, stateLabel: String? = nil, detail: String,
                step: String? = nil, progress: Double? = nil, progressLabel: String? = nil, tokens: String? = nil,
                question: String? = nil, options: [String] = [], since: Date? = nil, until: Date? = nil, waitingSince: Date? = nil,
                added: Int? = nil, removed: Int? = nil) {
        self.id = id
        self.name = name
        self.tags = tags
        self.state = state
        self.stateLabel = stateLabel
        self.detail = detail
        self.step = step
        self.progress = progress
        self.progressLabel = progressLabel
        self.tokens = tokens
        self.question = question
        self.options = options
        self.since = since
        self.until = until
        self.waitingSince = waitingSince
        self.added = added
        self.removed = removed
    }

    /// "worker, background · fable-5-1, Running, step 1 of 3, edit ThreadView.swift"
    public var accessibilityLabel: String {
        [name, tags, stateLabel ?? state.label, step, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A run's state pill with its time: "37m" counting while it runs, "Waiting on parent · 2m" while
/// it waits on its parent's answer, "4m 02s" once finished; a queued or paused run shows its
/// word, outlined.
public struct SHRunPill: View {
    let state: AgentState
    let label: String?
    let since: Date?
    let until: Date?

    /// `label` leads ("Waiting on parent"); the time counts from `since` to `until`, or to now.
    public init(_ state: AgentState, label: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.state = state
        self.label = label
        self.since = since
        self.until = until
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            SHStatusDot(state)
            HStack(spacing: 0) {
                if let label { Text(label) }
                if let label, since != nil, !label.isEmpty { Text(" · ") }
                if let since { SHElapsedText(since: since, until: until, style: until == nil ? .short : .long) }
            }
            .font(.sh(.caption, weight: .medium))
            .foregroundStyle(state.textColor)
            .lineLimit(1)
            .monospacedDigit()
        }
        .padding(.horizontal, SH.Space.m)
        .frame(minHeight: SHRunTouchMetrics.pillHeight)
        .background(state.tint ?? .clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
        .shBorder(state.tint == nil ? Color.sh.lineStrong : .clear, radius: SH.Radius.xs)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One run as a card (MobileSubagents board): the branch glyph, name, tags and the timed pill;
/// then per state its step, context bar, tokens and last call; the question it put to its parent;
/// what it did and its diff; or why it failed, with Re-run. Tapping the card opens the run.
public struct SHRunCard: View, Equatable {
    let run: SHRunCardValue
    let isSelected: Bool
    let isEnabled: Bool
    let open: (() -> Void)?
    let rerun: (() -> Void)?
    private let actionShape: [Bool]
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// `isEnabled` gates Re-run (opening always works). A nil `open` draws the card as a header
    /// that opens nothing (the run already on screen); a nil `rerun` hides Re-run.
    public init(_ run: SHRunCardValue, isSelected: Bool = false, isEnabled: Bool = true, open: (() -> Void)?,
                rerun: (() -> Void)? = nil) {
        self.run = run
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.open = open
        self.rerun = rerun
        actionShape = [open != nil, rerun != nil]
    }

    public nonisolated static func == (a: SHRunCard, b: SHRunCard) -> Bool {
        a.run == b.run && a.isSelected == b.isSelected && a.isEnabled == b.isEnabled && a.actionShape == b.actionShape
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(alignment: .leading, spacing: SH.Space.m) {
            if let open {
                Button(action: open) { summary }
                    .buttonStyle(.plain)
                    .accessibilityLabel(run.accessibilityLabel)
                    .accessibilityValue(progressValue)
                    .accessibilityHint("Opens the run")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                summary
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(run.accessibilityLabel)
                    .accessibilityValue(progressValue)
            }
            if let question = run.question { SHRunQuestion(question, options: run.options) }
            if run.state == .failed, let rerun {
                Button("Re-run", action: rerun).buttonStyle(.sh(.secondary, size: .l)).disabled(!isEnabled)
                    .accessibilityLabel("Re-run \(run.name)")
            }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgRaised, in: shape)
        .shBorder(isSelected ? sh.running : sh.lineSubtle, radius: SH.Radius.l)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: SH.Radius.l + SHRunTouchMetrics.ring).fill(sh.runningTint)
                    .padding(-SHRunTouchMetrics.ring)
            }
        }
        .shAnimation(.content, value: run.state)
        .shAnimation(.hover, value: isSelected)
        .accessibilityElement(children: .contain)
    }

    private var progressValue: String {
        run.progress.map { "\(run.progressLabel ?? "Progress") \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    /// The pill: a live run's time, the wait on its parent, a finished run's duration, else its word.
    private var pill: (label: String?, since: Date?, until: Date?) {
        switch run.state {
        case .attention:
            return (run.stateLabel ?? run.state.label, run.waitingSince, nil)
        case .queued where run.waitingSince != nil:
            return (run.stateLabel ?? run.state.label, run.waitingSince, nil)
        case .running:
            return run.since == nil ? (run.stateLabel ?? run.state.label, nil, nil) : (run.stateLabel, run.since, nil)
        case .done, .failed, .stuck:
            guard let since = run.since, let until = run.until else { return (run.stateLabel ?? run.state.label, nil, nil) }
            return (run.state == .done ? run.stateLabel : run.stateLabel ?? run.state.label, since, until)
        case .queued, .idle:
            return (run.stateLabel ?? run.state.label, nil, nil)
        }
    }

    private var summary: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SH.Space.m) {
            // At accessibility sizes the header stacks: the name keeps its line, the tags and
            // the pill take the next.
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    HStack(spacing: SH.Space.m) {
                        SHBranchGlyph(run.state, size: SHRunTouchMetrics.glyph)
                        name
                    }
                    pillView
                    if let tags = run.tags { tagsText(tags).lineLimit(2) }
                }
            } else {
                HStack(spacing: SH.Space.m) {
                    SHBranchGlyph(run.state, size: SHRunTouchMetrics.glyph)
                    name.layoutPriority(2)
                    if let tags = run.tags { tagsText(tags).lineLimit(1).layoutPriority(0) }
                    Spacer(minLength: SH.Space.s)
                    pillView.layoutPriority(3)
                }
            }
            switch run.state {
            case .running:
                if dynamicType.isAccessibilitySize, run.step != nil || run.progress != nil || run.tokens != nil {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        HStack(spacing: SH.Space.m) {
                            if let step = run.step { Text(step) }
                            Spacer(minLength: SH.Space.s)
                            if let tokens = run.tokens { Text(tokens) }
                        }
                        if let progress = run.progress {
                            ProgressView(value: progress).progressViewStyle(.shBar)
                                .accessibilityLabel(run.progressLabel ?? "Progress")
                        }
                    }
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                } else if run.step != nil || run.progress != nil || run.tokens != nil {
                    HStack(spacing: SH.Space.m) {
                        if let step = run.step { Text(step) }
                        if let progress = run.progress {
                            ProgressView(value: progress).progressViewStyle(.shBar)
                                .accessibilityLabel(run.progressLabel ?? "Progress")
                        } else {
                            Spacer(minLength: 0)
                        }
                        if let tokens = run.tokens { Text(tokens) }
                    }
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                }
                detailLine
            case .done:
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(run.detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(2)
                    if let added = run.added, let removed = run.removed { SHDiffStat(added: added, removed: removed) }
                }
            case .failed:
                Text(run.detail).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.failed).lineLimit(3)
            default:
                detailLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var name: some View {
        Text(run.name).font(.shMono(SHTextStyle.ui.size, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
    }

    private func tagsText(_ tags: String) -> Text {
        Text(tags).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
    }

    private var pillView: some View {
        let pill = pill
        return SHRunPill(run.state, label: pill.label, since: pill.since, until: pill.until)
    }

    private var detailLine: some View {
        Text(run.detail).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
            .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
    }
}

/// The question a run put to its parent, to read: the question and the answers it offered. No
/// control answers it: its parent does, or asks the user in its own thread.
public struct SHRunQuestion: View {
    let question: String
    let options: [String]

    public init(_ question: String, options: [String] = []) {
        self.question = question
        self.options = options
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            SHInlineText(text: question, codeSize: SHTextStyle.caption.size).equatable()
                .shText(.body)
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !options.isEmpty {
                Text("It offered: " + options.joined(separator: " · "))
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A finished run in the list of earlier runs.
public struct SHRunHistoryRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: AgentState
    public var summary: String
    /// When it finished: "1h ago".
    public var finishedAt: Date?
    public var added: Int?
    public var removed: Int?

    public init(id: String, name: String, state: AgentState, summary: String, finishedAt: Date? = nil, added: Int? = nil, removed: Int? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.summary = summary
        self.finishedAt = finishedAt
        self.added = added
        self.removed = removed
    }
}

/// Earlier runs in one grouped card (MobileSubagents board): the outcome's glyph, the name over
/// "what it did · 1h ago", the diff, and a chevron. A row opens the run.
public struct SHRunHistoryList: View, Equatable {
    let rows: [SHRunHistoryRow]
    let select: (String) -> Void

    public init(_ rows: [SHRunHistoryRow], select: @escaping (String) -> Void) {
        self.rows = rows
        self.select = select
    }

    public nonisolated static func == (a: SHRunHistoryList, b: SHRunHistoryList) -> Bool { a.rows == b.rows }

    public var body: some View {
        let sh = Color.sh
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    if index > 0 { SHHairline() }
                    Button { select(row.id) } label: { label(row) }
                        .buttonStyle(.shRow(radius: 0))
                        .accessibilityLabel([row.name, row.state.label, row.summary].filter { !$0.isEmpty }.joined(separator: ", "))
                        .accessibilityHint("Opens the run")
                }
            }
        }
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
        .shBorder(sh.lineSubtle, radius: SH.Radius.l)
    }

    private func label(_ row: SHRunHistoryRow) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.l) {
            SHStateGlyph(row.state, size: SHRunTouchMetrics.glyph)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.name).font(.shMono(SHTextStyle.ui.size, .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                HStack(spacing: 0) {
                    Text(row.summary).lineLimit(1).truncationMode(.tail)
                    if let finishedAt = row.finishedAt {
                        Text(" · ")
                        SHElapsedText(since: finishedAt)
                        Text(" ago")
                    }
                }
                .font(.sh(.caption))
                .foregroundStyle(sh.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let added = row.added, let removed = row.removed { SHDiffStat(added: added, removed: removed) }
            Image(systemName: "chevron.right").font(.sh(.caption)).foregroundStyle(sh.textTertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHRunTouchMetrics.historyRowHeight)
        .contentShape(Rectangle())
    }
}

/// The header of one run beside the thread (iPadSubagents board): the branch glyph in its state,
/// "tests · 3 of 3", a mono line ending in a state-colored accent ("done 11:02"), and the
/// caller's controls.
public struct SHRunHeader<Trailing: View>: View {
    let title: String
    let position: String?
    let state: AgentState
    let meta: String
    let accent: String?
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(_ title: String, position: String? = nil, state: AgentState, meta: String, accent: String? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.position = position
        self.state = state
        self.meta = meta
        self.accent = accent
        self.trailing = trailing
    }

    public var body: some View {
        let sh = Color.sh
        let accentText = accent.map { meta.isEmpty ? $0 : " · \($0)" } ?? ""
        let titleBlock = HStack(spacing: SH.Space.m) {
            SHBranchGlyph(state, size: SHRunTouchMetrics.glyph)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text("\(Text(title).font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textPrimary))\(Text(position.map { " · \($0)" } ?? "").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary))")
                    .lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                    .accessibilityAddTraits(.isHeader)
                if !meta.isEmpty || accent != nil {
                    Text("\(Text(meta))\(Text(accentText).foregroundStyle(state.textColor))")
                        .font(.sh(.mono))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        Group {
            // At accessibility sizes the controls take a line of their own under the title.
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    titleBlock
                    HStack(spacing: SH.Space.xxs) {
                        Spacer(minLength: 0)
                        trailing()
                    }
                }
                .padding(.vertical, SH.Space.s)
            } else {
                HStack(spacing: SH.Space.m) {
                    titleBlock
                    Spacer(minLength: SH.Space.m)
                    HStack(spacing: SH.Space.xxs) { trailing() }
                }
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(maxWidth: .infinity, minHeight: SH.Height.touch + SH.Space.m)
        .background(sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// Tabs between sibling runs (iPadSteer board): one segment per run, the selected one raised.
public struct SHRunTabs: View {
    @Binding var selection: String
    let tabs: [(id: String, title: String)]

    public init(selection: Binding<String>, tabs: [(id: String, title: String)]) {
        _selection = selection
        self.tabs = tabs
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach(tabs, id: \.id) { tab in
                let selected = tab.id == selection
                Button { selection = tab.id } label: {
                    Text(tab.title)
                        .font(.sh(.caption, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: SHRunTouchMetrics.tabHeight)
                        .background(selected ? sh.bgRaised : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shTouchTarget(height: SHRunTouchMetrics.tabHeight)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(SH.Space.xxs)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shAnimation(.content, value: selection)
    }
}
