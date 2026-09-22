import SwiftUI
import ShepherdProtocol
import ShepherdRemote

// Subagent cards and the RunsStrip (docs/design-spec/subagent-card-states.png). A subagent is a
// turn inside a turn: the card sits in the ToolGroup where its shepherd_child_start row was.
// Pause is absent on purpose: the children runtime has abort but no pause, and a button that
// cannot do what it says is a fake affordance.

/// What a card can ask the thread to do. `inspect` opens the side panel for the run.
struct NativeSubagentActions {
    var inspect: (ChildRun) -> Void
    var command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    var enabled: Bool
}

/// The ↳ branch glyph in the run's state colour.
struct NativeBranchGlyph: View {
    let color: Color
    var size: CGFloat = NativeMetrics.subagentGlyph
    var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: size * 0.8, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

@MainActor
func nativeSubagentColor(_ state: NativeSubagentState) -> Color {
    switch state {
    case .running: NativeTokens.accent
    case .needsYou: NativeTokens.warning
    case .done: NativeTokens.success
    case .failed: NativeTokens.danger
    }
}

struct NativeSubagentCard: View {
    let run: ChildRun
    /// Finished cards fold to one row while siblings still run (the inspector board); the
    /// chevron toggles either way.
    var hasLiveSiblings = false
    @ObservedObject var clock: NativeThreadClock
    let actions: NativeSubagentActions
    @State private var collapsed: Bool?
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var state: NativeSubagentState { nativeSubagentState(run) }
    private var role: String { run.role ?? run.label }
    private var isCollapsed: Bool { collapsed ?? (state == .done && hasLiveSiblings) }

