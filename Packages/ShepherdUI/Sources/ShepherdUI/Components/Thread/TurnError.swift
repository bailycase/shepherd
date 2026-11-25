import SwiftUI

/// The turn error's own measures (TurnErrors): the Mac card, and the touch card iPhone and iPad
/// share.
public enum SHTurnErrorMetrics {
    #if os(iOS)
    public static let radius: CGFloat = SH.Radius.xxl
    public static let horizontalPadding: CGFloat = 16
    public static let titleSize: CGFloat = 15
    public static let messageSize: CGFloat = 14
    public static let foldedHeight: CGFloat = 36
    public static let foldedSize: CGFloat = 13.5
    public static let bodySize: CGFloat = 11
    #else
    public static let radius: CGFloat = 10
    public static let horizontalPadding: CGFloat = 16
    public static let titleSize: CGFloat = 14
    public static let messageSize: CGFloat = 13
    public static let foldedHeight: CGFloat = 26
    public static let foldedSize: CGFloat = 12.5
    public static let bodySize: CGFloat = 11.5
    #endif
    public static let verticalPadding: CGFloat = 14
    public static let lineGap: CGFloat = 5
    public static let titleGap: CGFloat = 10
    /// A link's size in the message, and its arrow's.
    public static let linkSize: CGFloat = 12.5
    public static let actionsTop: CGFloat = 6
    public static let actionGap: CGFloat = 6
    public static let detailsSize: CGFloat = 12.5
    /// Details: the facts beside the raw body on the Mac (a 250pt column, labels 70pt wide), above
    /// it on touch.
    public static let detailsLeading: CGFloat = 52
    public static let detailsGap: CGFloat = 24
    public static let factsWidth: CGFloat = 250
    public static let factLabelWidth: CGFloat = 70
    public static let factRowGap: CGFloat = 7
    public static let factSize: CGFloat = 12
    /// The folded line and the retry line: a 13pt glyph, 8pt gaps.
    public static let lineGlyph: CGFloat = 13
    /// Touch (the boards' `.gt-err`): the glyph 16pt before the title, the rest 26pt in under it; its actions 20pt apart.
    public static let touchGlyph: CGFloat = 16
    public static let touchIndent: CGFloat = 26
    public static let touchActionGap: CGFloat = 20
}

/// A request to the model that failed (TurnErrors › The error card): the kind's glyph on a
/// plain glyph before a plain title, the provider's words cleaned (keys cut, links), the status
/// and type as chips beside the model and provider, then Retry, Copy and Details, which opens
/// in place on everything the provider sent back. Folded (an earlier error the next turn
/// repeated, or one pi retried past), it is one line that opens the card.
public struct SHTurnError: View {
    public enum Span: Equatable, Sendable {
        case text(String)
        /// A key cut to its ends, a host, a quoted name: mono, in the primary color.
        case code(String)
        case link(display: String, url: String)
    }

    /// The raw body's runs: JSON keys and strings take the syntax colors.
    public enum BodyToken: Equatable, Sendable {
        case plain(String)
        case key(String)
        case string(String)
        case redacted(String)
        case link(String)
    }

    public struct Fact: Equatable, Sendable {
        public var label: String
        public var value: String
        public var mono: Bool

        public init(_ label: String, _ value: String, mono: Bool = true) {
            self.label = label
            self.value = value
            self.mono = mono
        }
    }

    public struct Content: Equatable, Sendable {
        public var glyph: String
        public var title: String
        public var message: [Span]
        public var chips: [String]
        /// "gpt-5 · OpenAI".
        public var source: String?
        /// "Tried 3 times over 31m".
        public var tries: String?
        /// "5:54 PM".
        public var time: String?
        /// "401 · 5:52 PM".
        public var foldedMeta: String
        public var facts: [Fact]
        public var body: [BodyToken]
        public var copyText: String

        public init(glyph: String = "exclamationmark.triangle", title: String, message: [Span], chips: [String] = [], source: String? = nil,
                    tries: String? = nil, time: String? = nil, foldedMeta: String = "", facts: [Fact] = [], body: [BodyToken] = [],
                    copyText: String = "") {
            self.glyph = glyph
            self.title = title
            self.message = message
            self.chips = chips
            self.source = source
            self.tries = tries
            self.time = time
            self.foldedMeta = foldedMeta
            self.facts = facts
            self.body = body
            self.copyText = copyText
        }
    }

