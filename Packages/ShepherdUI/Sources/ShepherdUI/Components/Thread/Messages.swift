import SwiftUI

// Messages (SHThread board): the user's bubble, code, thinking, the turn footer and the
// turn-level error (the agent's prose is in Prose.swift). Value inputs only; the app owns the
// thread.

/// When a message's quiet details show: the bubble's time and a finished turn's footer. Only
/// while the pointer is over the message (`hovering`, which the host tracks for the whole
/// message), while one of their controls has keyboard focus, while a copy confirms, or while
/// VoiceOver runs, so they stay reachable. Either way they keep their place and only fade
/// (`.hover`): showing them never moves or resizes anything.
enum SHMessageDetails {
    static func shown(hovering: Bool, focused: Bool = false, confirming: Bool = false, voiceOver: Bool) -> Bool {
        SHPlatform.showsHoverDetails || hovering || focused || confirming || voiceOver
    }
}

/// A user bubble's measure and inset: the Mac's (and the phone's) at most 600pt with 10×14
/// inside, or the iPad boards' 520pt with 12×16 (iPadThread).
public struct SHUserBubbleMetrics: Equatable, Sendable {
    public var maxWidth: CGFloat
    public var vertical: CGFloat
    public var horizontal: CGFloat
    /// The hover time floats under the bubble instead of holding room for itself (ProjectLead boards: 16pt from a bubble to the next
    /// line, with nothing drawn between).
    public var overlaysCaption = false
    /// Leading added to the body line the ordinary bubble uses (it takes one point off): the boards' bubble is 20.25pt a line
    /// (13.5 on 1.5), which measured 2pt a line taller than the ordinary bubble's.
    public var leadingAdjustment: CGFloat = -1

    public static let standard = SHUserBubbleMetrics(maxWidth: SHThreadMetrics.bubbleMaxWidth, vertical: 10, horizontal: 14)
    /// The Project conversation's bubble (ProjectLead-Started): a 520pt measure inside 12 / 16 padding and a 1pt border (554pt), caption overlaid. The 2.25pt is the half-leading CSS puts above and below a 20.25pt line that SwiftUI's first and last lines lack.
    public static let lead = SHUserBubbleMetrics(maxWidth: 554, vertical: SH.Space.l + 2.25, horizontal: SH.Space.xl, overlaysCaption: true, leadingAdjustment: -2)
    public static let pad = SHUserBubbleMetrics(maxWidth: 520, vertical: SH.Space.l, horizontal: SH.Space.xl)
}

extension EnvironmentValues {
    @Entry public var shUserBubbleMetrics = SHUserBubbleMetrics.standard
}

/// The user's turn: right-aligned, at most 600pt (`shUserBubbleMetrics`), `bgBubble` with a 1px strong line, radius 8.
/// No avatar and no name; the time sits beneath, shown only while the message is hovered. A
/// message steered into a running turn wears "Steered" above it and a `running` line. Its text
/// follows `shProseSize`. `leading` sits above the words inside the bubble: the design references
/// the message carries (DesignReferenceChip · sent).
public struct SHUserBubble<Leading: View>: View {
    /// How the message reached pi.
    public enum Origin: Sendable {
        /// Sent, or delivered from the queue.
        case sent
        /// Steered into a running turn, where pi read it.
        case steered
    }

    /// The "Steered" label's glyph.
    static var steeredGlyph: CGFloat { 11 }

    let text: String
    let title: String?
    let attachments: [String]
    let timestamp: String?
    let note: String?
    let revealed: Bool
    let origin: Origin
    let leading: Leading
    @Environment(\.shProseSize) private var proseSize
    @Environment(\.shUserBubbleMetrics) private var metrics
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// `attachments` name the images sent with the message. `timestamp` shows only while
    /// `revealed` (the pointer is over the message); `note` follows it and always shows ("from
    /// parent"). `title` leads the bubble in semibold, `text` 4pt under it: an answer to a
    /// question (the option chosen, then a note).
    public init(_ text: String, title: String? = nil, attachments: [String] = [], timestamp: String? = nil, note: String? = nil,
                revealed: Bool = false, origin: Origin = .sent, @ViewBuilder leading: () -> Leading) {
        self.text = text
        self.title = title
        self.attachments = attachments
        self.timestamp = timestamp
        self.note = note
        self.revealed = revealed
        self.origin = origin
        self.leading = leading()
    }

