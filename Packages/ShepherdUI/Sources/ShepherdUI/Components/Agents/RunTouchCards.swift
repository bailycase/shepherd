import SwiftUI

// Subagent runs for touch (MobileSubagents, MobileSteer, iPadSteer, iPadSubagents boards): the
// run card, the group card a turn shows for several runs, the rows of earlier runs, the run
// header and the tabs between sibling runs. The phone and iPad ramp, 44pt targets, nothing on
// hover. The Mac keeps `NWSubagentCard`, `NWRunsStrip` and `NWRunLedger`.

/// The touch run components' own measures.
public enum NWRunTouchMetrics {
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
public struct NWRunCardValue: Identifiable, Equatable, Sendable {
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
    /// The question (inline Markdown) while the run needs you, and the answers it offered.
    public var question: String?
    public var options: [String]
    /// When it started, and when it finished: the pill counts from one to the other, or to now.
    public var since: Date?
    public var until: Date?
    /// When it began waiting on you.
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

/// A run's state pill with its time: "37m" counting while it runs, "Needs you · 2m" while it
/// waits on you, "4m 02s" once finished; a queued or paused run shows its word, outlined.
public struct NWRunPill: View {
    let state: AgentState
    let label: String?
    let since: Date?
    let until: Date?

    /// `label` leads ("Needs you"); the time counts from `since` to `until`, or to now.
    public init(_ state: AgentState, label: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.state = state
        self.label = label
        self.since = since
        self.until = until
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            NWStatusDot(state)
            HStack(spacing: 0) {
                if let label { Text(label) }
                if let label, since != nil, !label.isEmpty { Text(" · ") }
                if let since { NWElapsedText(since: since, until: until, style: until == nil ? .short : .long) }
            }
            .font(.nw(.caption, weight: .medium))
            .foregroundStyle(state.textColor)
            .lineLimit(1)
            .monospacedDigit()
        }
        .padding(.horizontal, NW.Space.m)
        .frame(minHeight: NWRunTouchMetrics.pillHeight)
        .background(state.tint ?? .clear, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
        .nwBorder(state.tint == nil ? Color.nw.lineStrong : .clear, radius: NW.Radius.xs)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One run as a card (MobileSubagents board): the branch glyph, name, tags and the timed pill;
/// then per state its step, context bar, tokens and last call; its question with the answers it
/// offered and Reply…; what it did and its diff; or why it failed, with Re-run. Tapping the card
/// opens the run.
public struct NWRunCard: View, Equatable {
    let run: NWRunCardValue
    let isSelected: Bool
    let isEnabled: Bool
    let open: () -> Void
    let answer: ((String) -> Void)?
    let rerun: (() -> Void)?
    private let actionShape: [Bool]
    @Environment(\.dynamicTypeSize) private var dynamicType

    /// `isEnabled` gates answers and Re-run (opening always works). A nil `answer` hides the
    /// question's buttons; a nil `rerun` hides Re-run.
    public init(_ run: NWRunCardValue, isSelected: Bool = false, isEnabled: Bool = true, open: @escaping () -> Void,
                answer: ((String) -> Void)? = nil, rerun: (() -> Void)? = nil) {
        self.run = run
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.open = open
        self.answer = answer
        self.rerun = rerun
        actionShape = [answer != nil, rerun != nil]
    }

    public nonisolated static func == (a: NWRunCard, b: NWRunCard) -> Bool {
        a.run == b.run && a.isSelected == b.isSelected && a.isEnabled == b.isEnabled && a.actionShape == b.actionShape
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Button(action: open) { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(run.accessibilityLabel)
                .accessibilityValue(run.progress.map { "\(run.progressLabel ?? "Progress") \(Int(($0 * 100).rounded()))%" } ?? "")
                .accessibilityHint("Opens the run")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            if run.state == .attention, let question = run.question { questionBlock(question) }
            if run.state == .failed, let rerun {
                Button("Re-run", action: rerun).buttonStyle(.nw(.secondary, size: .l)).disabled(!isEnabled)
                    .accessibilityLabel("Re-run \(run.name)")
            }
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgRaised, in: shape)
        .nwBorder(isSelected ? nw.running : run.state == .attention ? nw.lantern : nw.lineSubtle, radius: NW.Radius.l)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: NW.Radius.l + NWRunTouchMetrics.ring).fill(nw.runningTint)
                    .padding(-NWRunTouchMetrics.ring)
            }
        }
        .nwAnimation(.content, value: run.state)
        .nwAnimation(.hover, value: isSelected)
        .accessibilityElement(children: .contain)
    }

