import SwiftUI

// A design's comments (DZCanvas, DZTweak, NWDesignTool): the numbered pin on the canvas, the
// thread beside it, and the card the chat and the Comments tab show. Pins are lantern, because a
// pin is something the viewer asked for; selection stays running blue.

/// The numbered pin (NWCommentPin): a lantern teardrop, round but for its bottom-leading corner,
/// which is its point, set on the element's top-trailing corner. On the canvas it is 26pt (a 4pt
/// point, mono 12 bold) with a small shadow; in a card's header 18pt (a 3pt point, mono 10 bold).
public struct NWCommentPin: View {
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
        let side = size == .canvas ? NWDesignMetrics.pinSize : NWDesignMetrics.cardPinSize
        let point = size == .canvas ? NWDesignMetrics.pinPoint : NWDesignMetrics.cardPinPoint
        let shape = UnevenRoundedRectangle(topLeadingRadius: side / 2, bottomLeadingRadius: point,
                                           bottomTrailingRadius: side / 2, topTrailingRadius: side / 2)
        Text("\(number)")
            .font(.nwMono(size == .canvas ? NWDesignMetrics.pinTextSize : NWDesignMetrics.cardPinTextSize, .bold))
            .foregroundStyle(Color.nw.textOnLantern)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: side, height: side)
            .background(Color.nw.lantern, in: shape)
            .shadow(color: size == .canvas ? Color.nw.knobShadow : .clear,
                    radius: NWDesignMetrics.pinShadowRadius, y: NWDesignMetrics.pinShadowY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Comment \(number)")
    }
}

/// One entry of a thread under its comment: the design agent's answer, or the viewer's reply.
public struct NWCommentEntry: Identifiable, Equatable, Sendable {
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

/// A comment on the canvas beside its pin, under its element (NWCommentThread; DZTweak): 320pt, a
/// raised card with the popover's line and shadow at radius 12. The author and age with Resolve
/// trailing, the comment, each answer under a hairline, and the Reply… field.
public struct NWCommentThread: View {
    let author: String
    let age: String
    /// Said after the age when the comment's element is gone ("element changed").
    let note: String?
    let text: String
    let entries: [NWCommentEntry]
    @Binding var reply: String
    let onResolve: (() -> Void)?
    let onReply: (() -> Void)?
    let onClose: (() -> Void)?
    @FocusState private var replyFocused: Bool

    public init(author: String, age: String, note: String? = nil, text: String, entries: [NWCommentEntry] = [],
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NWDesignMetrics.threadSpacing) {
            HStack(spacing: NW.Space.m) {
                Text(author).font(.nwSans(NWDesignMetrics.commentMetaSize, .semibold)).foregroundStyle(nw.textPrimary)
                Text([age, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.nwSans(NWDesignMetrics.commentMetaSize))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let onResolve {
                    Button("Resolve", systemImage: "checkmark", action: onResolve)
                        .buttonStyle(.nw(.ghost, size: .s))
                }
            }
            NWCommentText(text)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: NWDesignMetrics.entrySpacing) {
                    (Text(entry.author).fontWeight(.semibold).foregroundStyle(nw.textPrimary)
                        + Text(" · \(entry.age)").foregroundStyle(nw.textTertiary))
                        .font(.nwSans(NWDesignMetrics.commentMetaSize))
                    NWCommentText(entry.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, NWDesignMetrics.entryGap)
                .overlay(alignment: .top) { NWHairline() }
            }
            if let onReply {
                TextField("Reply…", text: $reply, prompt: Text("Reply…").foregroundStyle(nw.textTertiary), axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.nwSans(NWDesignMetrics.replyTextSize))
                    .foregroundStyle(nw.textPrimary)
                    .tint(nw.lantern)
                    .focused($replyFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { reply += "\n"; return .handled }
                        onReply()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard let onClose else { return .ignored }
                        onClose()
                        return .handled
                    }
                    .padding(.horizontal, NWDesignMetrics.replyFieldPadding)
                    .padding(.vertical, NW.Space.s)
                    .frame(minHeight: NWDesignMetrics.replyFieldHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: NWDesignMetrics.replyFieldRadius)
                            .strokeBorder(nw.lineStrong, lineWidth: NWDesignMetrics.lineWidth)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { replyFocused = true }
            }
        }
        .padding(.vertical, NWDesignMetrics.threadPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.threadPaddingHorizontal)
        .frame(width: NWDesignMetrics.threadWidth, alignment: .leading)
        .nwPopover(radius: NWDesignMetrics.threadRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment by \(author)")
    }
}

/// A comment where it is listed (NWCommentCard): the chat, where the design agent's answer joins
/// it (`nwCommentAnswer`), and the Comments tab. 12×14 padding, 8pt between its parts, radius 10,
/// a 1px `lineStrong` line on `bgRaised`. Its header in 11.5 `textTertiary`: the small pin, "on"
/// and the board · element in `textPrimary` semibold, and author · age trailing; then the comment.
public struct NWCommentCard: View, Equatable {
    let number: Int
    /// "A · Checkout funnel".
    let target: String
    /// "You · 2m".
    let meta: String
    let text: String
    /// The design agent's answer follows in the card: its bottom edge stays open for it.
    let continues: Bool

