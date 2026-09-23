import SwiftUI
import ShepherdDesign
import ShepherdProtocol
import ShepherdRemote

// Subagents (spec §10): a subagent is a turn inside a turn. Its card sits in the ToolGroup
// where its spawn call was; more than three siblings collapse to a RunsStrip; once every run in
// the group has finished, the cards become one RunLedger. Pause waits at the child's next
// model-request boundary; Continue releases it.

/// What a card can ask the thread to do. `inspect` opens the inspector for the run.
struct SubagentActions {
    var inspect: (ChildRun) -> Void
    var command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    var enabled: Bool
    /// The run open in the inspector: its card gets the accent border, its ledger row the tint.
    var inspectedRunID: String? = nil
}

struct SubagentCard: View {
    let run: ChildRun
    /// A finished card folds to its header while siblings still run.
    var hasLiveSiblings = false
    let actions: SubagentActions
    @State private var collapsed: Bool?
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var state: NativeSubagentState { nativeSubagentState(run) }
    private var role: String { run.role ?? run.label }
    private var isCollapsed: Bool { collapsed ?? (state == .done && hasLiveSiblings) }
    private var selected: Bool { actions.inspectedRunID == run.runID }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                if !isCollapsed, state != .failed {
                    VStack(alignment: .leading, spacing: 10) {
                        switch state {
                        case .running: runningBody(now: context.date)
                        case .needsYou: needsYouBody
                        case .done: doneBody
                        case .failed: EmptyView()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, state == .needsYou ? 12 : 2)
                    .padding(.bottom, 12)
                }
            }
            .accessibilityLabel(nativeSubagentAccessibilityLabel(run, now: context.date))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state == .failed ? Tokens.dangerBg : Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(borderColor, lineWidth: 1) }
        .background { RoundedRectangle(cornerRadius: Radius.lg + 3).fill(selected ? Tokens.focusRing : .clear).padding(-3) }
        .contentShape(Rectangle())
        // Anywhere that is not a button opens the inspector.
        .onTapGesture { actions.inspect(run) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Inspect") { actions.inspect(run) }
    }

    private var borderColor: Color {
        if selected { return Tokens.accent }
        return switch state {
        case .running: Tokens.border
        case .needsYou: Tokens.warning.opacity(0.45)
        case .done: Tokens.border
        case .failed: Tokens.danger.opacity(0.4)
        }
    }

    // MARK: Header

    /// 40pt: branch glyph · name · "mode · model · thinking" · trailing state.
    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            BranchGlyph(SubagentStyle.color(state))
            Text(role).font(Fonts.labelStrong).foregroundStyle(state == .failed ? Tokens.dangerText : Tokens.text).lineLimit(1)
            if state == .failed {
                Text(run.exitReason ?? run.state).font(Fonts.micro).foregroundStyle(Tokens.dangerText).lineLimit(1).truncationMode(.tail)
            } else if isCollapsed, state == .done, let summary = run.summary ?? doneLines.first {
                Text(summary).font(Fonts.bodySmall).foregroundStyle(Tokens.textSecondary).lineLimit(1).truncationMode(.tail)
            } else {
                Text(meta).font(Fonts.micro).foregroundStyle(Tokens.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing(now: now)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.subagentHeaderHeight)
        .background(state == .needsYou ? Tokens.warningBg : .clear)
    }

    /// "background · claude-fable-5-1 · thinking high"
    private var meta: String {
        var parts: [String] = []
        if let context = run.context { parts.append(context) }
        if let model = run.model { parts.append(nativeModelShortName(model)) }
        if let thinking = run.thinking, thinking != "off" { parts.append("thinking \(thinking)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func trailing(now: Date) -> some View {
        let elapsed = nativeSubagentElapsed(run, now: now).map(nativeSubagentDurationText)
        switch state {
        case .running:
            HStack(spacing: 6) {
                if run.paused == true {
                    Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(Tokens.textMuted)
                } else {
                    Spinner(size: 11)
                }
                Text((run.paused == true ? "Paused" : "Running") + (elapsed.map { " · \($0)" } ?? ""))
                    .font(Fonts.captionMedium).foregroundStyle(Tokens.accentText).monospacedDigit()
            }
            .fixedSize()
        case .needsYou:
            HStack(spacing: 6) {
                RunStateGlyph(.needsYou, size: 12)
                Text("Needs you" + (elapsed.map { " · \($0)" } ?? "")).font(Fonts.captionMedium).foregroundStyle(Tokens.warningText).monospacedDigit()
            }
            .fixedSize()
        case .done:
            HStack(spacing: 8) {
                if isCollapsed, let result = run.result { DiffStat(added: result.added, removed: result.removed) }
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.success)
                    Text(isCollapsed ? (elapsed ?? "Done") : "Done" + (elapsed.map { " · \($0)" } ?? ""))
                        .font(Fonts.captionMedium).foregroundStyle(Tokens.successText).monospacedDigit()
                }
                Button { collapsed = !isCollapsed } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.textMuted)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(role)" : "Collapse \(role)")
            }
            .fixedSize()
        case .failed:
            HStack(spacing: 6) {
                Button("Retry") { actions.command(run, .resume, nil, nil) }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Retry \(role)")
                Button("Transcript") { actions.inspect(run) }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .accessibilityLabel("Open \(role) transcript")
            }
            .fixedSize()
        }
    }

    // MARK: Running

    /// Progress (step n/m, the bar, counters) and ONE live activity line in tool-row form. The
    /// card never grows while running.
    private func runningBody(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let step = run.step {
                    Text("step \(step.index) / \(step.total)").font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().fixedSize()
                }
                ProgressBar((run.contextPercent ?? 0) / 100)
                Text(nativeSubagentCounters(run)).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().lineLimit(1).fixedSize()
            }
            if let activity = run.lastActivity {
                HStack(spacing: 10) {
                    Text(activity.tool).font(Fonts.code).foregroundStyle(Tokens.textTertiary)
                        .frame(width: Metrics.toolNameWidth, alignment: .leading).lineLimit(1)
                    Text(activity.preview ?? "").font(Fonts.code).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let diff = activity.diff { DiffStat(added: diff.added, removed: diff.removed) }
                    Text(nativeAgeText(activity.at, now: now)).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().fixedSize()
                }
            }
            if replying { replyField(placeholder: "Steer \(role) — delivered before its next turn") }
            HStack(spacing: 6) {
                Button { actions.inspect(run) } label: {
                    HStack(spacing: 6) { Text("Inspect"); Text(KeybindingsStore.shared.display(.inspectSubagent)).font(Fonts.micro).foregroundStyle(Tokens.textMuted) }
                }
                .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                .accessibilityLabel("Inspect \(role)")
                Button("Steer…") { replying.toggle(); replyFocused = replying }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Steer \(role)")
                Button(run.paused == true ? "Continue" : "Pause") {
                    actions.command(run, run.paused == true ? .continue : .pause, nil, nil)
                }
                .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                .disabled(!actions.enabled)
                .help("Pause before the next model request; current tools finish normally")
                Spacer(minLength: 0)
                Button("Stop") { actions.command(run, .cancel, nil, nil) }
                    .buttonStyle(ShepherdButtonStyle(.ghost, size: .small))
                    .foregroundStyle(Tokens.dangerText)
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Stop \(role)")
            }
            .padding(.top, 4)
        }
    }

    // MARK: Needs you

    private var needsYouBody: some View {
        let question = run.question
        return VStack(alignment: .leading, spacing: 10) {
            Text(Prose.inline(question?.text ?? run.attentionText ?? ""))
                .font(Fonts.bodySmall).lineSpacing(Fonts.bodySmallLeading).foregroundStyle(Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if replying { replyField(placeholder: "Reply to \(role)…") }
            HStack(alignment: .center, spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button(option) { actions.command(run, .message, option, .steer) }
                            .buttonStyle(ShepherdButtonStyle(index == 0 ? .primary : .secondary, size: .small))
                            .disabled(!actions.enabled)
                            .accessibilityLabel("Answer \(option)")
                    }
                    Button("Reply…") { replying.toggle(); replyFocused = replying }
                        .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                        .disabled(!actions.enabled)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One-line answer field; ⏎ sends through the children extension (never the parent).
    private func replyField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $reply)
                .textFieldStyle(.plain).font(Fonts.bodySmall).autocorrectionDisabled()
                .focused($replyFocused)
                .onSubmit { send() }
                .accessibilityLabel(placeholder)
            Button("Send") { send() }
                .buttonStyle(ShepherdButtonStyle(.primary, size: .small))
                .disabled(!actions.enabled || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(replyFocused ? Tokens.accent : Tokens.borderStrong, lineWidth: 1) }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.command(run, .message, text, .steer)
        reply = ""
        replying = false
    }

    // MARK: Done

    /// First two lines of the child's final output.
    private var doneLines: [String] {
        let lines = (run.output ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(lines.prefix(2))
    }

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            let summary = run.summary ?? doneLines.joined(separator: " ")
            if !summary.isEmpty {
                Text(Prose.inline(summary))
                    .font(Fonts.bodySmall).lineSpacing(Fonts.bodySmallLeading).foregroundStyle(Tokens.text)
                    .lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if let result = run.result {
                    let parts = nativeSubagentResultLine(result)
                    Text(parts[0]).foregroundStyle(Tokens.textMuted)
                    DiffStat(added: result.added, removed: result.removed)
                    Text(parts[2]).foregroundStyle(Tokens.textMuted)
                    Text(parts[3]).foregroundStyle(Tokens.textMuted)
                }
                Spacer(minLength: 0)
                Button("Open transcript") { actions.inspect(run) }
                    .buttonStyle(LinkButtonStyle(font: Fonts.micro))
                    .accessibilityLabel("Open \(role) transcript")
            }
            .font(Fonts.micro)
        }
    }
}

