import SwiftUI

// Messages (NWThread board): the user's bubble, the agent's prose and code, thinking, the turn
// footer and the turn-level error. Value inputs only; the app owns the thread.

/// When a message's quiet details show: the bubble's time and a finished turn's footer. Only
/// while the pointer is over the message (`hovering`, which the host tracks for the whole
/// message), while one of their controls has keyboard focus, while a copy confirms, or while
/// VoiceOver runs, so they stay reachable. Either way they keep their place and only fade
/// (`.hover`): showing them never moves or resizes anything.
enum NWMessageDetails {
    static func shown(hovering: Bool, focused: Bool = false, confirming: Bool = false, voiceOver: Bool) -> Bool {
        NWPlatform.showsHoverDetails || hovering || focused || confirming || voiceOver
    }
}

/// The user's turn: right-aligned, at most 600pt, `bgBubble` with a 1px strong line, radius 8.
/// No avatar and no name; the time sits beneath, shown only while the message is hovered. A
/// message steered into a running turn wears "Steered" above it and a `running` line. Its text
/// follows `nwProseSize`.
public struct NWUserBubble: View {
    /// How the message reached pi.
    public enum Origin: Sendable {
        /// Sent, or delivered from the queue.
        case sent
        /// Steered into a running turn, where pi read it.
        case steered
    }

    /// The "Steered" label's glyph.
    static let steeredGlyph: CGFloat = 11

    let text: String
    let attachments: [String]
    let timestamp: String?
    let note: String?
    let revealed: Bool
    let origin: Origin
    @Environment(\.nwProseSize) private var proseSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// `attachments` name the images sent with the message. `timestamp` shows only while
    /// `revealed` (the pointer is over the message); `note` follows it and always shows ("from
    /// parent").
    public init(_ text: String, attachments: [String] = [], timestamp: String? = nil, note: String? = nil,
                revealed: Bool = false, origin: Origin = .sent) {
        self.text = text
        self.attachments = attachments
        self.timestamp = timestamp
        self.note = note
        self.revealed = revealed
        self.origin = origin
    }

