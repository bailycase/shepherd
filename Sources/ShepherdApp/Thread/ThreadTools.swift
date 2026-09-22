import SwiftUI
import AppKit
import ShepherdDesign
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
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
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
        let nameWidth = min(76, max(Metrics.toolNameWidth, CGFloat(longest) * 7.6)) * ThemeStore.shared.textScale
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Tokens.borderSubtle.frame(height: 1) }
                ToolRowView(row: row, nameWidth: nameWidth, small: small, review: review)
            }
        }
        .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Tokens.border, lineWidth: 1))
    }
}

/// One call: status glyph · name · preview · result · duration · chevron (spec §5). Expands to
/// its saved output (12 lines, then a sheet); ⌥-click shows the raw call.
struct ToolRowView: View {
    let row: NativeToolRow
    var nameWidth: CGFloat = Metrics.toolNameWidth
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
        .background(expanded ? (row.state == .failed ? Tokens.dangerBg : Tokens.bgMuted) : hovering ? Tokens.bgHover : .clear)
        .sheet(isPresented: $showOutput) {
            ToolOutputSheet(title: "\(row.name) · \(row.preview)", output: row.output, truncated: row.truncated) { showOutput = false }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RunStateGlyph(glyphState)
            Text(row.name).font(Fonts.code).foregroundStyle(Tokens.textTertiary)
                .frame(width: nameWidth, alignment: .leading).lineLimit(1).truncationMode(.middle)
                .help(row.name)
            (Text(row.preview).foregroundStyle(Tokens.text) + Text(row.previewSuffix ?? "").foregroundStyle(Tokens.textMuted))
                .font(Fonts.code).lineLimit(1).truncationMode(.tail)
                .help(row.preview + (row.previewSuffix ?? ""))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let diff = row.diff { DiffStat(added: diff.added, removed: diff.removed) }
                ForEach(Array(row.results.enumerated()), id: \.offset) { _, result in
                    Text(result.text).font(Fonts.micro).foregroundStyle(tone(result.tone)).lineLimit(1)
                }
                if row.state == .running, row.results.isEmpty {
                    Text("running").font(Fonts.micro).foregroundStyle(Tokens.accentText)
                }
                if let path = row.reviewPath, let review {
                    Button("review ›") { review(path) }
                        .buttonStyle(LinkButtonStyle(font: Fonts.micro))
                        .accessibilityLabel("Review \(path)")
                }
                duration
                if row.expandable {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(Tokens.textMuted).frame(width: 12)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: small ? Metrics.toolRowHeightSmall : Metrics.toolRowHeight)
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
                Text(row.arguments ?? "").font(Fonts.output).foregroundStyle(Tokens.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(width: 440, height: 260)
            .background(Tokens.bgRaised)
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
                    Text(value.text).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit()
                }
            }
        } else if let value = row.duration(now: Date()) {
            Text(value.text).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit()
        }
    }

    private var output: some View {
        let lines = row.output.split(separator: "\n", omittingEmptySubsequences: false)
        // A running row streams its tail; a finished one shows its head.
        let live = row.state == .running
        let limit = Metrics.toolOutputMaxLines
        let shown = live ? lines.suffix(limit) : lines.prefix(limit)
        return VStack(alignment: .leading, spacing: 6) {
            if live, lines.count > limit {
                Text("… \(lines.count - limit) earlier lines").font(Fonts.caption).foregroundStyle(Tokens.textMuted)
            }
            Text(shown.joined(separator: "\n"))
                .font(Fonts.output).lineSpacing(Fonts.outputLeading)
                .foregroundStyle(row.state == .failed ? Tokens.dangerText : Tokens.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !live, lines.count > limit || row.truncated {
                Button(lines.count > limit ? "… \(lines.count - limit) more lines" : "Output truncated · open") { showOutput = true }
                    .buttonStyle(LinkButtonStyle(color: row.state == .failed ? Tokens.dangerText : Tokens.accentText))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 4, leading: Metrics.toolOutputIndent, bottom: 12, trailing: 12))
    }

    private var glyphState: RunState {
        switch row.state {
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    private func tone(_ tone: NativeToolRow.Tone) -> Color {
        // On an expanded failed row only dangerText or neutral text may sit on dangerBg.
        let onDanger = expanded && row.state == .failed
        return switch tone {
        case .success: onDanger ? Tokens.textSecondary : Tokens.successText
        case .danger: Tokens.dangerText
        case .muted: Tokens.textMuted
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
                Text(title).font(Fonts.codeMedium).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                Button("Done", action: close).buttonStyle(ShepherdButtonStyle(.primary, size: .small)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: Metrics.headerHeight)
            .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
            ScrollView([.vertical, .horizontal]) {
                Text(output).font(Fonts.output).lineSpacing(Fonts.outputLeading).foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled).fixedSize().padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if truncated {
                Text("The host clipped this output; the full text is in pi's session file.")
                    .font(Fonts.caption).foregroundStyle(Tokens.textMuted).padding(12)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .background(Tokens.bgSurface)
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