// MARK: RunsStrip

/// More than three sibling runs collapse to one row: count, one cell per run in spawn order,
/// "7 done · 3 running · 1 needs you", totals. A needs-you run still renders its card below.
struct RunsStrip: View {
    let runs: [ChildRun]
    let actions: SubagentActions
    @Binding var expanded: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let summary = nativeRunsStripSummary(runs, now: context.date)
            let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
            HStack(spacing: 10) {
                BranchGlyph(Tokens.accent)
                Text("\(summary.count) subagents").font(Fonts.labelStrong).foregroundStyle(Tokens.text).fixedSize()
                HStack(spacing: 3) {
                    ForEach(ordered, id: \.id) { run in
                        Button { actions.inspect(run) } label: {
                            RoundedRectangle(cornerRadius: 2).fill(SubagentStyle.color(nativeSubagentState(run)))
                                .frame(width: Metrics.runCell, height: Metrics.runCell)
                        }
                        .buttonStyle(.plain)
                        .help(run.role ?? run.label)
                        .accessibilityLabel(nativeSubagentAccessibilityLabel(run, now: context.date))
                    }
                }
                Text(summary.states).font(Fonts.micro).foregroundStyle(Tokens.textMuted).lineLimit(1)
                Spacer(minLength: 8)
                Text(summary.totals).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().lineLimit(1).layoutPriority(-1)
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse subagents" : "Expand subagents")
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.subagentHeaderHeight)
            .frame(maxWidth: .infinity)
            .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Tokens.border, lineWidth: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(summary.count) subagents, \(summary.states)")
        }
    }
}

