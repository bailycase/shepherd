import SwiftUI

// A design's comments (DZCanvas, DZTweak, SHDesignTool): the numbered pin on the canvas, the
// thread beside it, and the card the chat and the Comments tab show. Pins are lantern, because a
// pin is something the viewer asked for; selection stays running blue.

/// The numbered pin (SHCommentPin): a lantern teardrop, round but for its bottom-leading corner,
/// which is its point, set on the element's top-trailing corner. On the canvas it is 26pt (a 4pt
/// point, mono 12 bold) with a small shadow; in a card's header 18pt (a 3pt point, mono 10 bold).
public struct SHCommentPin: View {
    public enum Size: Sendable {
        case canvas
        case card
    }

    let number: Int
    let size: Size

    public init(_ number: Int, size: Size = .canvas) {
        self.number = number
        self.size = size
    }

    public var body: some View {
        let side = size == .canvas ? SHDesignMetrics.pinSize : SHDesignMetrics.cardPinSize
        let point = size == .canvas ? SHDesignMetrics.pinPoint : SHDesignMetrics.cardPinPoint
        let shape = UnevenRoundedRectangle(topLeadingRadius: side / 2, bottomLeadingRadius: point,
                                           bottomTrailingRadius: side / 2, topTrailingRadius: side / 2)
        Text("\(number)")
            .font(.shMono(size == .canvas ? SHDesignMetrics.pinTextSize : SHDesignMetrics.cardPinTextSize, .bold))
            .foregroundStyle(Color.sh.textOnLantern)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: side, height: side)
            .background(Color.sh.lantern, in: shape)
            .shadow(color: size == .canvas ? Color.sh.knobShadow : .clear,
                    radius: SHDesignMetrics.pinShadowRadius, y: SHDesignMetrics.pinShadowY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Comment \(number)")
    }
}

/// One entry of a thread under its comment: the design agent's answer, or the viewer's reply.
public struct SHCommentEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// "Design agent", "You".
    public let author: String
    /// "1m", "now".
    public let age: String
    public let text: String

    public init(id: String, author: String, age: String, text: String) {
        self.id = id
        self.author = author
        self.age = age
        self.text = text
    }
}

/// A comment on the canvas beside its pin, under its element (SHCommentThread; DZTweak): 320pt, a
/// raised card with the popover's line and shadow at radius 12. The author and age with Resolve
/// trailing, the comment, each answer under a hairline, and the Reply… field.
public struct SHCommentThread: View {
    let author: String
    let age: String
    /// Said after the age when the comment's element is gone ("element changed").
    let note: String?
    let text: String
    let entries: [SHCommentEntry]
    @Binding var reply: String
    let onResolve: (() -> Void)?
    let onReply: (() -> Void)?
    let onClose: (() -> Void)?
    @FocusState private var replyFocused: Bool