    var body: some View {
        let color = nativeSubagentColor(state)
        VStack(alignment: .leading, spacing: NativeMetrics.subagentCardRowSpacing) {
            header
            if !isCollapsed {
                switch state {
                case .running: runningBody
                case .needsYou: needsYouBody
                case .done: doneBody
                case .failed: EmptyView()
                }
            }
        }
        .padding(NativeMetrics.subagentCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state == .failed ? NativeTokens.dangerBg : NativeTokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(border(color), lineWidth: 1))
        .contentShape(Rectangle())
        // Anywhere that is not a button opens the inspector.
        .onTapGesture { actions.inspect(run) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(nativeSubagentAccessibilityLabel(run, now: clock.now))
    }

    private func border(_ color: Color) -> Color {
        switch state {
        case .running, .needsYou: color.opacity(0.5)
        case .done: NativeTokens.border
        case .failed: NativeTokens.danger.opacity(0.5)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            NativeBranchGlyph(color: nativeSubagentColor(state))
            Text(role).font(NativeFonts.label).foregroundStyle(NativeTokens.text).lineLimit(1)
            if state == .failed {
                Text(run.exitReason ?? run.state).font(NativeFonts.micro).foregroundStyle(NativeTokens.dangerText).lineLimit(1).truncationMode(.tail)
            } else if isCollapsed, state == .done, let summary = doneSummary.first {
                Text(summary).font(NativeFonts.bodySmall).foregroundStyle(NativeTokens.text).lineLimit(1).truncationMode(.tail)
            } else {
                Text(meta).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: NativeMetrics.subagentCardHeaderHeight)
    }

    /// "background · claude-fable-5-1 · thinking high"
    private var meta: String {
        var parts: [String] = []
        if let context = run.context { parts.append(context) }
        if let model = run.model { parts.append(nativeModelShortName(model)) }
        if let thinking = run.thinking, thinking != "off" { parts.append("thinking \(thinking)") }
        return parts.joined(separator: " · ")
    }

    private var elapsed: String? { nativeSubagentElapsed(run, now: clock.now).map(nativeSubagentDurationText) }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .running:
            HStack(spacing: 6) {
                NativeSpinner(color: NativeTokens.accent, size: 11)
                Text("Running" + (elapsed.map { " · \($0)" } ?? "")).font(NativeFonts.captionMedium).foregroundStyle(NativeTokens.accentText).monospacedDigit()
            }
            .fixedSize()
        case .needsYou:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTokens.warning)
                Text("Needs you" + (elapsed.map { " · \($0)" } ?? "")).font(NativeFonts.captionMedium).foregroundStyle(NativeTokens.warningText).monospacedDigit()
            }
            .fixedSize()
        case .done:
            HStack(spacing: 8) {
                if isCollapsed, let result = run.result {
                    (Text("+\(result.added)").foregroundStyle(NativeTokens.successText) + Text(" -\(result.removed)").foregroundStyle(NativeTokens.dangerText))
                        .font(NativeFonts.micro)
                }
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTokens.success)
                    Text(isCollapsed ? (elapsed ?? "Done") : "Done" + (elapsed.map { " · \($0)" } ?? ""))
                        .font(NativeFonts.captionMedium).foregroundStyle(NativeTokens.successText).monospacedDigit()
                }
                Button { collapsed = !isCollapsed } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTokens.textMuted)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(role) result" : "Collapse \(role) result")
            }
            .fixedSize()
        case .failed:
            HStack(spacing: 6) {
                Button("Retry") { actions.command(run, .resume, nil, nil) }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!actions.enabled)
                    .help("Resume \(role) with its original task")
                    .accessibilityLabel("Retry \(role)")
                Button("Transcript") { actions.inspect(run) }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .accessibilityLabel("Open \(role) transcript")
            }
            .fixedSize()
        }
    }

    // MARK: Running

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let step = run.step {
                    Text("step \(step.index) / \(step.total)").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit().fixedSize()
                }
                progress
                Spacer(minLength: 8)
                Text(nativeSubagentCounters(run)).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit().lineLimit(1).fixedSize()
            }
            if let activity = run.lastActivity {
                HStack(spacing: 10) {
                    Text(activity.tool).font(NativeFonts.code).foregroundStyle(NativeTokens.textMuted)
                        .frame(width: 40, alignment: .leading).lineLimit(1)
                    Text(activity.preview ?? "").font(NativeFonts.code).foregroundStyle(NativeTokens.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let diff = activity.diff {
                        (Text(diff.added > 0 ? "+\(diff.added)" : "").foregroundStyle(NativeTokens.successText)
                         + Text(diff.removed > 0 ? " -\(diff.removed)" : "").foregroundStyle(NativeTokens.dangerText))
                            .font(NativeFonts.micro)
                    }
                    Text(nativeAgeText(activity.at, now: clock.now)).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit().fixedSize()
                }
            }
            if replying { replyField(placeholder: "Steer \(role) — delivered before its next turn", mode: .steer) }
            HStack(spacing: 6) {
                Button { actions.inspect(run) } label: {
                    HStack(spacing: 5) {
                        Text("Inspect")
                        Text("⌘I").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
                    }
                }
                .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                .accessibilityLabel("Inspect \(role)")
                Button("Steer…") { replying.toggle(); replyFocused = replying }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Steer \(role)")
                Spacer(minLength: 0)
                Button("Stop") { actions.command(run, .cancel, nil, nil) }
                    .buttonStyle(.plain).font(NativeFonts.label).foregroundStyle(NativeTokens.dangerText)
                    .disabled(!actions.enabled)
                    .help("Abort and terminate \(role)")
                    .accessibilityLabel("Stop \(role)")
            }
            .padding(.top, 2)
        }
    }

    private var progress: some View {
        // Context fill of the child's own session; a bare track until the first turn reports it.
        let fraction = min(1, max(0, (run.contextPercent ?? 0) / 100))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NativeTokens.bgTrack)
                Capsule().fill(NativeTokens.accent).frame(width: geo.size.width * fraction)
            }
        }
        .frame(maxWidth: NativeMetrics.subagentProgressWidth)
        .frame(height: NativeMetrics.subagentProgressHeight)
        .accessibilityLabel("Context \(Int((run.contextPercent ?? 0).rounded())) percent")
    }

    // MARK: Needs you

    private var needsYouBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NativeProse.inline(run.question?.text ?? run.attentionText ?? ""))
                .font(NativeFonts.bodySmall).lineSpacing(NativeFonts.bodySmallLeading).foregroundStyle(NativeTokens.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if replying { replyField(placeholder: "Reply to \(role)…", mode: .steer) }
            HStack(spacing: 6) {
                ForEach(Array((run.question?.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button(option) { actions.command(run, .message, option, .steer) }
                        .buttonStyle(NativeButtonStyle(index == 0 ? .primary : .secondary, size: NativeMetrics.subagentCardButton))
                        .disabled(!actions.enabled)
                        .accessibilityLabel("Answer \(option)")
                }
                Button("Reply…") { replying.toggle(); replyFocused = replying }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Reply to \(role)")
                Spacer(minLength: 0)
            }
        }
    }

    /// One-line answer field; ⏎ sends through the children extension (never the parent).
    private func replyField(placeholder: String, mode: NativeThreadDelivery) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $reply)
                .textFieldStyle(.plain).font(NativeFonts.bodySmall).autocorrectionDisabled()
                .focused($replyFocused)
                .onSubmit { send(mode) }
                .accessibilityLabel(placeholder)
            Button("Send") { send(mode) }
                .buttonStyle(NativeButtonStyle(.primary, size: NativeMetrics.subagentCardButton))
                .disabled(!actions.enabled || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send to \(role)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(NativeTokens.bgMuted, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(NativeTokens.border, lineWidth: 1))
    }

    private func send(_ mode: NativeThreadDelivery) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.command(run, .message, text, mode)
        reply = ""
        replying = false
    }

    // MARK: Done

    /// First two lines of the child's final output.
    private var doneSummary: [String] {
        let lines = (run.output ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(lines.prefix(2))
    }

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !doneSummary.isEmpty {
                Text(NativeProse.inline(doneSummary.joined(separator: " ")))
                    .font(NativeFonts.bodySmall).lineSpacing(NativeFonts.bodySmallLeading).foregroundStyle(NativeTokens.text)
                    .lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if let result = run.result {
                    let parts = nativeSubagentResultLine(result)
                    Text(parts[0]).foregroundStyle(NativeTokens.textMuted)
                    (Text("+\(result.added)").foregroundStyle(NativeTokens.successText) + Text(" -\(result.removed)").foregroundStyle(NativeTokens.dangerText))
                    Text(parts[2]).foregroundStyle(NativeTokens.textMuted)
                    Text(parts[3]).foregroundStyle(NativeTokens.textMuted)
                }
                Spacer(minLength: 0)
                Button("Open transcript") { actions.inspect(run) }
                    .buttonStyle(.plain).foregroundStyle(NativeTokens.accentText)
                    .accessibilityLabel("Open \(role) transcript")
            }
            .font(NativeFonts.micro)
        }
    }
}