// MARK: RunLedger

/// The permanent record of a finished run group: a 36pt header on `bgMuted` (glyph, "n
/// subagents", state cells, "all done · wall · tokens", combined DiffStat and files) and one
/// 44pt row per subagent in spawn order. Rows open the read-only inspector.
struct RunLedger: View {
    let runs: [ChildRun]
    let actions: SubagentActions

    var body: some View {
        let ledger = nativeSubagentLedger(runs)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BranchGlyph(Tokens.accent)
                Text(ledger.title).font(Fonts.labelStrong).foregroundStyle(Tokens.text).fixedSize()
                RunCells(ledger.rows.map { SubagentStyle.color($0.state) }).accessibilityHidden(true)
                Text(ledger.status).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                if let files = ledger.diffText {
                    HStack(spacing: 6) {
                        DiffStat(added: ledger.added, removed: ledger.removed)
                        Text("· \(files)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.ledgerHeaderHeight)
            .background(Tokens.bgMuted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ledger.title), \(ledger.status)")
            ForEach(ledger.rows, id: \.run.id) { row in
                Tokens.borderSubtle.frame(height: 1)
                LedgerRow(row: row, selected: row.run.runID == actions.inspectedRunID) { actions.inspect(row.run) }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Tokens.border, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

private struct LedgerRow: View {
    let row: NativeSubagentLedger.Row
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RunStateGlyph(row.state == .failed ? .failed : row.state == .needsYou ? .needsYou : .done)
                Text(row.run.role ?? row.run.label).font(Fonts.labelStrong).foregroundStyle(Tokens.text).lineLimit(1)
                    .frame(width: Metrics.ledgerNameWidth, alignment: .leading)
                Text(row.summary).font(Fonts.bodySmall).foregroundStyle(row.state == .failed ? Tokens.dangerText : Tokens.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(row.meta).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit().lineLimit(1).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Tokens.accent : Tokens.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: Metrics.ledgerRowHeight)
            .frame(maxWidth: .infinity)
            .background(selected ? Tokens.accentBg : hovering ? Tokens.bgHover : .clear)
            .overlay(alignment: .trailing) { if selected { Tokens.accent.frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(row.run.role ?? row.run.label), \(row.state == .failed ? "failed" : "done"), \(row.summary)")
        .accessibilityHint("Opens the run in the inspector")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The subagents for one turn: cards where few, the strip (plus needs-you cards) when many,
/// the ledger once every run in the group has finished.
struct SubagentStack: View {
    let runs: [ChildRun]
    /// Whether any sibling in the turn is still live; finished cards fold while it is.
    var turnLive = false
    let actions: SubagentActions
    @State private var stripExpanded = false

    var body: some View {
        let ordered = runs.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        let live = turnLive || ordered.contains { !$0.isTerminal }
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            if !live, nativeSubagentGroupIsTerminal(ordered) {
                RunLedger(runs: ordered, actions: actions)
            } else if ordered.count > NativeRunsStripSummary.collapseThreshold {
                RunsStrip(runs: ordered, actions: actions, expanded: $stripExpanded)
                ForEach(ordered.filter { stripExpanded || $0.needsAttention }, id: \.id) { run in
                    SubagentCard(run: run, hasLiveSiblings: live, actions: actions)
                }
            } else {
                ForEach(ordered, id: \.id) { run in
                    SubagentCard(run: run, hasLiveSiblings: live, actions: actions)
                }
            }
        }
    }
}
