import SwiftUI
import ShepherdProtocol
import ShepherdRemote

// Turn rendering (DESIGN.md › iOS). Derivations (turns, items,
// tool rows, group summary, head truncation) come from ShepherdRemote and are shared with
// the desktop; this file only lays them out at phone sizes.

/// User turn: trailing bubble, 15pt, radius 14 with a 4 bottom-trailing corner. No speaker label.
struct MobileUserTurn: View {
    let messages: [NativeThreadMessage]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(messages, id: \.entryID) { message in
                VStack(alignment: .leading, spacing: MobileTokens.spacing) {
                    ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                        if block.kind == .unsupportedImage {
                            Text("Image · view on your Mac").font(MobileTokens.caption12).foregroundStyle(tokens.textMuted)
                        } else {
                            Text(block.text).font(MobileTokens.bubble).lineSpacing(MobileTokens.bubbleLeading).textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(tokens.bubble, in: UnevenRoundedRectangle(
                    topLeadingRadius: MobileTokens.bubbleRadius, bottomLeadingRadius: MobileTokens.bubbleRadius,
                    bottomTrailingRadius: MobileTokens.bubbleCorner, topTrailingRadius: MobileTokens.bubbleRadius))
                .frame(maxWidth: 300, alignment: .trailing)
            }
            // The bridge carries no timestamps, so the micro line under the bubble stays empty.
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
    }
}

/// Agent turn: thinking disclosure, prose, collapsed tool groups, footer once settled.
struct MobileAgentTurn: View {
    let messages: [NativeThreadMessage]
    let running: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let items = nativeTurnItems(messages)
        let streaming = running && messages.contains { $0.status == "streaming" || $0.status == "running" }
        VStack(alignment: .leading, spacing: MobileTokens.blockSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                switch item {
                case .thinking(let text):
                    MobileThinkingDisclosure(text: text, streaming: streaming && index == items.count - 1)
                case .prose(let text):
                    MarkdownText(text: text)
                case .tools(let group):
                    MobileToolGroup(messages: group)
                case .note(let text):
                    Text(text).font(MobileTokens.caption12).foregroundStyle(tokens.textMuted)
                case .error(let text, let count):
                    Text(count > 1 ? "\(text) · ×\(count)" : text).font(MobileTokens.caption12).foregroundStyle(tokens.dangerText)
                }
            }
            // No timestamps or durations from the bridge; only the tool count is real, and it is
            // redundant when the turn ends on a group row that already states it.
            let endsOnGroup: Bool = if case .tools = items.last { true } else { false }
            if !streaming, !endsOnGroup {
                let tools = messages.count { $0.toolName != nil || $0.role == "toolResult" }
                if tools > 0 {
                    Text("\(tools) tool call\(tools == 1 ? "" : "s")").font(MobileTokens.micro).foregroundStyle(tokens.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent")
    }
}

struct MobileThinkingDisclosure: View {
    /// nil while streaming with nothing to show yet.
    let text: String?
    let streaming: Bool
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if streaming {
                        MobileSpinner(color: tokens.accent, size: 11)
                        Text("Thinking…").font(MobileTokens.caption12).italic().foregroundStyle(tokens.textTertiary)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(tokens.textMuted).frame(width: 12)
                        // The bridge carries no thinking duration, so the caption stays "Thought".
                        Text("Thought").font(MobileTokens.caption12).italic().foregroundStyle(tokens.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: MobileTokens.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text == nil)
            .accessibilityLabel(streaming ? "Thinking" : "Thought")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded, let text {
                Text(text).font(MobileTokens.bubble).italic().lineSpacing(MobileTokens.bubbleLeading)
                    .foregroundStyle(tokens.textTertiary).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { tokens.border.frame(width: 2) }
            }
        }
    }
}

/// Collapsed to one 44pt summary row ("6 tool calls · read 1 · edit 3 · bash 2"); expanded rows are 40pt.
struct MobileToolGroup: View {
    let messages: [NativeThreadMessage]
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let rows = messages.map(NativeToolRow.init)
        let summary = nativeToolGroupSummary(messages)
        let head = summary.split(separator: " · ", maxSplits: 1).map(String.init)
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    glyph(for: rows, tokens).frame(width: 14, height: 14)
                    Text(head.first ?? summary).font(MobileTokens.labelStrong).foregroundStyle(tokens.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if head.count > 1 {
                        Text(head[1]).font(MobileTokens.micro).foregroundStyle(tokens.textMuted).lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(tokens.textMuted).frame(width: 12)
                }
                .padding(.horizontal, 12)
                .frame(height: MobileTokens.toolSummaryHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tokens.borderSubtle.frame(height: 1)
                    MobileToolRowView(row: row)
                }
            }
        }
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
        .clipShape(RoundedRectangle(cornerRadius: MobileTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.border, lineWidth: 1))
    }

