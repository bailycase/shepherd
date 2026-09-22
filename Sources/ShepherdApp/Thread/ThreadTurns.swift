import SwiftUI
import AppKit
import ShepherdDesign
import ShepherdProtocol
import ShepherdRemote

/// The user's turn: a trailing bubble on `bgBubble`, max 600pt, radius 12 with a 4pt
/// bottom-trailing corner, the time beneath. No speaker label: shape carries the role.
struct UserTurn: View {
    let messages: [NativeThreadMessage]
    /// Micro caption under the bubble; "10:58 · from parent" in a child's transcript.
    var caption: String?
    var small = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(messages, id: \.entryID) { message in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                        if block.kind == .unsupportedImage {
                            Label("Image", systemImage: "photo").font(Fonts.caption).foregroundStyle(Tokens.textTertiary)
                        } else {
                            Text(block.text).font(small ? Fonts.sans(13.5) : Fonts.bodySmall).foregroundStyle(Tokens.text)
                                .lineSpacing(Fonts.bodySmallLeading).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Tokens.bgBubble, in: UnevenRoundedRectangle(topLeadingRadius: Radius.xl, bottomLeadingRadius: Radius.xl,
                                                                         bottomTrailingRadius: Radius.bubbleTail, topTrailingRadius: Radius.xl))
                .opacity(message.status == "pending" ? 0.7 : 1)
                .frame(maxWidth: Metrics.userMaxWidth, alignment: .trailing)
            }
            if let caption {
                Text(caption).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// One agent turn (spec §4): thinking, prose, grouped tool calls, subagent cards, then the
/// footer once the turn has finished.
struct AgentTurn: View {
    let messages: [NativeThreadMessage]
    /// True while this turn is the one streaming.
    let live: Bool
    var small = false
    var subagents = NativeSubagentPlacement()
    var subagentActions: SubagentActions? = nil
    /// Timestamp (ms) of the user message that opened this turn: the footer's time and duration.
    var startedAt: Double? = nil
    /// Resend the prompt that opened this turn; nil hides Retry.
    var retry: (() -> Void)? = nil
    var review: ((String) -> Void)? = nil

    var body: some View {
        let items = nativeTurnItems(messages)
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                switch item {
                case .thinking(let text):
                    ThinkingDisclosure(text: text, seconds: thinkingSeconds(before: index, in: items),
                                       streaming: live && index == items.count - 1)
                case .prose(let text):
                    Prose(text: text, small: small)
                case .tools(let group):
                    ToolGroup(messages: group, small: small, subagents: subagents, subagentActions: subagentActions, review: review)
                        .padding(.vertical, 4)
                case .error(let text, let count):
                    // A failed provider request is a status line, not prose: pi retries.
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .semibold))
                        Text("Request failed · \(text)").lineLimit(1).truncationMode(.tail)
                        if count > 1 { Text("×\(count)").monospacedDigit().foregroundStyle(Tokens.textMuted) }
                    }
                    .font(Fonts.caption).foregroundStyle(Tokens.dangerText)
                    .help(text)
                case .note(let text):
                    Text(text).font(Fonts.caption).foregroundStyle(Tokens.textMuted)
                        .lineLimit(3).truncationMode(.tail).help(text).textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Tokens.border.frame(width: 2) }
                        .frame(maxWidth: Metrics.proseMaxWidth, alignment: .leading)
                }
            }
            // Runs with no spawn row in this turn render after it; a folded group already
            // placed them in its strip or ledger unless there was no spawn row to fold into.
            if let subagentActions, !subagents.trailing.isEmpty,
               subagents.byToolCall.isEmpty || !subagentGroupFolds(subagents) {
                SubagentStack(runs: subagents.byToolCall.isEmpty ? subagents.all : subagents.trailing, actions: subagentActions)
            }
            if !live, !items.isEmpty {
                // Spawn rows the cards replaced are not tool calls the reader can see.
                TurnFooter(messages: messages.filter { $0.toolCallID.map { subagents.byToolCall[$0] == nil } ?? true },
                           startedAt: startedAt, subagents: subagents.all, inspect: subagentActions?.inspect, retry: retry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The thinking duration the host observed for the message carrying the thinking item at
    /// `index`: thinking items come from messages' thinking blocks, in order.
    private func thinkingSeconds(before index: Int, in items: [NativeTurnItem]) -> Double? {
        let durations = messages.flatMap { message in
            message.blocks.filter { $0.kind == .thinking }.map { _ in message.thinkingSeconds }
        }
        let ordinal = items[...index].count { if case .thinking = $0 { true } else { false } } - 1
        return durations.indices.contains(ordinal) ? durations[ordinal] : nil
    }
}

/// "Thought for 4s", collapsed by default; while streaming, a spinner and "Thinking…".
/// Expanded: tertiary italic prose on a 2pt rule.
struct ThinkingDisclosure: View {
    let text: String
    var seconds: Double?
    var streaming = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caption: String {
        if streaming { return "Thinking…" }
        guard let seconds, seconds >= 0.5 else { return "Thought" }
        return "Thought for \(seconds < 60 ? "\(Int(seconds.rounded()))s" : nativeDurationText(seconds))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if streaming {
                        Spinner(size: 12)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(Tokens.textMuted).frame(width: 12)
                    }
                    Text(caption).font(Fonts.caption).italic().foregroundStyle(Tokens.textTertiary)
                }
                .padding(.vertical, 4)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(caption)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text(text).font(Fonts.sans(13)).italic().lineSpacing(3)
                    .foregroundStyle(Tokens.textTertiary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20).padding(.vertical, 4)
                    .overlay(alignment: .leading) { Tokens.border.frame(width: 2).padding(.leading, 5) }
                    .frame(maxWidth: Metrics.proseMaxWidth, alignment: .leading)
            }
        }
    }
}