    /// The pill: a live run's time, the wait on you, a finished run's duration, else its word.
    private var pill: (label: String?, since: Date?, until: Date?) {
        switch run.state {
        case .attention:
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
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: NW.Space.m) {
            // At accessibility sizes the header stacks: the name keeps its line, the tags and
            // the pill take the next.
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    HStack(spacing: NW.Space.m) {
                        NWBranchGlyph(run.state, size: NWRunTouchMetrics.glyph)
                        name
                    }
                    pillView
                    if let tags = run.tags { tagsText(tags).lineLimit(2) }
                }
            } else {
                HStack(spacing: NW.Space.m) {
                    NWBranchGlyph(run.state, size: NWRunTouchMetrics.glyph)
                    name.layoutPriority(2)
                    if let tags = run.tags { tagsText(tags).lineLimit(1).layoutPriority(0) }
                    Spacer(minLength: NW.Space.s)
                    pillView.layoutPriority(3)
                }
            }
            switch run.state {
            case .running:
                if dynamicType.isAccessibilitySize, run.step != nil || run.progress != nil || run.tokens != nil {
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        HStack(spacing: NW.Space.m) {
                            if let step = run.step { Text(step) }
                            Spacer(minLength: NW.Space.s)
                            if let tokens = run.tokens { Text(tokens) }
                        }
                        if let progress = run.progress {
                            ProgressView(value: progress).progressViewStyle(.nwBar)
                                .accessibilityLabel(run.progressLabel ?? "Progress")
                        }
                    }
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                } else if run.step != nil || run.progress != nil || run.tokens != nil {
                    HStack(spacing: NW.Space.m) {
                        if let step = run.step { Text(step) }
                        if let progress = run.progress {
                            ProgressView(value: progress).progressViewStyle(.nwBar)
                                .accessibilityLabel(run.progressLabel ?? "Progress")
                        } else {
                            Spacer(minLength: 0)
                        }
                        if let tokens = run.tokens { Text(tokens) }
                    }
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                }
                detailLine
            case .done:
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                    Text(run.detail).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(2)
                    if let added = run.added, let removed = run.removed { NWDiffStat(added: added, removed: removed) }
                }
            case .failed:
                Text(run.detail).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.failed).lineLimit(3)
            case .attention:
                if run.question == nil { detailLine }
            default:
                detailLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var name: some View {
        Text(run.name).font(.nwMono(NWTextStyle.ui.size, .semibold)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
    }

    private func tagsText(_ tags: String) -> Text {
        Text(tags).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
    }

    private var pillView: some View {
        let pill = pill
        return NWRunPill(run.state, label: pill.label, since: pill.since, until: pill.until)
    }

    private var detailLine: some View {
        Text(run.detail).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
            .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
    }

    private func questionBlock(_ question: String) -> some View {
        NWRunQuestion(question, options: run.options, name: run.name, isEnabled: isEnabled, answer: answer)
    }
}

/// A run's question with the answers it offered (the first primary) and Reply…, which opens a
/// field that answers in its own words. Without `answer` only the question shows.
public struct NWRunQuestion: View {
    let question: String
    let options: [String]
    let name: String
    let isEnabled: Bool
    let answer: ((String) -> Void)?
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    public init(_ question: String, options: [String], name: String, isEnabled: Bool = true, answer: ((String) -> Void)?) {
        self.question = question
        self.options = options
        self.name = name
        self.isEnabled = isEnabled
        self.answer = answer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWInlineText(text: question, codeSize: NWTextStyle.caption.size).equatable()
                .nwText(.body)
                .foregroundStyle(Color.nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let answer {
                // Answers wrap onto the next line rather than squeeze.
                NWRunWrap(spacing: NW.Space.m) { answers(answer) }
                if replying { replyField(answer) }
            }
        }
    }