    public var body: some View {
        let nw = Color.nw
        let steered = origin == .steered
        VStack(alignment: .trailing, spacing: 5) {
            if steered {
                HStack(spacing: NW.Space.xs) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: Self.steeredGlyph, weight: .medium))
                    Text("Steered").font(.nw(.caption, weight: .medium))
                }
                .foregroundStyle(nw.running)
            }
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
                        .foregroundStyle(nw.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(nw.bgBubble, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(steered ? nw.running : nw.lineStrong, radius: NW.Radius.m)
            .frame(maxWidth: NWThreadMetrics.bubbleMaxWidth, alignment: .trailing)
            if timestamp != nil || note != nil {
                caption
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    /// "2:41 PM", or "10:58 · from parent": the time (and its separator) fades in place beside a
    /// note that always shows.
    private var caption: some View {
        let shown = NWMessageDetails.shown(hovering: revealed, voiceOver: voiceOver)
        return HStack(spacing: 0) {
            if let timestamp {
                Text(note == nil ? timestamp : "\(timestamp) · ").monospacedDigit()
                    .opacity(shown ? 1 : 0)
                    .nwAnimation(.hover, value: shown)
            }
            if let note { Text(note) }
        }
        .font(.nwMono(10.5))
        .foregroundStyle(Color.nw.textTertiary)
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
                    .overlay(alignment: .leading) { nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
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
    /// Copies so far: each one pops the check.
    @State private var copies = 0
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
                    copies += 1
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    NWCopyGlyph(copied: copied, copies: copies)
                }
                .buttonStyle(.nwIcon(size: NWThreadMetrics.codeCopyButton))
                .focused($copyFocused)
                .opacity(NWPlatform.showsHoverDetails || hovering || copyFocused || copied ? 1 : 0)
                .nwAnimation(.hover, value: hovering || copyFocused || copied)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, NW.Space.l)
            .padding(.trailing, NW.Space.s)
            .frame(height: NWThreadMetrics.codeHeaderHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            // The code draws directly when its longest line fits the column, and scrolls
            // sideways only when it does not: the scroll view was a fifth of the block's cost.
            ViewThatFits(in: .horizontal) {
                codeText
                ScrollView(.horizontal) { codeText }
                    .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }

    /// The code at its natural width, unwrapped.
    private var codeText: some View {
        Group {
            if let highlighted { Text(highlighted) } else { Text(code) }
        }
        .font(.nw(.code))
        .lineSpacing(NWTextStyle.code.lineSpacing + 0.6)
        .foregroundStyle(Color.nw.textPrimary)
        .textSelection(.enabled)
        .fixedSize()
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, 10)
    }
}

/// A copy button's glyph (code blocks, the turn footer): two squares that turn into a check
/// for a moment after each copy, replacing the symbol and popping.
struct NWCopyGlyph: View {
    let copied: Bool
    /// Copies so far: each one pops.
    let copies: Int

    var body: some View {
        Image(systemName: copied ? "checkmark" : "square.on.square").font(.system(size: 12))
            .nwContentTransition(.symbol)
            .nwAnimation(.content, value: copied)
            .nwPop(trigger: copies)
    }
}

// MARK: Thinking

/// The model's thinking (NWThread board). Collapsed: a 10pt chevron and "Thought for 4s" in
/// italic 12. Expanded: the text in italic 12.5 on a 2pt rule. Live (LiveText): "› Thinking…"
/// shimmering on a 26pt line, the thread's live indicator between tools, settling into "Thought
/// for Ns" when it ends. With no text (the model kept its reasoning back), finished thinking is
/// the plain line, not a control.
public struct NWThinking: View {
    let title: String
    let spokenTitle: String
    let text: String
    @Binding var isExpanded: Bool
    let live: Bool

    /// Finished thinking: `title` is "Thought for 4s", `spokenTitle` how VoiceOver says it
    /// ("Thought for 4 seconds"). An empty `text` draws the plain line.
    public init(_ title: String, text: String, isExpanded: Binding<Bool>, spokenTitle: String? = nil) {
        self.title = title
        self.spokenTitle = spokenTitle ?? title
        self.text = text
        _isExpanded = isExpanded
        live = false
    }

    private init() {
        title = "Thinking…"
        spokenTitle = "Thinking"
        text = ""
        _isExpanded = .constant(false)
        live = true
    }

    /// pi thinking between tools: its thinking streaming, or nothing yet to show for it.
    public static func live() -> NWThinking { NWThinking() }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When thinking ends, "Thinking…" cross-fades into "Thought for 4s" in place, as long as
    /// the caller keeps one `NWThinking` for both (the same view identity).
    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            ZStack(alignment: .leading) {
                if live { liveHeader.nwTransition(.content) }
                else if text.isEmpty { plainLine.nwTransition(.content) }
                else { toggle.nwTransition(.content) }
            }
            .nwAnimation(.content, value: live)
            if isExpanded, !live, !text.isEmpty {
                Text(text)
                    .font(.nwSans(12.5)).italic()
                    .lineSpacing(NWTextStyle.caption.lineSpacing + 2)
                    .foregroundStyle(nw.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NW.Space.xxs)
                    .padding(.leading, NW.Space.l)
                    .overlay(alignment: .leading) { nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
                    .frame(maxWidth: NWThreadMetrics.proseMeasure, alignment: .leading)
                    .nwTransition(.disclosure)
            }
        }
    }

    /// The disclosure's chevron, still, in `textTertiary`, and "Thinking…" in italic 12.5
    /// shimmering (LiveText: text moves, icons don't).
    private var liveHeader: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.nw.textTertiary)
                .frame(width: NWThreadMetrics.liveChevron, height: NWThreadMetrics.liveChevron)
            Text(title).font(.nw(.ui, weight: .regular)).italic().lineLimit(1).nwShimmer(active: true)
        }
        .frame(minHeight: NWThreadMetrics.liveHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
    }

    /// Thinking the model did not share: the collapsed row's words alone, with nothing to open.
    private var plainLine: some View {
        let note = "\(spokenTitle). The model didn't share its reasoning."
        return Text(title).font(.nwSans(12)).italic()
            .nwContentTransition(.numeric())
            .nwAnimation(.content, value: title)
            .foregroundStyle(Color.nw.textSecondary)
            #if os(iOS)
            .frame(minHeight: NW.Height.touch)
            #endif
            .nwHelp(note)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note)
    }

    private var toggle: some View {
        Button {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: NW.Space.s) {
                NWThreadChevron(isExpanded: isExpanded)
                // Thinking that merges into this stretch counts its seconds up.
                Text(title).font(.nwSans(12)).italic()
                    .nwContentTransition(.numeric())
                    .nwAnimation(.content, value: title)
            }
            .foregroundStyle(Color.nw.textSecondary)
            #if os(iOS)
            .frame(minHeight: NW.Height.touch)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nwFocusRing(radius: NW.Radius.xs)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the model's thinking")
    }
}