    @ViewBuilder private func glyph(for rows: [NativeToolRow], _ tokens: MobileTokens) -> some View {
        if rows.contains(where: { $0.state == .running }) {
            MobileSpinner(color: tokens.accent, size: 11)
        } else if rows.contains(where: { $0.state == .failed }) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(tokens.danger)
        } else {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(tokens.success)
        }
    }
}

/// 40pt row: glyph · name · head-truncated preview · result. Bash and any row with saved
/// output push a full-screen output view instead of expanding inline.
struct MobileToolRowView: View {
    let row: NativeToolRow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let label = HStack(spacing: 8) {
            Text(row.name).font(MobileTokens.mono).foregroundStyle(tokens.textTertiary).frame(width: 36, alignment: .leading).lineLimit(1)
            Text("\(nativeHeadTruncated(row.preview, max: 34))\(Text(row.previewSuffix ?? "").foregroundStyle(tokens.textMuted))")
                .foregroundStyle(tokens.text)
                .font(MobileTokens.mono).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if let diff = row.diff {
                    Text("\(Text("+\(diff.added)").foregroundStyle(tokens.successText)) \(Text("−\(diff.removed)").foregroundStyle(tokens.dangerText))")
                        .font(MobileTokens.micro)
                }
                if let result = row.results.first {
                    Text(result.text).font(MobileTokens.micro).foregroundStyle(tone(result.tone, tokens)).lineLimit(1)
                } else if row.state == .running {
                    Text("running").font(MobileTokens.micro).foregroundStyle(tokens.accentText)
                }
                if row.expandable {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(tokens.textMuted)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: MobileTokens.toolRowHeight)
        .contentShape(Rectangle())
        .background(row.state == .failed ? tokens.dangerBg : .clear)

        Group {
            if row.expandable {
                NavigationLink { MobileToolOutputView(row: row) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tool \(row.accessibilityLabel)")
        .accessibilityAddTraits(row.expandable ? .isButton : [])
    }

    private func tone(_ tone: NativeToolRow.Tone, _ tokens: MobileTokens) -> Color {
        switch tone {
        case .success: tokens.successText
        case .danger: tokens.dangerText
        case .muted: tokens.textMuted
        }
    }
}

/// Full-screen saved output for one tool call.
struct MobileToolOutputView: View {
    let row: NativeToolRow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: MobileTokens.blockSpacing) {
                Text(row.preview + (row.previewSuffix ?? "")).font(MobileTokens.code).foregroundStyle(tokens.text)
                Text(row.output).font(MobileTokens.output).lineSpacing(4)
                    .foregroundStyle(row.state == .failed ? tokens.dangerText : tokens.textSecondary)
                    .textSelection(.enabled)
                if row.truncated {
                    Text("Output truncated · full text on your Mac").font(MobileTokens.caption12).foregroundStyle(tokens.textMuted)
                }
            }
            .padding(MobileTokens.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(row.state == .failed ? tokens.dangerBg : tokens.muted)
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(tokens.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// Fenced code renders as mono blocks; everything else is inline Markdown prose with headings.
struct MarkdownText: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    private var segments: [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var code = false
        var buffer: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let body = buffer.joined(separator: "\n")
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append((code, body)) }
                buffer = []
                code.toggle()
            } else {
                buffer.append(String(line))
            }
        }
        let body = buffer.joined(separator: "\n")
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append((code, body)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTokens.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    CodeBlock(text: segment.text)
                } else {
                    ForEach(Array(segment.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("#") {
                            Text(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                                .font(MobileTokens.heading)
                        } else if !trimmed.isEmpty {
                            // Inline-only Markdown keeps line breaks but not list syntax; swap the marker for a bullet.
                            let listed = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                                .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? "•  " + $0.dropFirst(2) : $0 }
                                .joined(separator: "\n")
                            Text(Self.inline(listed, tokens: MobileTokens(scheme: scheme)))
                                .font(MobileTokens.prose)
                                .lineSpacing(MobileTokens.proseLeading)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .tint(MobileTokens(scheme: scheme).accent)
    }

    /// Inline code runs take the mono face at a size that sits inside 16pt prose, on `bg.hover`;
    /// left at the prose size they dominate the sentence.
    static func inline(_ text: String, tokens: MobileTokens) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = MobileTokens.inlineCode
            attributed[run.range].backgroundColor = tokens.hover
        }
        return attributed
    }
}

struct CodeBlock: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.trimmingCharacters(in: .newlines))
                .font(MobileTokens.code)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.muted)
        .clipShape(RoundedRectangle(cornerRadius: MobileTokens.spacing))
        .overlay(RoundedRectangle(cornerRadius: MobileTokens.spacing).strokeBorder(tokens.border, lineWidth: 1))
    }
}