    @ViewBuilder private func answers(_ answer: @escaping (String) -> Void) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button(option) { answer(option) }
                .buttonStyle(.nw(index == 0 ? .primary : .secondary, size: .l))
                .disabled(!isEnabled)
                .accessibilityLabel("Answer \(option)")
        }
        Button("Reply…") {
            replying.toggle()
            replyFocused = replying
        }
        .buttonStyle(.nw(options.isEmpty ? .secondary : .ghost, size: .l))
        .disabled(!isEnabled)
        .accessibilityLabel("Reply to \(name)")
    }

    private func replyField(_ answer: @escaping (String) -> Void) -> some View {
        NWSteerField(text: $reply, prompt: "Reply to \(name)…", isEnabled: isEnabled, focus: $replyFocused,
                     accessibilityLabel: "Reply to \(name)") {
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isEnabled, !text.isEmpty else { return }
            answer(text)
            reply = ""
            replying = false
        }
    }
}

/// Lays its children out in rows, left to right, starting a new row when the next one does not
/// fit.
struct NWRunWrap: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// One run as a row of a group card.
public struct NWRunGroupRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: AgentState
    /// "step 1 of 3 · restyling ThreadView", "needs you: rename or replace?", a summary.
    public var detail: String
    /// Beside the name in a finished group ("5 files · 41m").
    public var meta: String?
    /// The row's time: counting from `since` while live, fixed at `until` once finished.
    public var since: Date?
    public var until: Date?

    public init(id: String, name: String, state: AgentState, detail: String, meta: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
        self.meta = meta
        self.since = since
        self.until = until
    }
}

/// Several runs of one turn in one card (MobileSteer, iPadSubagents boards). While any run is
/// live: "3 subagents" with Open, and one line per run (its glyph, name, what it is doing, and
/// its time); once all have finished: the steps, "all done · 45m", and two lines per run (name
/// and meta over its summary). A row opens its run; Open opens them all.
public struct NWRunGroupCard: View, Equatable {
    let title: String
    let state: AgentState
    /// A finished group's status ("all done · 45m"); nil while live.
    let status: String?
    let rows: [NWRunGroupRow]
    /// Under a live group's rows: what the turn waits on ("Waiting on worker and reviewer").
    let footer: String?
    let selectedID: String?
    let openAll: (() -> Void)?
    let select: (String) -> Void
    /// Whether Open exists, for `==` (closures do not compare).
    private let opens: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(title: String, state: AgentState, status: String? = nil, rows: [NWRunGroupRow], footer: String? = nil,
                selectedID: String? = nil, openAll: (() -> Void)? = nil, select: @escaping (String) -> Void) {
        self.title = title
        self.state = state
        self.status = status
        self.rows = rows
        self.footer = footer
        self.selectedID = selectedID
        self.openAll = openAll
        self.select = select
        opens = openAll != nil
    }

    public nonisolated static func == (a: NWRunGroupCard, b: NWRunGroupCard) -> Bool {
        a.title == b.title && a.state == b.state && a.status == b.status && a.rows == b.rows && a.footer == b.footer && a.selectedID == b.selectedID
            && a.opens == b.opens
    }

