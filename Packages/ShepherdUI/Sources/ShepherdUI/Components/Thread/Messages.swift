import SwiftUI

// Messages (NWThread board): the user's bubble, the agent's prose and code, thinking, the turn
// footer and the turn-level error. Value inputs only; the app owns the thread.

/// The user's turn: right-aligned, at most 600pt, `bgBubble` with a 1px strong line, radius 8.
/// No avatar and no name; the time sits beneath. A follow-up typed while a turn runs is queued:
/// dashed and quiet until it sends. Its text follows `nwProseSize`.
public struct NWUserBubble: View {
    let text: String
    let attachments: [String]
    let timestamp: String?
    let isQueued: Bool
    let onEdit: (() -> Void)?
    let onSendNow: (() -> Void)?
    @Environment(\.nwProseSize) private var proseSize

    /// `attachments` name the images sent with the message. `onEdit` and `onSendNow` add the
    /// queued bubble's buttons; pass them only when the host can do it.
    public init(_ text: String, attachments: [String] = [], timestamp: String? = nil, isQueued: Bool = false,
                onEdit: (() -> Void)? = nil, onSendNow: (() -> Void)? = nil) {
        self.text = text
        self.attachments = attachments
        self.timestamp = timestamp
        self.isQueued = isQueued
        self.onEdit = onEdit
        self.onSendNow = onSendNow
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .trailing, spacing: 5) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                if !attachments.isEmpty {
                    HStack(spacing: NW.Space.s) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, name in
                            NWAttachmentChip(name, thumbnail: nil)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.nw(.body, size: proseSize))
                        .lineSpacing(max(0, NWTextStyle.body.lineSpacing(proseSize) - 1))
                        .foregroundStyle(isQueued ? nw.textSecondary : nw.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(isQueued ? Color.clear : nw.bgBubble, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .overlay {
                if isQueued {
                    RoundedRectangle(cornerRadius: NW.Radius.m)
                        .strokeBorder(nw.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    Color.clear.nwBorder(nw.lineStrong, radius: NW.Radius.m)
                }
            }
            .frame(maxWidth: NWThreadMetrics.bubbleMaxWidth, alignment: .trailing)
            if isQueued {
                HStack(spacing: NW.Space.m) {
                    Text("queued · sends when the turn ends").font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                    if let onEdit { Button("Edit", action: onEdit).buttonStyle(.nw(.ghost, size: .s)) }
                    if let onSendNow { Button("Send now", action: onSendNow).buttonStyle(.nw(.ghost, size: .s)) }
                }
            } else if let timestamp {
                Text(timestamp).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Prose

/// One Markdown block of agent prose, with its inline runs already styled.
public enum NWProseBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [NWProseListItem])
    case quote(AttributedString)
    case code(String, language: String?)
    case rule
}

public struct NWProseListItem: Equatable, Sendable {
    public var text: AttributedString
    /// One nested level: a sub-list or a fenced block under the item.
    public var children: [NWProseBlock]

    public init(text: AttributedString, children: [NWProseBlock] = []) {
        self.text = text
        self.children = children
    }
}

/// Agent prose: body 13.5/1.6 in `textPrimary` at the 640pt measure, blocks 12pt apart.
/// Headings at `.headline`, lists indented 20pt (one nested level), quotes on a
/// 2pt rule, fenced code through `code` (an `NWCodeBlock` unless the app highlights it).
/// Text follows `nwProseSize`.
public struct NWAgentProse<Code: View>: View {
    let blocks: [NWProseBlock]
    let maxWidth: CGFloat
    let code: (String, String?) -> Code

    public init(_ blocks: [NWProseBlock], maxWidth: CGFloat = NWThreadMetrics.proseMeasure,
                @ViewBuilder code: @escaping (String, String?) -> Code) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWProseBlocks(blocks: blocks, code: code)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

extension NWAgentProse where Code == NWCodeBlock {
    public init(_ blocks: [NWProseBlock], maxWidth: CGFloat = NWThreadMetrics.proseMeasure) {
        self.init(blocks, maxWidth: maxWidth) { NWCodeBlock($0, language: $1) }
    }
}

private struct NWProseBlocks<Code: View>: View {
    let blocks: [NWProseBlock]
    var nested = false
    let code: (String, String?) -> Code
    @Environment(\.nwProseSize) private var size

    var body: some View {
        let nw = Color.nw
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(_, let text):
                Text(text).font(.nw(.headline, size: size)).lineSpacing(NWTextStyle.headline.lineSpacing(size))
                    .foregroundStyle(nw.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, nested ? 0 : NW.Space.xs)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph(let text):
                Text(text).nwText(.body, size: size).foregroundStyle(nw.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .quote(let text):
                Text(text).nwText(.body, size: size).italic().foregroundStyle(nw.textSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, NW.Space.l)
                    .overlay(alignment: .leading) { nw.lineStrong.frame(width: 2) }
            case .code(let text, let language):
                code(text, language)
            case .rule:
                NWHairline().padding(.vertical, NW.Space.xs)
            case .list(let ordered, let start, let items):
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            // The marker ends 6pt before the item, as a list's outside marker does.
                            Text(ordered ? "\(start + index)." : "•")
                                .font(.nw(.body, size: size)).foregroundStyle(nw.textPrimary).monospacedDigit()
                                .fixedSize()
                                .frame(width: NWThreadMetrics.listIndent - NW.Space.s, alignment: .trailing)
                                .padding(.trailing, NW.Space.s)
                                .accessibilityHidden(!ordered)
                            VStack(alignment: .leading, spacing: NW.Space.xs) {
                                Text(item.text).nwText(.body, size: size).foregroundStyle(nw.textPrimary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                NWProseBlocks(blocks: item.children, nested: true, code: code)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Code

/// A fenced block (NWThread board): `bgSunken`, a 1px line, radius 8; a 28pt header with the
/// language and a copy button that appears on hover (and for keyboard focus); code in mono 12
/// at 1.6, syntax colored when `highlighted` is given.
public struct NWCodeBlock: View {
    let code: String
    let language: String?
    let highlighted: AttributedString?
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    public init(_ code: String, language: String?, highlighted: AttributedString? = nil) {
        self.code = code
        self.language = language
        self.highlighted = highlighted
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Text(language ?? "code").font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                Spacer(minLength: 0)
                Button {
                    NWPasteboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "square.on.square").font(.system(size: 12))
                }
                .buttonStyle(.nwIcon(size: NWThreadMetrics.codeCopyButton))
                .focused($copyFocused)
                .opacity(hovering || copyFocused || copied ? 1 : 0)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, NW.Space.l)
            .padding(.trailing, NW.Space.s)
            .frame(height: NWThreadMetrics.codeHeaderHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView(.horizontal) {
                Group {
                    if let highlighted { Text(highlighted) } else { Text(code) }
                }
                .font(.nw(.code))
                .lineSpacing(NWTextStyle.code.lineSpacing + 0.6)
                .foregroundStyle(nw.textPrimary)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, NW.Space.l)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }
}

// MARK: Thinking

/// The model's thinking (NWThread board). Collapsed: a 10pt chevron and "Thought for 4s" in
/// italic 12. Expanded: the text in italic 12.5 on a 2pt rule. Live: a spinner, "Thinking…"
/// and its seconds, collapsing to "Thought for Ns" when it ends.
public struct NWThinking: View {
    let title: String
    let text: String
    @Binding var isExpanded: Bool
    let live: Bool
    let since: Date?
    let seconds: Double?

    /// Finished thinking: `title` is "Thought for 4s".
    public init(_ title: String, text: String, isExpanded: Binding<Bool>) {
        self.title = title
        self.text = text
        _isExpanded = isExpanded
        live = false
        since = nil
        seconds = nil
    }

    /// Thinking that is still streaming: seconds tick from `since` when known, else show
    /// `seconds` as the host last measured them.
    public init(liveSince since: Date?, seconds: Double? = nil) {
        title = "Thinking…"
        text = ""
        _isExpanded = .constant(false)
        live = true
        self.since = since
        self.seconds = seconds
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let nw = Color.nw
        if live {
            HStack(spacing: NW.Space.m) {
                ProgressView().progressViewStyle(.nwSpinner(size: 12, color: nw.textSecondary))
                Text(title).font(.nwSans(12)).italic().foregroundStyle(nw.textSecondary)
                if let since {
                    NWElapsedText(since: since, style: .long).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                } else if let seconds {
                    Text(NWDuration.text(seconds, .long)).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                }
            }
            .frame(minHeight: NWThreadMetrics.activityHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thinking")
        } else {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Button {
                    withAnimation(NW.Motion.pane.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: NW.Space.s) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: NWThreadMetrics.chevron, height: NWThreadMetrics.chevron)
                        Text(title).font(.nwSans(12)).italic()
                    }
                    .foregroundStyle(nw.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nwFocusRing(radius: NW.Radius.xs)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the model's thinking")
                if isExpanded {
                    Text(text)
                        .font(.nwSans(12.5)).italic()
                        .lineSpacing(NWTextStyle.caption.lineSpacing + 2)
                        .foregroundStyle(nw.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, NW.Space.xxs)
                        .padding(.leading, NW.Space.l)
                        .overlay(alignment: .leading) { nw.lineStrong.frame(width: 2) }
                        .frame(maxWidth: NWThreadMetrics.proseMeasure, alignment: .leading)
                }
            }
        }
    }
}

// MARK: Turn footer and errors

/// After a finished turn: copy and retry (24pt icon buttons), then "2:44 PM · 3m 12s · 23 tool
/// calls" in mono 10.5 tertiary, and "· 3 subagents" as a link when given.
public struct NWTurnFooter: View {
    let meta: String
    let link: String?
    let onLink: (() -> Void)?
    let onCopy: (() -> Void)?
    let onRetry: (() -> Void)?
    @State private var copied = false

    public init(meta: String, link: String? = nil, onLink: (() -> Void)? = nil,
                onCopy: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.meta = meta
        self.link = link
        self.onLink = onLink
        self.onCopy = onCopy
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: NW.Space.xs) {
            if let onCopy {
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "square.on.square").font(.system(size: 12)) }
                .buttonStyle(.nwIcon(size: NWThreadMetrics.footerButton))
                .help("Copy the reply")
                .accessibilityLabel(copied ? "Copied" : "Copy response")
            }
            if let onRetry {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.nwIcon(size: NWThreadMetrics.footerButton))
                    .help("Send this turn's prompt again")
                    .accessibilityLabel("Retry turn")
            }
            HStack(spacing: 0) {
                Text(meta).monospacedDigit()
                if let link, let onLink {
                    if !meta.isEmpty { Text(" · ") }
                    Button(link, action: onLink).buttonStyle(.nwLink(font: .nwMono(10.5)))
                }
            }
            .font(.nwMono(10.5))
            .foregroundStyle(Color.nw.textTertiary)
            .padding(.leading, NW.Space.xs)
        }
    }
}

/// A turn that failed as a whole ("Model overloaded — the turn stopped after 6 tool calls."),
/// on `failedTint` with Retry. Tool failures stay in their activity lines.
public struct NWTurnError: View {
    let message: String
    let count: Int
    let retry: (() -> Void)?

    public init(_ message: String, count: Int = 1, retry: (() -> Void)? = nil) {
        self.message = message
        self.count = count
        self.retry = retry
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(nw.failed)
                .frame(width: 14, height: 14)
            Text(message).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > 1 {
                Text("×\(count)").font(.nwMono(11)).foregroundStyle(nw.textTertiary).monospacedDigit()
            }
            if let retry {
                Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.secondary, size: .s))
            }
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, 10)
        .background(nw.failedTint, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .accessibilityElement(children: .contain)
    }
}

/// The tail row while an agent runs: a running spinner and what it is doing, in italic 12.
public struct NWWorkingRow: View {
    let label: String

    public init(_ label: String) { self.label = label }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            ProgressView().progressViewStyle(.nwSpinner(size: 12))
            Text(label).font(.nwSans(12)).italic().foregroundStyle(Color.nw.textSecondary)
        }
        .padding(.leading, NW.Space.xs)
        .frame(minHeight: NWThreadMetrics.activityHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