    public init(author: String, age: String, note: String? = nil, text: String, entries: [SHCommentEntry] = [],
                reply: Binding<String>, onResolve: (() -> Void)? = nil, onReply: (() -> Void)? = nil,
                onClose: (() -> Void)? = nil) {
        self.author = author
        self.age = age
        self.note = note
        self.text = text
        self.entries = entries
        _reply = reply
        self.onResolve = onResolve
        self.onReply = onReply
        self.onClose = onClose
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SHDesignMetrics.threadSpacing) {
            HStack(spacing: SH.Space.m) {
                Text(author).font(.shSans(SHDesignMetrics.commentMetaSize, .semibold)).foregroundStyle(sh.textPrimary)
                Text([age, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.shSans(SHDesignMetrics.commentMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let onResolve {
                    Button("Resolve", systemImage: SHGlyph.Design.resolveComment.rawValue, action: onResolve)
                        .buttonStyle(.sh(.ghost, size: .s))
                }
            }
            SHCommentText(text)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: SHDesignMetrics.entrySpacing) {
                    (Text(entry.author).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
                        + Text(" · \(entry.age)").foregroundStyle(sh.textTertiary))
                        .font(.shSans(SHDesignMetrics.commentMetaSize))
                    SHCommentText(entry.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SHDesignMetrics.entryGap)
                .overlay(alignment: .top) { SHHairline() }
            }
            if let onReply {
                TextField("Reply…", text: $reply, prompt: Text("Reply…").foregroundStyle(sh.textTertiary), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.shSans(SHDesignMetrics.replyTextSize))
                    .foregroundStyle(sh.textPrimary)
                    .tint(sh.lantern)
                    .focused($replyFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if let result = SHReturnKey.lineBreak(for: press) { return result }
                        onReply()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard let onClose else { return .ignored }
                        onClose()
                        return .handled
                    }
                    .padding(.horizontal, SHDesignMetrics.replyFieldPadding)
                    .padding(.vertical, SH.Space.s)
                    .frame(minHeight: SHDesignMetrics.replyFieldHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: SHDesignMetrics.replyFieldRadius)
                            .strokeBorder(sh.lineStrong, lineWidth: SHDesignMetrics.lineWidth)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { replyFocused = true }
            }
        }
        .padding(.vertical, SHDesignMetrics.threadPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.threadPaddingHorizontal)
        .frame(width: SHDesignMetrics.threadWidth, alignment: .leading)
        .shPopover(radius: SHDesignMetrics.threadRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment by \(author)")
    }
}

/// A comment where it is listed (SHCommentCard): the chat, where the design agent's answer joins
/// it (`shCommentAnswer`), and the Comments tab. 12×14 padding, 8pt between its parts, radius 10,
/// a 1px `lineStrong` line on `bgRaised`. Its header in 11.5 `textTertiary`: the small pin, "on"
/// and the board · element in `textPrimary` semibold, and author · age trailing; then the comment.
public struct SHCommentCard: View, Equatable {
    let number: Int
    /// "A · Checkout funnel".
    let target: String
    /// "You · 2m".
    let meta: String
    let text: String
    /// The design agent's answer follows in the card: its bottom edge stays open for it.
    let continues: Bool
    let onOpen: (() -> Void)?
    let onResolve: (() -> Void)?
    /// Seeds the same hover state in previews and offscreen control tests.
    let hovering: Bool
    @State private var pointerInside = false
    private enum Control: Hashable { case open, resolve }
    @FocusState private var focused: Control?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    public init(number: Int, target: String, meta: String, text: String, continues: Bool = false,
                onOpen: (() -> Void)? = nil, onResolve: (() -> Void)? = nil, hovering: Bool = false) {
        self.number = number
        self.target = target
        self.meta = meta
        self.text = text
        self.continues = continues
        self.onOpen = onOpen
        self.onResolve = onResolve
        self.hovering = hovering
    }

    nonisolated public static func == (a: Self, b: Self) -> Bool {
        a.number == b.number && a.target == b.target && a.meta == b.meta && a.text == b.text
            && a.continues == b.continues && a.hovering == b.hovering
            && (a.onOpen == nil) == (b.onOpen == nil) && (a.onResolve == nil) == (b.onResolve == nil)
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("design.comment")
        let showResolve = onResolve != nil && (pointerInside || hovering || focused != nil || voiceOver)
        ZStack(alignment: .topTrailing) {
            if let onOpen {
                Button(action: onOpen) { card(hidingMeta: showResolve) }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: SHDesignMetrics.commentCardRadius))
                    .focused($focused, equals: .open)
                    .accessibilityLabel("Open comment \(number)")
                    .accessibilityValue("\(target), \(meta), \(text)")
                    .accessibilityHint("Open the comment's board")
                    .accessibilityActions {
                        if let onResolve { Button("Resolve", action: onResolve) }
                    }
            } else {
                card(hidingMeta: showResolve)
            }
            if let onResolve {
                Button("Resolve", action: onResolve)
                    .buttonStyle(.sh(.ghost, size: .s))
                    .focused($focused, equals: .resolve)
                    .help("Resolve comment")
                    .accessibilityLabel("Resolve comment \(number)")
                    .opacity(showResolve ? 1 : 0)
                    .allowsHitTesting(showResolve)
                    .accessibilityHidden(!showResolve)
                    .padding(.trailing, SHDesignMetrics.commentCardPaddingHorizontal)
                    .padding(.top, SHDesignMetrics.commentCardPaddingVertical - (SH.Height.controlS - SHDesignMetrics.cardPinSize) / 2)
            }
        }
        .onHover { pointerInside = $0 }
    }

