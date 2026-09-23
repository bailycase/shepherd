import SwiftUI
import ShepherdUI
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
        .background(state == .failed ? Color.nw.failedTint : Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(borderColor, lineWidth: 1) }
        .nwFocusRing(selected, radius: NW.Radius.m)
        .contentShape(Rectangle())
        // Anywhere that is not a button opens the inspector.
        .onTapGesture { actions.inspect(run) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Inspect") { actions.inspect(run) }
    }

    private var borderColor: Color {
        if selected { return Color.nw.running }
        return switch state {
        case .running: Color.nw.lineSubtle
        case .needsYou: Color.nw.lantern.opacity(0.45)
        case .done: Color.nw.lineSubtle
        case .failed: Color.nw.failed.opacity(0.4)
        }
    }

    // MARK: Header

    /// 40pt: branch glyph · name · "mode · model · thinking" · trailing state.
    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            NWBranchGlyph(AgentState(state))
            Text(role).font(Font.nw(.headline)).foregroundStyle(state == .failed ? Color.nw.failed : Color.nw.textPrimary).lineLimit(1)
            if state == .failed {
                Text(run.exitReason ?? run.state).font(Font.nw(.micro)).foregroundStyle(Color.nw.failed).lineLimit(1).truncationMode(.tail)
            } else if isCollapsed, state == .done, let summary = run.summary ?? doneLines.first {
                Text(summary).font(Font.nw(.body)).foregroundStyle(Color.nw.textSecondary).lineLimit(1).truncationMode(.tail)
            } else {
                Text(meta).font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing(now: now)
        }
        .padding(.horizontal, 12)
        .frame(height: AppLayout.subagentHeaderHeight)
        .background(state == .needsYou ? Color.nw.lanternTint : .clear)
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
                    Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(Color.nw.textTertiary)
                } else {
                    ProgressView().progressViewStyle(.nwSpinner(size: 11))
                }
                Text((run.paused == true ? "Paused" : "Running") + (elapsed.map { " · \($0)" } ?? ""))
                    .font(Font.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.running).monospacedDigit()
            }
            .fixedSize()
        case .needsYou:
            HStack(spacing: 6) {
                NWStateGlyph(.attention, size: 12)
                Text("Needs you" + (elapsed.map { " · \($0)" } ?? "")).font(Font.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.lanternText).monospacedDigit()
            }
            .fixedSize()
        case .done:
            HStack(spacing: 8) {
                if isCollapsed, let result = run.result { NWDiffStat(added: result.added, removed: result.removed) }
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.nw.done)
                    Text(isCollapsed ? (elapsed ?? "Done") : "Done" + (elapsed.map { " · \($0)" } ?? ""))
                        .font(Font.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.done).monospacedDigit()
                }
                Button { collapsed = !isCollapsed } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.nw.textTertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(role)" : "Collapse \(role)")
            }
            .fixedSize()
        case .failed:
            HStack(spacing: 6) {
                Button("Retry") { actions.command(run, .resume, nil, nil) }
                    .buttonStyle(NWButtonStyle(.secondary, size: .s))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Retry \(role)")
                Button("Transcript") { actions.inspect(run) }
                    .buttonStyle(NWButtonStyle(.secondary, size: .s))
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
                    Text("step \(step.index) / \(step.total)").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().fixedSize()
                }
                ProgressView(value: (run.contextPercent ?? 0) / 100).progressViewStyle(.nwBar)
                Text(nativeSubagentCounters(run)).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().lineLimit(1).fixedSize()
            }
            if let activity = run.lastActivity {
                HStack(spacing: 10) {
                    Text(activity.tool).font(Font.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                        .frame(width: AppLayout.toolNameWidth, alignment: .leading).lineLimit(1)
                    Text(activity.preview ?? "").font(Font.nw(.mono)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let diff = activity.diff { NWDiffStat(added: diff.added, removed: diff.removed) }
                    Text(nativeAgeText(activity.at, now: now)).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().fixedSize()
                }
            }
            if replying { replyField(placeholder: "Steer \(role) — delivered before its next turn") }
            HStack(spacing: 6) {
                Button { actions.inspect(run) } label: {
                    HStack(spacing: 6) { Text("Inspect"); Text(KeybindingsStore.shared.display(.inspectSubagent)).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary) }
                }
                .buttonStyle(NWButtonStyle(.secondary, size: .s))
                .accessibilityLabel("Inspect \(role)")
                Button("Steer…") { replying.toggle(); replyFocused = replying }
                    .buttonStyle(NWButtonStyle(.secondary, size: .s))
                    .disabled(!actions.enabled)
                    .accessibilityLabel("Steer \(role)")
                Button(run.paused == true ? "Continue" : "Pause") {
                    actions.command(run, run.paused == true ? .continue : .pause, nil, nil)
                }
                .buttonStyle(NWButtonStyle(.secondary, size: .s))
                .disabled(!actions.enabled)
                .help("Pause before the next model request; current tools finish normally")
                Spacer(minLength: 0)
                Button("Stop") { actions.command(run, .cancel, nil, nil) }
                    .buttonStyle(NWButtonStyle(.ghost, size: .s))
                    .foregroundStyle(Color.nw.failed)
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
                .font(Font.nw(.body)).lineSpacing(NWTextStyle.body.lineSpacing).foregroundStyle(Color.nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if replying { replyField(placeholder: "Reply to \(role)…") }
            HStack(alignment: .center, spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(Array((question?.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button(option) { actions.command(run, .message, option, .steer) }
                            .buttonStyle(NWButtonStyle(index == 0 ? .primary : .secondary, size: .s))
                            .disabled(!actions.enabled)
                            .accessibilityLabel("Answer \(option)")
                    }
                    Button("Reply…") { replying.toggle(); replyFocused = replying }
                        .buttonStyle(NWButtonStyle(.secondary, size: .s))
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
                .textFieldStyle(.plain).font(Font.nw(.body)).autocorrectionDisabled()
                .focused($replyFocused)
                .onSubmit { send() }
                .accessibilityLabel(placeholder)
            Button("Send") { send() }
                .buttonStyle(NWButtonStyle(.primary, size: .s))
                .disabled(!actions.enabled || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineStrong, lineWidth: 1) }.nwFocusRing(replyFocused, radius: NW.Radius.m)
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
                    .font(Font.nw(.body)).lineSpacing(NWTextStyle.body.lineSpacing).foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if let result = run.result {
                    let parts = nativeSubagentResultLine(result)
                    Text(parts[0]).foregroundStyle(Color.nw.textTertiary)
                    NWDiffStat(added: result.added, removed: result.removed)
                    Text(parts[2]).foregroundStyle(Color.nw.textTertiary)
                    Text(parts[3]).foregroundStyle(Color.nw.textTertiary)
                }
                Spacer(minLength: 0)
                Button("Open transcript") { actions.inspect(run) }
                    .buttonStyle(NWLinkButtonStyle(font: Font.nw(.micro)))
                    .accessibilityLabel("Open \(role) transcript")
            }
            .font(Font.nw(.micro))
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
                NWBranchGlyph(.running)
                Text("\(summary.count) subagents").font(Font.nw(.headline)).foregroundStyle(Color.nw.textPrimary).fixedSize()
                HStack(spacing: 3) {
                    ForEach(ordered, id: \.id) { run in
                        Button { actions.inspect(run) } label: {
                            RoundedRectangle(cornerRadius: 2).fill(SubagentStyle.color(nativeSubagentState(run)))
                                .frame(width: AppLayout.runCell, height: AppLayout.runCell)
                        }
                        .buttonStyle(.plain)
                        .help(run.role ?? run.label)
                        .accessibilityLabel(nativeSubagentAccessibilityLabel(run, now: context.date))
                    }
                }
                Text(summary.states).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                Spacer(minLength: 8)
                Text(summary.totals).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().lineLimit(1).layoutPriority(-1)
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.nw.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse subagents" : "Expand subagents")
            }
            .padding(.horizontal, 12)
            .frame(height: AppLayout.subagentHeaderHeight)
            .frame(maxWidth: .infinity)
            .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
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
                NWBranchGlyph(.running)
                Text(ledger.title).font(Font.nw(.headline)).foregroundStyle(Color.nw.textPrimary).fixedSize()
                NWStepStrip(ledger.rows.map { AgentState($0.state) }, segmentWidth: AppLayout.runCell).accessibilityHidden(true)
                Text(ledger.status).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                if let files = ledger.diffText {
                    HStack(spacing: 6) {
                        NWDiffStat(added: ledger.added, removed: ledger.removed)
                        Text("· \(files)").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: AppLayout.ledgerHeaderHeight)
            .background(Color.nw.bgSunken)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ledger.title), \(ledger.status)")
            ForEach(ledger.rows, id: \.run.id) { row in
                NWHairline()
                LedgerRow(row: row, selected: row.run.runID == actions.inspectedRunID) { actions.inspect(row.run) }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
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
                NWStateGlyph(row.state == .failed ? .failed : row.state == .needsYou ? .attention : .done)
                Text(row.run.role ?? row.run.label).font(Font.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                    .frame(width: AppLayout.ledgerNameWidth, alignment: .leading)
                Text(row.summary).font(Font.nw(.body)).foregroundStyle(row.state == .failed ? Color.nw.failed : Color.nw.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(row.meta).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit().lineLimit(1).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.nw.running : Color.nw.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: AppLayout.ledgerRowHeight)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.nw.runningTint : hovering ? Color.nw.bgHover : .clear)
            .overlay(alignment: .trailing) { if selected { Color.nw.running.frame(width: 3) } }
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
        VStack(alignment: .leading, spacing: AppLayout.blockSpacing) {
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