    public init(number: Int, target: String, meta: String, text: String, continues: Bool = false) {
        self.number = number
        self.target = target
        self.meta = meta
        self.text = text
        self.continues = continues
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("design.comment")
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NWDesignMetrics.commentCardSpacing) {
            HStack(spacing: NW.Space.m) {
                NWCommentPin(number, size: .card)
                (Text("on ") + Text(target).fontWeight(.semibold).foregroundStyle(nw.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NW.Space.m)
                Text(meta).lineLimit(1)
            }
            .font(.nwSans(NWDesignMetrics.commentMetaSize))
            .foregroundStyle(nw.textTertiary)
            NWCommentText(text)
        }
        .padding(.top, NWDesignMetrics.commentCardPaddingVertical)
        .padding(.bottom, continues ? 0 : NWDesignMetrics.commentCardPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.commentCardPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { NWCommentCardChrome(edge: continues ? .top : nil) }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The design agent's answer inside the comment card above it (DZCanvas): under a hairline,
    /// 8pt below it, inside the card's sides and bottom. `bridge` is the room between the two
    /// rows, which the card's sides cross.
    public func nwCommentAnswer(bridge: CGFloat) -> some View {
        padding(.top, NWDesignMetrics.entryGap)
            .overlay(alignment: .top) { NWHairline() }
            .padding(.top, NWDesignMetrics.commentCardSpacing)
            .padding(.bottom, NWDesignMetrics.commentCardPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.commentCardPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { NWCommentCardChrome(edge: .bottom).padding(.top, -bridge) }
    }
}

/// A comment's words: 13/1.5, selectable.
struct NWCommentText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .nwText(size: NWDesignMetrics.commentTextSize, lineHeight: NWDesignMetrics.commentLineHeight)
            .foregroundStyle(Color.nw.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card's fill and line: whole, or the top or bottom part of a card an answer splits across
/// two rows (the open edge drawn neither rounded nor lined).
struct NWCommentCardChrome: View {
    /// The part this is: `.top` leaves the bottom open, `.bottom` the top; nil is the whole card.
    let edge: VerticalEdge?

    var body: some View {
        let radius = NWDesignMetrics.commentCardRadius
        let line = NWDesignMetrics.lineWidth
        let shape = UnevenRoundedRectangle(topLeadingRadius: edge == .bottom ? 0 : radius,
                                           bottomLeadingRadius: edge == .top ? 0 : radius,
                                           bottomTrailingRadius: edge == .top ? 0 : radius,
                                           topTrailingRadius: edge == .bottom ? 0 : radius)
        shape.fill(Color.nw.bgRaised)
            .overlay {
                // Inset by half the line so it draws inside, except across the open edge, where the
                // other part's line carries on.
                NWOpenCardOutline(radius: radius, open: edge.map { $0 == .top ? .bottom : .top })
                    .stroke(Color.nw.lineStrong, lineWidth: line)
                    .padding(.horizontal, line / 2)
                    .padding(.top, edge == .bottom ? 0 : line / 2)
                    .padding(.bottom, edge == .top ? 0 : line / 2)
            }
    }
}

/// A rounded rectangle's outline, with one edge (and its corners) left out when `open` names it.
struct NWOpenCardOutline: Shape {
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
public func nwCommentAge(since milliseconds: Double, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince1970 - milliseconds / 1000)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
}