    let content: Content
    let folded: Bool
    let retry: (() -> Void)?
    /// The provider's login no longer works: opens its sign-in.
    let signIn: (() -> Void)?
    /// Where Details and unfolding are kept when the caller keeps them (a thread's store);
    /// otherwise the card keeps its own.
    let detailsState: Binding<Bool>?
    let unfoldState: Binding<Bool>?
    @State private var ownDetails: Bool
    @State var ownOpened = false
    @State var copied = false
    @State var copies = 0

    /// `detailsOpen` seeds Details when the card keeps its own state (previews, tests).
    public init(_ content: Content, folded: Bool = false, detailsOpen: Bool = false, details: Binding<Bool>? = nil,
                unfolded: Binding<Bool>? = nil, retry: (() -> Void)? = nil, signIn: (() -> Void)? = nil) {
        self.content = content
        self.folded = folded
        self.retry = retry
        self.signIn = signIn
        detailsState = details
        unfoldState = unfolded
        _ownDetails = State(initialValue: detailsOpen)
    }

    var detailsOpen: Bool { detailsState?.wrappedValue ?? ownDetails }
    var unfolded: Bool { unfoldState?.wrappedValue ?? ownOpened }

    func toggleDetails() {
        if let detailsState { detailsState.wrappedValue.toggle() } else { ownDetails.toggle() }
    }

    @ViewBuilder public var body: some View {
        #if os(macOS)
        if folded, !unfolded { macFoldedLine } else { macCard }
        #else
        if folded, !unfolded { foldedLine } else { card }
        #endif
    }

    // MARK: Folded