    public var body: some View {
        let sh = Color.sh
        let steered = origin == .steered
        VStack(alignment: .trailing, spacing: 5) {
            if steered {
                HStack(spacing: SH.Space.xs) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: Self.steeredGlyph, weight: .medium))
                    Text("Steered").font(.sh(.caption, weight: .medium))
                }
                .foregroundStyle(sh.running)
            }
            VStack(alignment: .leading, spacing: SH.Space.m) {
                // Above the words: what it holds may open over them (a chip's preview).
                leading.zIndex(1)
                if !attachments.isEmpty {
                    HStack(spacing: SH.Space.s) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, name in
                            SHAttachmentChip(name, thumbnail: nil)
                        }
                    }
                }
                if title != nil || !text.isEmpty {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        if let title { line(title, weight: .semibold) }
                        if !text.isEmpty { line(text, weight: nil) }
                    }
                }
            }
            .padding(.vertical, metrics.vertical)
            .padding(.horizontal, metrics.horizontal)
            // The border is drawn under the content, so a chip's preview that opens over the
            // bubble's edge isn't crossed by it.
            .background {
                RoundedRectangle(cornerRadius: SH.Radius.m).fill(sh.bgBubble)
                    .shBorder(steered ? sh.running : sh.lineStrong, radius: SH.Radius.m)
            }
            .frame(maxWidth: metrics.maxWidth, alignment: .trailing)
            if !metrics.overlaysCaption, timestamp != nil || note != nil {
                caption
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if metrics.overlaysCaption, timestamp != nil || note != nil { caption.offset(y: SH.Space.xl) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func line(_ value: String, weight: Font.Weight?) -> some View {
        Text(value)
            .font(.sh(.body, weight: weight, size: proseSize))
            .lineSpacing(max(0, SHTextStyle.body.lineSpacing(proseSize) + metrics.leadingAdjustment))
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "2:41 PM", or "10:58 · from parent": the time (and its separator) fades in place beside a
    /// note that always shows.
    private var caption: some View {
        let shown = SHMessageDetails.shown(hovering: revealed, voiceOver: voiceOver)
        return HStack(spacing: 0) {
            if let timestamp {
                Text(note == nil ? timestamp : "\(timestamp) · ").monospacedDigit()
                    .opacity(shown ? 1 : 0)
                    .shAnimation(.hover, value: shown)
            }
            if let note { Text(note) }
        }
        .font(.shMono(10.5))
        .foregroundStyle(Color.sh.textTertiary)
    }
}

extension SHUserBubble where Leading == EmptyView {
    public init(_ text: String, title: String? = nil, attachments: [String] = [], timestamp: String? = nil, note: String? = nil,
                revealed: Bool = false, origin: Origin = .sent) {
        self.init(text, title: title, attachments: attachments, timestamp: timestamp, note: note, revealed: revealed, origin: origin) {
            EmptyView()
        }
    }
}

// MARK: Code

/// A fenced block (SHThread board): `bgSunken`, a 1px line, radius 8; a 28pt header with the
/// language and a copy button that appears on hover (and for keyboard focus); code in mono 12
/// at 1.6, syntax colored when `highlighted` is given.
public struct SHCodeBlock: View {
    let code: String
    let language: String?
    let highlighted: AttributedString?
    #if os(macOS)
    @State private var nativeCode = SHNativeCodeText.Cache()
    #endif
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
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                let kind = SHFenceKind(language)
                HStack(spacing: SH.Space.xs) {
                    if let glyph = kind.glyph {
                        Image(systemName: glyph).font(.system(size: SHThreadMetrics.codeLabelGlyph, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    Text(kind.label).font(.shMono(10.5))
                }
                .foregroundStyle(sh.textTertiary)
                Spacer(minLength: 0)
                Button {
                    SHPasteboard.copy(code)
                    copied = true
                    copies += 1
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    SHCopyGlyph(copied: copied, copies: copies)
                }
                .buttonStyle(.shIcon(size: SHThreadMetrics.codeCopyButton))
                .focused($copyFocused)
                .opacity(SHPlatform.showsHoverDetails || hovering || copyFocused || copied ? 1 : 0)
                .shAnimation(.hover, value: hovering || copyFocused || copied)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.s)
            .frame(height: SHThreadMetrics.codeHeaderHeight)
            .overlay(alignment: .bottom) { SHHairline() }
            // The code draws directly when its longest line fits the column, so the thread's
            // wheel never meets a nested scroll view there, and scrolls sideways only when it does not.
            ViewThatFits(in: .horizontal) {
                codeText
                ScrollView(.horizontal) { codeText }
                    .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }

    /// The code at its natural width, unwrapped.
    private var codeText: some View {
        Group {
            #if os(macOS)
            SHNativeCodeText(code: code, highlighted: highlighted, scale: ThemeStore.shared.textScale,
                             lineSpacing: SHTextStyle.code.lineSpacing + 0.6, cache: nativeCode)
            #else
            if let highlighted { Text(highlighted) } else { Text(code) }
            #endif
        }
        .font(.sh(.code))
        .lineSpacing(SHTextStyle.code.lineSpacing + 0.6)
        .foregroundStyle(Color.sh.textPrimary)
        .textSelection(.enabled)
        .fixedSize()
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, 10)
    }
}

/// What a source fence's header says (including the source beneath a rendered Mermaid chart).
/// Diagram and math source headers name the source after a glyph: "mermaid ·
/// diagram source", "latex · math source".
struct SHFenceKind: Equatable {
    let label: String
    let glyph: String?

    init(_ language: String?) {
        guard let language, !language.isEmpty else {
            self.init(label: "code", glyph: nil)
            return
        }
        switch language.lowercased() {
        case "mermaid", "plantuml", "dot", "graphviz", "d2":
            self.init(label: "\(language) · diagram source", glyph: "point.3.connected.trianglepath.dotted")
        case "math", "latex", "tex", "katex":
            self.init(label: "\(language) · math source", glyph: "function")
        default:
            self.init(label: language, glyph: nil)
        }
    }

    private init(label: String, glyph: String?) {
        self.label = label
        self.glyph = glyph
    }
}

/// A copy button's glyph (code blocks, the turn footer): `doc.on.doc`, turning into a check
/// for a moment after each copy, replacing the symbol and popping.
struct SHCopyGlyph: View {
    let copied: Bool
    /// Copies so far: each one pops.
    let copies: Int

    var body: some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
            .shContentTransition(.symbol)
            .shAnimation(.content, value: copied)
            .shPop(trigger: copies)
    }
}

// MARK: Thinking

/// The model's thinking (SHThread board). Collapsed: a 10pt chevron and "Thought for 4s" in
/// italic 12. Expanded: the text as Markdown (bold, italic, code and links inline; paragraphs,
/// lists and quotes as blocks) in italic 12.5 on a 2pt rule. Live (LiveText): "Thinking…"
/// shimmering on a 26pt line with its clock in mono 11 tertiary, settling into "Thought for Ns"
/// when it ends. Live thinking whose summary the provider shared is a disclosure already
/// ("Thinking… · 30s", ResponseVisibility › B): open, the summary so far and where it came from.
/// With no text (the model kept its reasoning back), finished thinking is the plain line, not a
/// control. A row with nothing to open draws no chevron but keeps its place, so the words never
/// move.
public struct SHThinking: View {
    let title: String
    let spokenTitle: String
    let blocks: [SHProseBlock]
    @Binding var isExpanded: Bool
    let live: Bool
    /// When live thinking began, for its clock; nil draws none.
    var since: Date?

    /// Under an open live summary: where its words came from, and that they are not all of it.
    public static let summarySource = "Summary shared by the model. Its full reasoning isn’t shown."

    /// Finished thinking: `title` is "Thought for 4s", `spokenTitle` how VoiceOver says it
    /// ("Thought for 4 seconds"), and `blocks` the text, parsed once per change by the host
    /// app. No blocks draw the plain line.
    public init(_ title: String, blocks: [SHProseBlock], isExpanded: Binding<Bool>, spokenTitle: String? = nil) {
        self.title = title
        self.spokenTitle = spokenTitle ?? title
        self.blocks = blocks
        _isExpanded = isExpanded
        live = false
    }

    /// Finished thinking as plain text: a paragraph per blank-line-separated run, with no
    /// Markdown read. An empty `text` draws the plain line.
    public init(_ title: String, text: String, isExpanded: Binding<Bool>, spokenTitle: String? = nil) {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.init(title, blocks: paragraphs.map { .paragraph(AttributedString($0)) }, isExpanded: isExpanded, spokenTitle: spokenTitle)
    }

    private init(since: Date?, blocks: [SHProseBlock] = [], isExpanded: Binding<Bool> = .constant(false)) {
        title = "Thinking…"
        spokenTitle = "Thinking"
        self.blocks = blocks
        _isExpanded = isExpanded
        live = true
        self.since = since
    }

    /// pi thinking between tools: its thinking streaming, or nothing yet to show for it.
    public static func live() -> SHThinking { SHThinking(since: nil) }

    /// The model thinking now, since `since` (its clock; nil draws none). With `blocks`, the
    /// summary the provider has shared so far, it is a disclosure: "Thinking… · 30s".
    public static func live(since: Date?, blocks: [SHProseBlock] = [], isExpanded: Binding<Bool> = .constant(false)) -> SHThinking {
        SHThinking(since: since, blocks: blocks, isExpanded: isExpanded)
    }

    /// Expanded thinking's text: Geist 12.5 (italic where it is drawn) at 1.55, headings
    /// semibold.
    @MainActor static var font: Font { .shSans(12.5) }
    @MainActor static var headingFont: Font { .shSans(12.5, .semibold) }
    @MainActor static var lineSpacing: CGFloat { SHTextStyle.caption.lineSpacing + 2 }

    /// What the row is: only a disclosure has something to open, so only it wears a chevron
    /// and takes a press.
    enum Kind: Equatable {
        /// "Thinking…", shimmering: nothing to open yet.
        case live
        /// "Thinking… · 30s": live, with a summary to open.
        case liveDisclosure
        /// "Thought for Ns" with no text: the model kept its reasoning back.
        case plain
        case disclosure

        init(live: Bool, blocks: [SHProseBlock]) {
            self = live ? (blocks.isEmpty ? .live : .liveDisclosure) : blocks.isEmpty ? .plain : .disclosure
        }

        var opens: Bool { self == .disclosure || self == .liveDisclosure }
    }

    var kind: Kind { Kind(live: live, blocks: blocks) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When thinking ends, "Thinking…" cross-fades into "Thought for 4s" in place, as long as
    /// the caller keeps one `SHThinking` for both (the same view identity).
    public var body: some View {
        let sh = Color.sh
        let kind = kind
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ZStack(alignment: .leading) {
                switch kind {
                case .live: liveHeader.shTransition(.content)
                case .plain: plainLine.shTransition(.content)
                case .disclosure, .liveDisclosure: toggle.shTransition(.content)
                }
            }
            .shAnimation(.content, value: live)
            if isExpanded, kind.opens {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHProseBlocks(blocks: blocks, voice: .thinking) { SHCodeBlock($0, language: $1) }
                    if kind == .liveDisclosure {
                        Text(Self.summarySource).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, SH.Space.xxs)
                .padding(.leading, SH.Space.l)
                .overlay(alignment: .leading) { sh.lineStrong.frame(width: SHThreadMetrics.ruleWidth) }
                .frame(maxWidth: SHThreadMetrics.proseMeasure, alignment: .leading)
                .shTransition(.disclosure)
            }
        }
    }

    /// "Thinking…" in italic 12.5 shimmering (LiveText: text moves, icons don't). Nothing
    /// opens yet, so no chevron draws (the user's decision, 2026-09-25); its place stays, the
    /// finished row's, so the words settle into "Thought for Ns" without moving.
    private var liveHeader: some View {
        SHLiveLine(title, italic: true, since: since, spokenTitle: spokenTitle)
    }

    /// Thinking the model did not share: the collapsed row's words alone, where a toggle's would
    /// be, with nothing to open.
    private var plainLine: some View {
        let note = "\(spokenTitle). The model didn't share its reasoning."
        return HStack(spacing: SH.Space.s) {
            SHThreadChevron(isExpanded: false, shown: false)
            Text(title).font(.shSans(12)).italic()
                .shContentTransition(.numeric())
                .shAnimation(.content, value: title)
        }
        .foregroundStyle(Color.sh.textSecondary)
        #if os(iOS)
        .frame(minHeight: SH.Height.touch)
        #endif
        .shHelp(note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note)
    }

    private var toggle: some View {
        Button {
            withAnimation(SH.Motion.disclosure.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: SH.Space.s) {
                SHThreadChevron(isExpanded: isExpanded)
                // Thinking that merges into this stretch counts its seconds up.
                HStack(spacing: 0) {
                    Text(title)
                    if live, let since {
                        Text(" · ")
                        SHElapsedText(since: since, style: .long)
                    }
                }
                .font(.shSans(12)).italic()
                .shContentTransition(.numeric())
                .shAnimation(.content, value: title)
            }
            .foregroundStyle(Color.sh.textSecondary)
            #if os(iOS)
            .frame(minHeight: SH.Height.touch)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shFocusRing(radius: SH.Radius.xs)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(live ? "Shows the summary the model has shared so far" : "Shows the model's thinking")
    }
}

/// The thread's live line while nothing else moves (LiveText, ResponseVisibility › A): the words
/// shimmering in 12.5 on a 26pt line ("Waiting for response", or "Thinking…" in italic), where a
/// thinking row's words sit, and the clock beside them in mono 11 `textTertiary`. Nothing spins;
/// under Reduce Motion the words are plain.
public struct SHLiveLine: View {
    let title: String
    let italic: Bool
    let since: Date?
    let spokenTitle: String
    let help: String?

    public init(_ title: String, italic: Bool = false, since: Date? = nil, spokenTitle: String? = nil, help: String? = nil) {
        self.title = title
        self.italic = italic
        self.since = since
        self.spokenTitle = spokenTitle ?? title
        self.help = help
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            SHThreadChevron(isExpanded: false, shown: false)
            HStack(spacing: SH.Space.m) {
                Text(title).font(.sh(.ui, weight: .regular)).italic(italic).lineLimit(1).shShimmer(active: true)
                if let since {
                    SHElapsedText(since: since, style: .long).font(.shMono(SHThreadMetrics.liveClock)).foregroundStyle(Color.sh.textTertiary).fixedSize()
                }
            }
        }
        .frame(minHeight: SHThreadMetrics.liveHeight)
        .contentShape(Rectangle())
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle)
    }
}

// MARK: Turn footer and errors

/// After a finished turn: copy and retry (24pt icon buttons), Response timing when the host
/// measured the reply (ResponseVisibility › C: its popover toggles, Esc closes it), then "2:44 PM ·
/// 3m 12s · 23 tool calls" in mono 10.5 tertiary, and "· 3 subagents" as a link when given. The
/// whole row shows only while its turn is hovered (`revealed`), one of its controls has keyboard
/// focus, a copy confirms, the timing is open, or VoiceOver runs; at rest it keeps its place,
/// invisible.
public struct SHTurnFooter: View {
    let meta: String
    let link: String?
    let onLink: (() -> Void)?
    let onCopy: (() -> Void)?
    let onRetry: (() -> Void)?
    let revealed: Bool
    /// The reply's Response timing; nil draws no timing button.
    var timing: SHResponseTimingModel?
    /// Stands in for the system's VoiceOver state (tests).
    private var voiceOverSeed: Bool?
    @State private var copied = false
    @State private var copies = 0
    @State private var timingOpen = false
    @FocusState private var focus: Control?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private enum Control: Hashable { case copy, retry, timing, link }

    /// The footer with the reply's Response timing (nil draws no timing button).
    public init(meta: String, link: String? = nil, onLink: (() -> Void)? = nil, onCopy: (() -> Void)? = nil,
                onRetry: (() -> Void)? = nil, timing: SHResponseTimingModel?, revealed: Bool = false) {
        self.init(meta: meta, link: link, onLink: onLink, onCopy: onCopy, onRetry: onRetry, revealed: revealed)
        self.timing = timing
    }

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
        let shown = SHMessageDetails.shown(hovering: revealed, focused: focus != nil || timingOpen, confirming: copied,
                                           voiceOver: voiceOverSeed ?? voiceOver)
        HStack(spacing: SH.Space.xs) {
            if let onCopy {
                Button {
                    onCopy()
                    copied = true
                    copies += 1
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { SHCopyGlyph(copied: copied, copies: copies) }
                .buttonStyle(.shIcon(size: SHThreadMetrics.footerButton))
                .focused($focus, equals: .copy)
                .help("Copy the reply")
                .accessibilityLabel(copied ? "Copied" : "Copy response")
            }
            if let onRetry {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                    .buttonStyle(.shIcon(size: SHThreadMetrics.footerButton))
                    .focused($focus, equals: .retry)
                    .help("Retry this turn")
                    .accessibilityLabel("Retry turn")
                    .shTransition(.content)
            }
            if let timing {
                Button { timingOpen.toggle() } label: { SHGlyph.responseTiming.image.font(.system(size: SHThreadMetrics.footerGlyph)) }
                    .buttonStyle(.shIcon(isOn: timingOpen, size: SHThreadMetrics.footerButton))
                    .focused($focus, equals: .timing)
                    .help(SHResponseTiming.title)
                    .accessibilityLabel(SHResponseTiming.title)
                    .accessibilityValue(timingOpen ? "Expanded" : "Collapsed")
                    .popover(isPresented: $timingOpen, arrowEdge: .top) {
                        #if os(iOS)
                        SHResponseTimingPresentation(model: timing)
                            .presentationCompactAdaptation(.sheet)
                        #else
                        SHResponseTiming(timing)
                        #endif
                    }
            }
            #if os(iOS)
            // Metadata wraps in the space left by the 44pt actions, including when a scene
            // narrows while its timing sheet is open. Touch never depends on hover.
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(meta).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                if let link, let onLink {
                    Button(link, action: onLink).buttonStyle(.shLink(font: .sh(.micro)))
                        .focused($focus, equals: .link)
                        .frame(minHeight: SH.Height.touch)
                }
            }
            .font(.sh(.micro))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.leading, SH.Space.xs)
            #else
            HStack(spacing: 0) {
                Text(meta).monospacedDigit()
                if let link, let onLink {
                    if !meta.isEmpty { Text(" · ") }
                    Button(link, action: onLink).buttonStyle(.shLink(font: .shMono(10.5)))
                        .focused($focus, equals: .link)
                }
            }
            .font(.shMono(10.5))
            .foregroundStyle(Color.sh.textTertiary)
            .padding(.leading, SH.Space.xs)
            #endif
        }
        // Retry appears once the agent is idle again.
        .shAnimation(.content, value: onRetry != nil)
        .opacity(shown ? 1 : 0)
        .shAnimation(.hover, value: shown)
    }
}

