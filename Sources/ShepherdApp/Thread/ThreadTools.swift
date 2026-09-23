import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Consecutive tool calls as one bordered group of one-line rows (spec §5). Subagent spawn
/// calls are replaced by their cards where they happened.
struct ToolGroup: View {
    let messages: [NativeThreadMessage]
    var small = false
    var subagents = NativeSubagentPlacement()
    var subagentActions: SubagentActions? = nil
    /// Opens the review pane at a file an edit or write touched ("review ›").
    var review: ((String) -> Void)? = nil

    var body: some View {
        let segments = subagentActions == nil ? [ToolSegment.rows(messages)] : toolSegments(messages, placement: subagents)
        VStack(alignment: .leading, spacing: AppLayout.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .rows(let rows):
                    rowGroup(rows.map(NativeToolRow.init))
                case .subagents(let runs):
                    if let subagentActions {
                        SubagentStack(runs: runs, turnLive: subagents.all.contains { !$0.isTerminal }, actions: subagentActions)
                    }
                }
            }
        }
    }

    private func rowGroup(_ rows: [NativeToolRow]) -> some View {
        // One name column per group so previews line up: the spec's 40pt, widened for longer
        // names up to a limit (the rest truncate in the middle with the full name on hover).
        let longest = rows.map(\.name.count).max() ?? 0
        let nameWidth = min(76, max(AppLayout.toolNameWidth, CGFloat(longest) * 7.6)) * ThemeStore.shared.textScale
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { NWHairline() }
                ToolRowView(row: row, nameWidth: nameWidth, small: small, review: review)
            }
        }
        .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
    }
}