// MARK: Turn footer and errors

/// After a finished turn: copy and retry (24pt icon buttons), then "2:44 PM · 3m 12s · 23 tool
/// calls" in mono 10.5 tertiary, and "· 3 subagents" as a link when given. The whole row shows
/// only while its turn is hovered (`revealed`), one of its controls has keyboard focus, a copy
/// confirms, or VoiceOver runs; at rest it keeps its place, invisible.
public struct NWTurnFooter: View {
    let meta: String
    let link: String?
    let onLink: (() -> Void)?
    let onCopy: (() -> Void)?
    let onRetry: (() -> Void)?
    let revealed: Bool
    /// Stands in for the system's VoiceOver state (tests).
    private var voiceOverSeed: Bool?
    @State private var copied = false
    @State private var copies = 0
    @FocusState private var focus: Control?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private enum Control: Hashable { case copy, retry, link }

    /// `revealed` is whether the pointer is over the turn; the host tracks it for the whole turn.
    public init(meta: String, link: String? = nil, onLink: (() -> Void)? = nil,
                onCopy: (() -> Void)? = nil, onRetry: (() -> Void)? = nil, revealed: Bool = false) {
        self.meta = meta
        self.link = link
        self.onLink = onLink
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.revealed = revealed
    }

    /// `voiceOver` stands in for the system's VoiceOver state, for tests.
    init(meta: String, link: String? = nil, onLink: (() -> Void)? = nil, onCopy: (() -> Void)? = nil,
         onRetry: (() -> Void)? = nil, revealed: Bool = false, voiceOver: Bool) {
        self.init(meta: meta, link: link, onLink: onLink, onCopy: onCopy, onRetry: onRetry, revealed: revealed)
        voiceOverSeed = voiceOver
    }

    public var body: some View {
        let shown = NWMessageDetails.shown(hovering: revealed, focused: focus != nil, confirming: copied,
                                           voiceOver: voiceOverSeed ?? voiceOver)
        HStack(spacing: NW.Space.xs) {
            if let onCopy {
                Button {
                    onCopy()
                    copied = true
                    copies += 1
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { NWCopyGlyph(copied: copied, copies: copies) }
                .buttonStyle(.nwIcon(size: NWThreadMetrics.footerButton))
                .focused($focus, equals: .copy)
                .help("Copy the reply")
                .accessibilityLabel(copied ? "Copied" : "Copy response")
            }
            if let onRetry {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.nwIcon(size: NWThreadMetrics.footerButton))
                    .focused($focus, equals: .retry)
                    .help("Send this turn's prompt again")
                    .accessibilityLabel("Retry turn")
                    .nwTransition(.content)
            }
            HStack(spacing: 0) {
                Text(meta).monospacedDigit()
                if let link, let onLink {
                    if !meta.isEmpty { Text(" · ") }
                    Button(link, action: onLink).buttonStyle(.nwLink(font: .nwMono(10.5)))
                        .focused($focus, equals: .link)
                }
            }
            .font(.nwMono(10.5))
            .foregroundStyle(Color.nw.textTertiary)
            .padding(.leading, NW.Space.xs)
        }
        // Retry appears once the agent is idle again.
        .nwAnimation(.content, value: onRetry != nil)
        .opacity(shown ? 1 : 0)
        .nwAnimation(.hover, value: shown)
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
                    .nwContentTransition(.numeric())
                    .nwTransition(.content)
            }
            if let retry {
                Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .nwTransition(.content)
            }
        }
        // A repeat counts up; Retry appears when the error ends the turn.
        .nwAnimation(.content, value: count)
        .nwAnimation(.content, value: retry != nil)
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, 10)
        .background(nw.failedTint, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .accessibilityElement(children: .contain)
    }
}