    private var finished: Bool { status != nil }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    if finished { NWHairline() }
                    Button { select(row.id) } label: { rowLabel(for: row) }
                        .buttonStyle(.nwRow(selected: row.id == selectedID, radius: finished ? 0 : NW.Radius.s))
                        .overlay(alignment: .trailing) {
                            if row.id == selectedID, finished { Rectangle().fill(nw.running).frame(width: NW.Space.xxs) }
                        }
                        .accessibilityLabel(rowLabel(row))
                        .accessibilityHint("Opens the run")
                        .accessibilityAddTraits(row.id == selectedID ? .isSelected : [])
                }
            }
            if let footer, !finished {
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(.nwSpinner(size: NWRunTouchMetrics.glyph - NW.Space.xxs, color: nw.textTertiary))
                    Text(footer).font(.nw(.caption)).foregroundStyle(nw.textTertiary).lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                }
                .padding(.horizontal, NW.Space.l)
                .frame(maxWidth: .infinity, minHeight: NW.Height.controlL, alignment: .leading)
                .overlay(alignment: .top) { NWHairline() }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, finished || footer != nil ? 0 : NW.Space.s)
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        let nw = Color.nw
        let large = dynamicType.isAccessibilitySize
        return HStack(spacing: NW.Space.m) {
            NWBranchGlyph(state, size: NWRunTouchMetrics.glyph, color: finished ? nil : nw.textSecondary)
            // At accessibility sizes the status takes the line under the title, without steps.
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                HStack(spacing: NW.Space.m) {
                    Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if finished, !large {
                        NWStepStrip(rows.map(\.state), segmentWidth: NW.Space.m).fixedSize()
                    }
                }
                if let status, large { statusText(status).lineLimit(2) }
            }
            Spacer(minLength: NW.Space.m)
            if let status, !large { statusText(status).lineLimit(1) }
            if let openAll {
                Button(action: openAll) {
                    HStack(spacing: NW.Space.xs) {
                        Text("Open")
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .font(.nw(.caption, weight: .medium))
                    .foregroundStyle(nw.running)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .nwTouchTarget(height: NWRunTouchMetrics.pillHeight, width: NW.Space.xxxl)
                .accessibilityLabel("Open \(title)")
            }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, large ? NW.Space.s : 0)
        .frame(minHeight: NW.Height.touch)
        .background(finished ? nw.bgSunken : .clear)
    }

    private func statusText(_ status: String) -> Text {
        Text(status).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
    }

    @ViewBuilder private func rowLabel(for row: NWRunGroupRow) -> some View {
        if finished { finishedRow(row) } else { liveRow(row) }
    }

    private func liveRow(_ row: NWRunGroupRow) -> some View {
        let nw = Color.nw
        let name = Text(row.name).font(.nwMono(NWTextStyle.caption.size + 1, .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
        let detail = Text(row.detail).font(.nw(.caption)).foregroundStyle(row.state == .attention ? nw.lanternText : nw.textSecondary)
        let time = row.since.map { NWElapsedText(since: $0, until: row.until).font(.nw(.mono)).foregroundStyle(nw.textTertiary) }
        return HStack(spacing: NW.Space.m) {
            NWStateGlyph(row.state, size: NWRunTouchMetrics.glyph)
            // At accessibility sizes the name and time share a line over the detail.
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    HStack(spacing: NW.Space.m) {
                        name
                        Spacer(minLength: NW.Space.s)
                        time
                    }
                    detail.lineLimit(3)
                }
                .padding(.vertical, NW.Space.s)
            } else {
                name.layoutPriority(1)
                detail.lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                time
            }
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NW.Height.touch)
        .contentShape(Rectangle())
    }

    private func finishedRow(_ row: NWRunGroupRow) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            NWStateGlyph(row.state, size: NWRunTouchMetrics.glyph)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                // At accessibility sizes the meta takes the line under the name.
                if dynamicType.isAccessibilitySize {
                    Text(row.name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    if let meta = row.meta { Text(meta).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(2) }
                } else {
                    HStack(spacing: NW.Space.m) {
                        Text(row.name).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                        if let meta = row.meta { Text(meta).font(.nw(.mono)).foregroundStyle(nw.textTertiary).lineLimit(1) }
                    }
                }
                Text(row.detail).font(.nw(.caption)).foregroundStyle(row.state == .failed ? nw.failed : nw.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.nw(.caption)).foregroundStyle(nw.textTertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWRunTouchMetrics.historyRowHeight)
        .contentShape(Rectangle())
    }

    private func rowLabel(_ row: NWRunGroupRow) -> String {
        [row.name, row.state.label, row.meta, row.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A finished run in the list of earlier runs.
public struct NWRunHistoryRow: Identifiable, Equatable, Sendable {
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
public struct NWRunHistoryList: View, Equatable {
    let rows: [NWRunHistoryRow]
    let select: (String) -> Void

    public init(_ rows: [NWRunHistoryRow], select: @escaping (String) -> Void) {
        self.rows = rows
        self.select = select
    }

    public nonisolated static func == (a: NWRunHistoryList, b: NWRunHistoryList) -> Bool { a.rows == b.rows }

    public var body: some View {
        let nw = Color.nw
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    if index > 0 { NWHairline() }
                    Button { select(row.id) } label: { label(row) }
                        .buttonStyle(.nwRow(radius: 0))
                        .accessibilityLabel([row.name, row.state.label, row.summary].filter { !$0.isEmpty }.joined(separator: ", "))
                        .accessibilityHint("Opens the run")
                }
            }
        }
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.l)
    }

    private func label(_ row: NWRunHistoryRow) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.l) {
            NWStateGlyph(row.state, size: NWRunTouchMetrics.glyph)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(row.name).font(.nwMono(NWTextStyle.ui.size, .medium)).foregroundStyle(nw.textPrimary).lineLimit(1)
                HStack(spacing: 0) {
                    Text(row.summary).lineLimit(1).truncationMode(.tail)
                    if let finishedAt = row.finishedAt {
                        Text(" · ")
                        NWElapsedText(since: finishedAt)
                        Text(" ago")
                    }
                }
                .font(.nw(.caption))
                .foregroundStyle(nw.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let added = row.added, let removed = row.removed { NWDiffStat(added: added, removed: removed) }
            Image(systemName: "chevron.right").font(.nw(.caption)).foregroundStyle(nw.textTertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWRunTouchMetrics.historyRowHeight)
        .contentShape(Rectangle())
    }
}