// MARK: RunsStrip

/// More than three sibling runs collapse to this 36pt row; a needs-you run still renders its
/// own card below it. Clicking a cell opens that run in the inspector; the chevron unfolds.
struct NativeRunsStrip: View {
    let runs: [ChildRun]
    @ObservedObject var clock: NativeThreadClock
    let actions: NativeSubagentActions
    @Binding var expanded: Bool

    var body: some View {
        let summary = nativeRunsStripSummary(runs, now: clock.now)
        let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        HStack(spacing: 10) {
            NativeBranchGlyph(color: NativeTokens.accent)
            Text("\(summary.count) subagents").font(NativeFonts.label).foregroundStyle(NativeTokens.text).fixedSize()
            HStack(spacing: NativeMetrics.runsStripCellGap) {
                ForEach(ordered, id: \.id) { run in
                    Button { actions.inspect(run) } label: {
                        RoundedRectangle(cornerRadius: 1.5).fill(nativeSubagentColor(nativeSubagentState(run)))
                            .frame(width: NativeMetrics.runsStripCell, height: NativeMetrics.runsStripCell)
                    }
                    .buttonStyle(.plain)
                    .help(run.role ?? run.label)
                    .accessibilityLabel(nativeSubagentAccessibilityLabel(run, now: clock.now))
                }
            }
            Text(summary.states).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).lineLimit(1)
            Spacer(minLength: 8)
            Text(summary.totals).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit().fixedSize()
            Button { expanded.toggle() } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(NativeTokens.textMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse subagents" : "Expand subagents")
        }
        .padding(.horizontal, NativeMetrics.subagentCardPadding)
        .frame(height: NativeMetrics.runsStripHeight)
        .frame(maxWidth: .infinity)
        .background(NativeTokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(NativeTokens.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(summary.count) subagents, \(summary.states)")
    }
}

/// The cards for one turn: at the spawn rows when few, the strip (plus needs-you cards) when many.
struct NativeSubagentStack: View {
    let runs: [ChildRun]
    /// Whether any sibling in the turn (not only this stack) is still live; finished cards fold.
    var turnLive = false
    @ObservedObject var clock: NativeThreadClock
    let actions: NativeSubagentActions
    @State private var stripExpanded = false

    var body: some View {
        let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        let live = turnLive || ordered.contains { !$0.isTerminal }
        VStack(alignment: .leading, spacing: NativeMetrics.blockSpacing) {
            if ordered.count > NativeRunsStripSummary.collapseThreshold {
                NativeRunsStrip(runs: ordered, clock: clock, actions: actions, expanded: $stripExpanded)
                ForEach(ordered.filter { stripExpanded || $0.needsAttention }, id: \.id) { run in
                    NativeSubagentCard(run: run, hasLiveSiblings: live, clock: clock, actions: actions)
                }
            } else {
                ForEach(ordered, id: \.id) { run in
                    NativeSubagentCard(run: run, hasLiveSiblings: live, clock: clock, actions: actions)
                }
            }
        }
    }
}

/// A tool group split around its spawn rows: plain rows stay grouped, each spawn position
/// becomes a card stack. Tool rows that spawned nothing visible stay tool rows.
enum NativeToolSegment: Equatable {
    case rows([NativeThreadMessage])
    case subagents([ChildRun])
}

func nativeToolSegments(_ group: [NativeThreadMessage], placement: NativeSubagentPlacement) -> [NativeToolSegment] {
    // With a strip (more than the threshold in this turn) every spawn row folds into one stack
    // at the first spawn's position, so the strip is the turn's single subagent surface.
    let all = placement.all
    let strip = all.count > NativeRunsStripSummary.collapseThreshold
    var segments: [NativeToolSegment] = []
    var rows: [NativeThreadMessage] = []
    var stripPlaced = false
    for message in group {
        guard let id = message.toolCallID, let runs = placement.byToolCall[id] else { rows.append(message); continue }
        if !rows.isEmpty { segments.append(.rows(rows)); rows = [] }
        if strip {
            if !stripPlaced { segments.append(.subagents(all)); stripPlaced = true }
        } else {
            segments.append(.subagents(runs))
        }
    }
    if !rows.isEmpty { segments.append(.rows(rows)) }
    return segments
}