    private func card(hidingMeta: Bool) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SHDesignMetrics.commentCardSpacing) {
            HStack(spacing: SH.Space.m) {
                SHCommentPin(number, size: .card)
                (Text("on ") + Text(target).fontWeight(.semibold).foregroundStyle(sh.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SH.Space.m)
                Text(meta).lineLimit(1)
                    .frame(minWidth: onResolve == nil ? nil : SH.Height.controlS, alignment: .trailing)
                    .opacity(hidingMeta ? 0 : 1)
            }
            .font(.shSans(SHDesignMetrics.commentMetaSize))
            .foregroundStyle(sh.textTertiary)
            SHCommentText(text)
        }
        .padding(.top, SHDesignMetrics.commentCardPaddingVertical)
        .padding(.bottom, continues ? 0 : SHDesignMetrics.commentCardPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.commentCardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SHCommentCardChrome(edge: continues ? .top : nil) }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The design agent's answer inside the comment card above it (DZCanvas): 8pt under the
    /// comment, under a hairline, inside the card's sides and bottom. `bridge` is the room a list
    /// puts between the two rows: the answer moves up across it to join the card.
    public func shCommentAnswer(bridge: CGFloat) -> some View {
        padding(.top, SHDesignMetrics.entryGap)
            .overlay(alignment: .top) { SHHairline() }
            .padding(.top, SHDesignMetrics.commentCardSpacing)
            .padding(.bottom, SHDesignMetrics.commentCardPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.commentCardPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SHCommentCardChrome(edge: .bottom) }
            .padding(.top, -bridge)
    }
}

/// A comment's words: 13/1.5, selectable.
struct SHCommentText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .shText(size: SHDesignMetrics.commentTextSize, lineHeight: SHDesignMetrics.commentLineHeight)
            .foregroundStyle(Color.sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card's fill and line: whole, or the top or bottom part of a card an answer splits across
/// two rows (the open edge drawn neither rounded nor lined).
struct SHCommentCardChrome: View {
    /// The part this is: `.top` leaves the bottom open, `.bottom` the top; nil is the whole card.
    let edge: VerticalEdge?

    var body: some View {
        let radius = SHDesignMetrics.commentCardRadius
        let line = SHDesignMetrics.lineWidth
        let shape = UnevenRoundedRectangle(topLeadingRadius: edge == .bottom ? 0 : radius,
                                           bottomLeadingRadius: edge == .top ? 0 : radius,
                                           bottomTrailingRadius: edge == .top ? 0 : radius,
                                           topTrailingRadius: edge == .bottom ? 0 : radius)
        shape.fill(Color.sh.bgRaised)
            .overlay {
                // Inset by half the line so it draws inside, except across the open edge, where the
                // other part's line carries on.
                SHOpenCardOutline(radius: radius, open: edge.map { $0 == .top ? .bottom : .top })
                    .stroke(Color.sh.lineStrong, lineWidth: line)
                    .padding(.horizontal, line / 2)
                    .padding(.top, edge == .bottom ? 0 : line / 2)
                    .padding(.bottom, edge == .top ? 0 : line / 2)
            }
    }
}

/// A rounded rectangle's outline, with one edge (and its corners) left out when `open` names it.
struct SHOpenCardOutline: Shape {
    let radius: CGFloat
    let open: VerticalEdge?

    func path(in rect: CGRect) -> Path {
        guard let open else { return RoundedRectangle(cornerRadius: radius).path(in: rect) }
        let r = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        // The closed edge's y, and the open edge's.
        let closed = open == .bottom ? rect.minY : rect.maxY
        let away = open == .bottom ? rect.maxY : rect.minY
        path.move(to: CGPoint(x: rect.minX, y: away))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: closed), tangent2End: CGPoint(x: rect.midX, y: closed), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: closed), tangent2End: CGPoint(x: rect.maxX, y: away), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: away))
        return path
    }
}

/// "now", "2m", "3h", "4d": how long ago a comment or an answer was written, as the boards say it.
public func shCommentAge(since milliseconds: Double, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince1970 - milliseconds / 1000)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
}