/// The header of one run beside the thread (iPadSubagents board): the branch glyph in its state,
/// "tests · 3 of 3", a mono line ending in a state-colored accent ("done 11:02"), and the
/// caller's controls.
public struct NWRunHeader<Trailing: View>: View {
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
        let nw = Color.nw
        let accentText = accent.map { meta.isEmpty ? $0 : " · \($0)" } ?? ""
        let titleBlock = HStack(spacing: NW.Space.m) {
            NWBranchGlyph(state, size: NWRunTouchMetrics.glyph)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text("\(Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary))\(Text(position.map { " · \($0)" } ?? "").font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textSecondary))")
                    .lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
                    .accessibilityAddTraits(.isHeader)
                if !meta.isEmpty || accent != nil {
                    Text("\(Text(meta))\(Text(accentText).foregroundStyle(state.textColor))")
                        .font(.nw(.mono))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        Group {
            // At accessibility sizes the controls take a line of their own under the title.
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    titleBlock
                    HStack(spacing: NW.Space.xxs) {
                        Spacer(minLength: 0)
                        trailing()
                    }
                }
                .padding(.vertical, NW.Space.s)
            } else {
                HStack(spacing: NW.Space.m) {
                    titleBlock
                    Spacer(minLength: NW.Space.m)
                    HStack(spacing: NW.Space.xxs) { trailing() }
                }
            }
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.s)
        .frame(maxWidth: .infinity, minHeight: NW.Height.touch + NW.Space.m)
        .background(nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// Tabs between sibling runs (iPadSteer board): one segment per run, the selected one raised.
public struct NWRunTabs: View {
    @Binding var selection: String
    let tabs: [(id: String, title: String)]

    public init(selection: Binding<String>, tabs: [(id: String, title: String)]) {
        _selection = selection
        self.tabs = tabs
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.xxs) {
            ForEach(tabs, id: \.id) { tab in
                let selected = tab.id == selection
                Button { selection = tab.id } label: {
                    Text(tab.title)
                        .font(.nw(.caption, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: NWRunTouchMetrics.tabHeight)
                        .background(selected ? nw.bgRaised : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nwTouchTarget(height: NWRunTouchMetrics.tabHeight)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(NW.Space.xxs)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwAnimation(.content, value: selection)
    }
}