/// After a finished turn (spec §4): copy and retry, then "time · duration · N tool calls" and
/// "· n subagents" as a link to the first run.
struct TurnFooter: View {
    let messages: [NativeThreadMessage]
    var startedAt: Double?
    var subagents: [ChildRun] = []
    var inspect: ((ChildRun) -> Void)?
    var retry: (() -> Void)?
    @State private var copied = false

    var body: some View {
        let tools = messages.count { $0.toolName != nil || $0.role == "toolResult" }
        let prose = messages.filter { $0.role == "assistant" && $0.toolName == nil }
            .flatMap(\.blocks).filter { $0.kind == .text }.map(\.text)
        let time = nativeTurnTimeText(startedAt: startedAt, endedAt: messages.compactMap(\.timestamp).max())
        let ordered = subagents.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        HStack(spacing: 2) {
            if !prose.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prose.joined(separator: "\n\n"), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(IconButtonStyle(bordered: false))
                .help("Copy the reply")
                .accessibilityLabel("Copy response")
            }
            if let retry {
                Button(action: retry) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(IconButtonStyle(bordered: false))
                    .help("Send this turn's prompt again")
                    .accessibilityLabel("Retry turn")
            }
            HStack(spacing: 0) {
                if let time { Text(time).monospacedDigit() }
                if tools > 0 {
                    if time != nil { Text(" · ") }
                    Text("\(tools) tool call\(tools == 1 ? "" : "s")")
                }
                if let first = ordered.first, let inspect {
                    if time != nil || tools > 0 { Text(" · ") }
                    Button("\(ordered.count) subagent\(ordered.count == 1 ? "" : "s")") { inspect(first) }
                        .buttonStyle(LinkButtonStyle(font: Fonts.micro))
                        .accessibilityLabel("Open \(first.role ?? first.label) in the inspector")
                }
            }
            .font(Fonts.micro).foregroundStyle(Tokens.textMuted).padding(.leading, 6)
        }
    }
}

/// The tail row while the agent runs: a spinner (a pulsing dot under Reduce Motion) and the
/// current activity in tertiary italic.
struct WorkingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Spinner(size: 12)
            Text(label).font(Fonts.caption).italic().foregroundStyle(Tokens.textTertiary)
        }
        .frame(height: Metrics.workingRowHeight)
        .padding(.leading, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