/// One call: status glyph · name · preview · result · duration · chevron (spec §5). Expands to
/// its saved output (12 lines, then a sheet); ⌥-click shows the raw call.
struct ToolRowView: View {
    let row: NativeToolRow
    var nameWidth: CGFloat = AppLayout.toolNameWidth
    var small = false
    var review: ((String) -> Void)? = nil
    @State private var expanded = false
    @State private var showCall = false
    @State private var showOutput = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded { output }
        }
        .background(expanded ? (row.state == .failed ? Color.nw.failedTint : Color.nw.bgSunken) : hovering ? Color.nw.bgHover : .clear)
        .sheet(isPresented: $showOutput) {
            ToolOutputSheet(title: "\(row.name) · \(row.preview)", output: row.output, truncated: row.truncated) { showOutput = false }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            NWStateGlyph(AgentState(row.state))
            Text(row.name).font(Font.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                .frame(width: nameWidth, alignment: .leading).lineLimit(1).truncationMode(.middle)
                .help(row.name)
            Text("\(Text(row.preview).foregroundStyle(Color.nw.textPrimary))\(Text(row.previewSuffix ?? "").foregroundStyle(Color.nw.textTertiary))")
                .font(Font.nw(.mono)).lineLimit(1).truncationMode(.tail)
                .help(row.preview + (row.previewSuffix ?? ""))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let diff = row.diff { NWDiffStat(added: diff.added, removed: diff.removed) }
                ForEach(Array(row.results.enumerated()), id: \.offset) { _, result in
                    Text(result.text).font(Font.nw(.micro)).foregroundStyle(tone(result.tone)).lineLimit(1)
                }
                if row.state == .running, row.results.isEmpty {
                    Text("running").font(Font.nw(.micro)).foregroundStyle(Color.nw.running)
                }
                if let path = row.reviewPath, let review {
                    Button("review ›") { review(path) }
                        .buttonStyle(NWLinkButtonStyle(font: Font.nw(.micro)))
                        .accessibilityLabel("Review \(path)")
                }
                duration
                if row.expandable {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(Color.nw.textTertiary).frame(width: 12)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: small ? AppLayout.toolRowHeightSmall : AppLayout.toolRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && row.expandable }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.option), row.arguments != nil { showCall = true; return }
            guard row.expandable else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
        }
        .contextMenu {
            if row.arguments != nil { Button("Show Call") { showCall = true } }
            if !row.output.isEmpty {
                Button("Open Output") { showOutput = true }
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.output, forType: .string)
                }
            }
        }
        .popover(isPresented: $showCall) {
            ScrollView {
                Text(row.arguments ?? "").font(Font.nw(.code)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(width: 440, height: 260)
            .background(Color.nw.bgRaised)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.expandable ? (expanded ? "Expanded" : "Collapsed") : "")
        .accessibilityAddTraits(row.expandable ? .isButton : [])
        .accessibilityAction { if row.expandable { expanded.toggle() } }
        .accessibilityAction(named: "Show call") { showCall = true }
    }

    @ViewBuilder private var duration: some View {
        if row.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let value = row.duration(now: context.date) {
                    Text(value.text).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit()
                }
            }
        } else if let value = row.duration(now: Date()) {
            Text(value.text).font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit()
        }
    }

    private var output: some View {
        let lines = row.output.split(separator: "\n", omittingEmptySubsequences: false)
        // A running row streams its tail; a finished one shows its head.
        let live = row.state == .running
        let limit = AppLayout.toolOutputMaxLines
        let shown = live ? lines.suffix(limit) : lines.prefix(limit)
        return VStack(alignment: .leading, spacing: 6) {
            if live, lines.count > limit {
                Text("… \(lines.count - limit) earlier lines").font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            Text(shown.joined(separator: "\n"))
                .font(Font.nw(.code)).lineSpacing(NWTextStyle.code.lineSpacing)
                .foregroundStyle(row.state == .failed ? Color.nw.failed : Color.nw.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !live, lines.count > limit || row.truncated {
                Button(lines.count > limit ? "… \(lines.count - limit) more lines" : "Output truncated · open") { showOutput = true }
                    .buttonStyle(NWLinkButtonStyle(color: row.state == .failed ? Color.nw.failed : Color.nw.running))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 4, leading: AppLayout.toolOutputIndent, bottom: 12, trailing: 12))
    }

    private func tone(_ tone: NativeToolRow.Tone) -> Color {
        // On an expanded failed row only dangerText or neutral text may sit on dangerBg.
        let onDanger = expanded && row.state == .failed
        return switch tone {
        case .success: onDanger ? Color.nw.textSecondary : Color.nw.done
        case .danger: Color.nw.failed
        case .muted: Color.nw.textTertiary
        }
    }
}

/// The full output of one call, from a row's "… n more lines".
struct ToolOutputSheet: View {
    let title: String
    let output: String
    let truncated: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(Font.nw(.mono, weight: .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .buttonStyle(NWButtonStyle(.secondary, size: .s))
                Button("Done", action: close).buttonStyle(NWButtonStyle(.primary, size: .s)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: AppLayout.headerHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView([.vertical, .horizontal]) {
                Text(output).font(Font.nw(.code)).lineSpacing(NWTextStyle.code.lineSpacing).foregroundStyle(Color.nw.textSecondary)
                    .textSelection(.enabled).fixedSize().padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if truncated {
                Text("The host clipped this output; the full text is in pi's session file.")
                    .font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).padding(12)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .background(Color.nw.bgWindow)
    }
}

/// A tool group split around its spawn rows: plain rows stay grouped, each spawn position
/// becomes a card stack. Tool rows that spawned nothing visible stay tool rows.
enum ToolSegment: Equatable {
    case rows([NativeThreadMessage])
    case subagents([ChildRun])
}

/// A turn's runs fold into one stack (the strip, or the ledger once every run is terminal).
func subagentGroupFolds(_ placement: NativeSubagentPlacement) -> Bool {
    placement.all.count > NativeRunsStripSummary.collapseThreshold || nativeSubagentGroupIsTerminal(placement.all)
}

func toolSegments(_ group: [NativeThreadMessage], placement: NativeSubagentPlacement) -> [ToolSegment] {
    // With a strip or a finished group, every spawn row folds into one stack at the first
    // spawn's position: one surface for the turn's subagents.
    let all = placement.all
    let folds = subagentGroupFolds(placement)
    var segments: [ToolSegment] = []
    var rows: [NativeThreadMessage] = []
    var placed = false
    for message in group {
        // Once cards represent these children, their bookkeeping calls have no second surface;
        // unassociated calls stay visible so errors are not hidden.
        if !all.isEmpty, ["shepherd_child_wait", "shepherd_child_result"].contains(message.toolName ?? "") { continue }
        guard let id = message.toolCallID, let runs = placement.byToolCall[id] else { rows.append(message); continue }
        if !rows.isEmpty { segments.append(.rows(rows)); rows = [] }
        if folds {
            if !placed { segments.append(.subagents(all)); placed = true }
        } else {
            segments.append(.subagents(runs))
        }
    }
    if !rows.isEmpty { segments.append(.rows(rows)) }
    return segments
}