    private var foldedLine: some View {
        let sh = Color.sh
        return Button {
            if let unfoldState { unfoldState.wrappedValue = true } else { ownOpened = true }
        } label: {
            HStack(spacing: SH.Space.m) {
                Image(systemName: content.glyph).font(.system(size: SHTurnErrorMetrics.lineGlyph - 1, weight: .medium))
                    .foregroundStyle(sh.failed)
                    .frame(width: SHTurnErrorMetrics.lineGlyph, height: SHTurnErrorMetrics.lineGlyph)
                Text(content.title).font(.shSans(SHTurnErrorMetrics.foldedSize)).foregroundStyle(sh.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                if !content.foldedMeta.isEmpty {
                    Text(content.foldedMeta).font(.shMono(11)).foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.system(size: SHThreadMetrics.chevron - 1, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
            }
            .frame(minHeight: SHTurnErrorMetrics.foldedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shHelp("Show the error")
        .accessibilityLabel("\(content.title), \(content.foldedMeta)")
        .accessibilityHint("Shows the error")
    }

    // MARK: Card

    private var card: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SHTurnErrorMetrics.radius)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SHTurnErrorMetrics.lineGap) {
                titleRow
                message.padding(.leading, SHTurnErrorMetrics.touchIndent)
                facts.padding(.leading, SHTurnErrorMetrics.touchIndent)
                actions
                    .padding(.leading, SHTurnErrorMetrics.touchIndent)
                    .padding(.top, SHTurnErrorMetrics.actionsTop)
            }
            .padding(.vertical, SHTurnErrorMetrics.verticalPadding)
            .padding(.horizontal, SHTurnErrorMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            if detailsOpen {
                SHHairline()
                details
                    .shTransition(.content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .shBorder(sh.lineSubtle, radius: SHTurnErrorMetrics.radius)
        .shLift(shape)
        .shAnimation(.content, value: detailsOpen)
        .accessibilityElement(children: .contain)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: SHTurnErrorMetrics.titleGap) {
            Image(systemName: content.glyph)
                .font(.system(size: SHTurnErrorMetrics.touchGlyph - 2, weight: .regular))
                .foregroundStyle(Color.sh.failed)
                .frame(width: SHTurnErrorMetrics.touchGlyph, height: SHTurnErrorMetrics.touchGlyph)
                .padding(.top, SH.Space.xxs)
                .accessibilityHidden(true)
            Text(content.title).font(.shSans(SHTurnErrorMetrics.titleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The provider's words: code spans in mono, links in the link color with their arrow.
    private var message: some View {
        let sh = Color.sh
        var text = Text(verbatim: "")
        for span in content.message {
            switch span {
            case .text(let value):
                text = Text("\(text)\(Text(verbatim: value))")
            case .code(let value):
                text = Text("\(text)\(Text(verbatim: value).font(.shMono(SHTurnErrorMetrics.messageSize - 0.5)).foregroundStyle(sh.textPrimary))")
            case .link(let display, let url):
                // The boards' `.em a`: ink and underlined, no arrow.
                var link = AttributedString(display)
                link.link = URL(string: url)
                link.underlineStyle = .single
                text = Text("\(text)\(Text(link).font(.shSans(SHTurnErrorMetrics.linkSize)).foregroundStyle(sh.textPrimary))")
            }
        }
        return text
            .font(.shSans(SHTurnErrorMetrics.messageSize))
            .foregroundStyle(sh.textSecondary)
            .lineSpacing(SHTurnErrorMetrics.messageSize * 0.5 - 3)
            .tint(sh.running)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "401 · authentication_error" in mono, then "gpt-6-astra · OpenAI · 3:04 PM · Tried 3 times over 31m" in sans (the boards' `.eg`).
    private var facts: some View {
        let sh = Color.sh
        let rest = [content.source, content.time, content.tries].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let chips = Text(verbatim: content.chips.joined(separator: " \u{00B7} ")).font(.shMono(SHTurnErrorMetrics.factSize))
        let line = if content.chips.isEmpty { Text(verbatim: rest) } else if rest.isEmpty { chips } else { Text("\(chips) \u{00B7} \(Text(verbatim: rest))") }
        return line
            .font(.shSans(SHTurnErrorMetrics.factSize))
            .foregroundStyle(sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Retry in ink, Copy in `textSecondary`, Details at the end (the boards' `.ea`): words, not chips.
    private var actions: some View {
        let sh = Color.sh
        let size = SHTurnErrorMetrics.messageSize
        return HStack(spacing: SHTurnErrorMetrics.touchActionGap) {
            if let retry {
                Button(action: retry) { Text("Retry").font(.shSans(size, .medium)).foregroundStyle(sh.textPrimary).touchRow() }
                    .buttonStyle(.plain)
                    .shHelp("Retry this turn")
                    .shTransition(.content)
            }
            if let signIn {
                Button(action: signIn) { Text("Sign in again").font(.shSans(size, .medium)).foregroundStyle(sh.textPrimary).touchRow() }
                    .buttonStyle(.plain)
                    .shHelp("The provider's sign-in no longer works: sign in to it again")
                    .shTransition(.content)
            }
            Button {
                SHPasteboard.copy(content.copyText)
                copied = true
                copies += 1
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Text(copied ? "Copied" : "Copy").font(.shSans(size)).foregroundStyle(sh.textSecondary).touchRow()
            }
            .buttonStyle(.plain)
            .shHelp("Copy the error")
            .accessibilityLabel(copied ? "Copied" : "Copy error")
            Spacer(minLength: 0)
            Button {
                toggleDetails()
            } label: {
                HStack(spacing: SH.Space.xs) {
                    Text("Details").font(.shSans(size)).foregroundStyle(sh.textSecondary)
                    SHTurningChevron(isOpen: detailsOpen)
                        .font(.system(size: SHThreadMetrics.chevron - 1, weight: .semibold))
                        .foregroundStyle(sh.textSecondary)
                        .frame(width: SHThreadMetrics.chevron)
                }
                .touchRow()
            }
            .buttonStyle(.plain)
            .shHelp("Everything the provider sent back")
            .accessibilityLabel(detailsOpen ? "Hide details" : "Show details")
        }
        .shAnimation(.content, value: retry != nil)
    }

    // MARK: Details

    private var details: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: SH.Space.l) {
            factGrid
            if !content.body.isEmpty { rawBody }
        }
        .padding(EdgeInsets(top: SH.Space.l, leading: SHTurnErrorMetrics.horizontalPadding,
                            bottom: SHTurnErrorMetrics.verticalPadding, trailing: SHTurnErrorMetrics.horizontalPadding))
        #else
        HStack(alignment: .top, spacing: SHTurnErrorMetrics.detailsGap) {
            factGrid.frame(width: SHTurnErrorMetrics.factsWidth, alignment: .leading)
            if !content.body.isEmpty { rawBody }
        }
        .padding(EdgeInsets(top: SHTurnErrorMetrics.verticalPadding, leading: SHTurnErrorMetrics.detailsLeading,
                            bottom: SH.Space.xl, trailing: SHTurnErrorMetrics.horizontalPadding))
        #endif
    }

    private var factGrid: some View {
        let sh = Color.sh
        return Grid(alignment: .leading, horizontalSpacing: SH.Space.l, verticalSpacing: SHTurnErrorMetrics.factRowGap) {
            ForEach(Array(content.facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label).font(.shSans(SHTurnErrorMetrics.factSize)).foregroundStyle(sh.textTertiary)
                        .frame(width: SHTurnErrorMetrics.factLabelWidth, alignment: .leading)
                    Text(fact.value)
                        .font(fact.mono ? .shMono(SHTurnErrorMetrics.factSize - 0.5) : .shSans(SHTurnErrorMetrics.factSize))
                        .foregroundStyle(sh.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(fact.value)
                }
            }
        }
    }

    /// Everything the provider sent back, pretty-printed: keys and strings in the syntax colors,
    /// a cut key on a faint fill, addresses underlined.
    private var rawBody: some View {
        let sh = Color.sh
        var text = AttributedString()
        for token in content.body {
            switch token {
            case .plain(let value):
                text += AttributedString(value)
            case .key(let value):
                var part = AttributedString(value)
                part.foregroundColor = sh.synFunction
                text += part
            case .string(let value):
                var part = AttributedString(value)
                part.foregroundColor = sh.synString
                text += part
            case .redacted(let value):
                var part = AttributedString(value)
                part.foregroundColor = sh.synString
                part.backgroundColor = sh.bgSelected
                text += part
            case .link(let value):
                var part = AttributedString(value)
                part.foregroundColor = sh.running
                part.underlineStyle = .single
                text += part
            }
        }
        return Text(text)
            .font(.shMono(SHTurnErrorMetrics.bodySize))
            .foregroundStyle(sh.textSecondary)
            .lineSpacing(SHTurnErrorMetrics.bodySize * 0.6 - 3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(sh.lineSubtle, radius: SH.Radius.m)
    }
}

/// pi retrying a request that failed (TurnErrors › While it retries): the kind's glyph, "OpenAI
/// is overloaded · retrying in 8s" shimmering, the only thing moving, and "2 of 3". `text` gives
/// the words at a moment; until `countdownEnds` passes they are redrawn each second.
public struct SHRetryLine: View {
    let glyph: String
    let count: String?
    let countdownEnds: Date?
    let text: (Date) -> String

    public init(glyph: String = "arrow.clockwise", count: String? = nil, countdownEnds: Date? = nil, text: @escaping (Date) -> String) {
        self.glyph = glyph
        self.count = count
        self.countdownEnds = countdownEnds
        self.text = text
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: glyph).font(.system(size: SHTurnErrorMetrics.lineGlyph - 1, weight: .medium))
                .foregroundStyle(sh.textSecondary)
                .frame(width: SHTurnErrorMetrics.lineGlyph, height: SHTurnErrorMetrics.lineGlyph)
            words
            if let count {
                Text(count).font(.shMono(11)).foregroundStyle(sh.textTertiary).monospacedDigit().fixedSize()
            }
        }
        .frame(minHeight: SHThreadMetrics.liveHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var words: some View {
        if let countdownEnds, countdownEnds > .now {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                line(text(context.date))
            }
        } else {
            line(text(.now))
        }
    }

    private func line(_ value: String) -> some View {
        #if os(iOS)
        // The observed status must not truncate the retry countdown in a narrow scene.
        Text(value).font(.sh(.ui, weight: .regular)).fixedSize(horizontal: false, vertical: true).shShimmer(active: true)
        #else
        Text(value).font(.sh(.ui, weight: .regular)).lineLimit(1).truncationMode(.tail).shShimmer(active: true)
        #endif
    }
}

private extension View {
    /// A word-button's touch target: 44pt tall across, without taking the card's room (the rows are the boards' 20pt).
    func touchRow() -> some View {
        #if os(iOS)
        padding(.vertical, (SH.Height.touch - SHTurnErrorMetrics.touchGlyph - SH.Space.xs) / 2)
            .contentShape(Rectangle())
            .padding(.vertical, -(SH.Height.touch - SHTurnErrorMetrics.touchGlyph - SH.Space.xs) / 2)
        #else
        self
        #endif
    }
}
