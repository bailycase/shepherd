import SwiftUI

// Pencil markup on the iPad canvas (iPadDesign): the palette that floats while ink is on the
// canvas, and in the chat the design agent's comments proposed from it.

/// The markup palette (iPadDesign), floating 28pt over the canvas's bottom middle while there is
/// ink: four 44pt tools (the pen, the marker, the eraser, Comment; the current one on
/// `bgSelected`), a divider, the three inks (22pt, the current one ringed in its own color 2pt
/// out), a divider, and Done in the link blue. A raised capsule with the popover's line and
/// shadow.
public struct SHMarkupPalette: View {
    public enum Tool: String, CaseIterable, Sendable {
        case pen, marker, eraser, comment

        public var title: String {
            switch self {
            case .pen: "Pen"
            case .marker: "Marker"
            case .eraser: "Eraser"
            case .comment: "Comment"
            }
        }
    }

    /// The inks: lantern, the link blue, and the primary text color.
    public enum Ink: String, CaseIterable, Sendable {
        case lantern, running, text

        @MainActor public var color: Color {
            switch self {
            case .lantern: Color.sh.lantern
            case .running: Color.sh.running
            case .text: Color.sh.textPrimary
            }
        }

        public var title: String {
            switch self {
            case .lantern: "Lantern"
            case .running: "Blue"
            case .text: "White"
            }
        }
    }

    @Binding var tool: Tool
    @Binding var ink: Ink
    /// Reading the markup: Done waits.
    let reading: Bool
    let done: () -> Void

    public init(tool: Binding<Tool>, ink: Binding<Ink>, reading: Bool = false, done: @escaping () -> Void) {
        _tool = tool
        _ink = ink
        self.reading = reading
        self.done = done
    }

    public var body: some View {
        let M = SHDesignMetrics.self
        HStack(spacing: M.markupSpacing) {
            ForEach(Tool.allCases, id: \.self) { item in
                Button { tool = item } label: {
                    SHMarkupToolGlyph(tool: item)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .background(tool == item ? Color.sh.bgSelected : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tool == item ? .isSelected : [])
            }
            divider
            ForEach(Ink.allCases, id: \.self) { item in
                Button { ink = item } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: M.markupSwatch, height: M.markupSwatch)
                        .overlay {
                            if ink == item {
                                Circle().strokeBorder(item.color, lineWidth: M.markupSwatchRing)
                                    .padding(-(M.markupSwatchRing + M.markupSwatchGap))
                            }
                        }
                        .frame(width: M.markupSwatchTarget, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title) ink")
                .accessibilityAddTraits(ink == item ? .isSelected : [])
            }
            divider
            Button(action: done) {
                Text("Done")
                    .font(.shSans(M.markupDoneSize, .semibold))
                    .foregroundStyle(Color.sh.running)
                    .padding(.horizontal, SH.Space.xs)
                    .frame(minHeight: SH.Height.touch)
                    .contentShape(Rectangle())
                    .opacity(reading ? SHControlMetrics.disabledOpacity : 1)
            }
            .buttonStyle(.plain)
            .disabled(reading)
            .accessibilityLabel(reading ? "Reading your markup" : "Done")
        }
        .padding(.vertical, M.markupPaddingVertical)
        .padding(.horizontal, M.markupPaddingHorizontal)
        .shPopover(radius: (SH.Height.touch + 2 * M.markupPaddingVertical) / 2)
    }

    private var divider: some View {
        SHHairline(.vertical)
            .frame(height: SHDesignMetrics.markupDividerHeight)
            .padding(.horizontal, SHDesignMetrics.markupDividerMargin)
    }
}

/// A markup tool's glyph (iPadDesign): a pencil with a lantern tip, a marker with a blue tip, an
/// eraser, and Comment's bubble, 20 × 26 in `textSecondary`.
struct SHMarkupToolGlyph: View {
    let tool: SHMarkupPalette.Tool

    var body: some View {
        let M = SHDesignMetrics.self
        Group {
            switch tool {
            case .comment:
                Image(systemName: "text.bubble")
                    .font(.shSans(M.markupGlyphWidth))
                    .foregroundStyle(Color.sh.textSecondary)
            default:
                Canvas { context, size in
                    let scale = CGAffineTransform(scaleX: size.width / 20, y: size.height / 26)
                    let line = StrokeStyle(lineWidth: M.markupGlyphLine, lineCap: .round, lineJoin: .round)
                    let body = Self.body(tool).applying(scale)
                    context.fill(body, with: .color(Color.sh.bgBase))
                    context.stroke(body, with: .color(Color.sh.textSecondary), style: line)
                    switch tool {
                    case .pen:
                        let tip = Path { $0.move(to: CGPoint(x: 8, y: 5.5)); $0.addLine(to: CGPoint(x: 12, y: 5.5)) }
                        context.stroke(tip.applying(scale), with: .color(Color.sh.lantern), lineWidth: M.markupTipLine)
                    case .marker:
                        context.fill(Path(CGRect(x: 7, y: 3, width: 6, height: 4)).applying(scale), with: .color(Color.sh.running))
                    case .eraser:
                        let band = Path { $0.move(to: CGPoint(x: 5, y: 10)); $0.addLine(to: CGPoint(x: 15, y: 10)) }
                        context.stroke(band.applying(scale), with: .color(Color.sh.textSecondary), style: line)
                    case .comment:
                        break
                    }
                }
            }
        }
        .frame(width: M.markupGlyphWidth, height: M.markupGlyphHeight)
        .accessibilityHidden(true)
    }

    /// The tool's outline in its 20 × 26 box.
    static func body(_ tool: SHMarkupPalette.Tool) -> Path {
        switch tool {
        case .pen:
            Path { p in
                p.move(to: CGPoint(x: 6, y: 25)); p.addLine(to: CGPoint(x: 6, y: 9)); p.addLine(to: CGPoint(x: 10, y: 2))
                p.addLine(to: CGPoint(x: 14, y: 9)); p.addLine(to: CGPoint(x: 14, y: 25)); p.closeSubpath()
            }
        case .marker:
            Path { p in
                p.move(to: CGPoint(x: 5, y: 25)); p.addLine(to: CGPoint(x: 5, y: 11)); p.addLine(to: CGPoint(x: 7, y: 7))
                p.addLine(to: CGPoint(x: 13, y: 7)); p.addLine(to: CGPoint(x: 15, y: 11)); p.addLine(to: CGPoint(x: 15, y: 25))
                p.closeSubpath()
            }
        case .eraser, .comment:
            Path(roundedRect: CGRect(x: 5, y: 4, width: 10, height: 21), cornerRadius: 2)
        }
    }
}

/// The design agent's comments proposed from Pencil markup, in the chat (iPadDesign): each a
/// comment card numbered as its pin will be, "from your markup", then Apply both (primary: each
/// goes to the agent as a comment) and Keep as comments, and a footnote.
public struct SHMarkupProposals: View, Equatable {
    public struct Card: Equatable, Identifiable, Sendable {
        public var id: String
        public var number: Int
        /// "A · phone › Steps list".
        public var target: String
        public var text: String

        public init(id: String, number: Int, target: String, text: String) {
            self.id = id
            self.number = number
            self.target = target
            self.text = text
        }
    }

    public enum State: Equatable, Sendable {
        /// Waiting for the viewer.
        case open
        /// Applying or keeping them.
        case working
        /// Kept: what became of them, said in a line.
        case settled(String)
    }

    let cards: [Card]
    let state: State
    let footnote: String?
    let apply: () -> Void
    let keep: () -> Void

    public init(cards: [Card], state: State, footnote: String? = nil, apply: @escaping () -> Void, keep: @escaping () -> Void) {
        self.cards = cards
        self.state = state
        self.footnote = footnote
        self.apply = apply
        self.keep = keep
    }

    public static func == (a: SHMarkupProposals, b: SHMarkupProposals) -> Bool {
        a.cards == b.cards && a.state == b.state && a.footnote == b.footnote
    }

    /// "Apply both" for two, "Apply" for one, "Apply all" for more.
    public static func applyTitle(_ count: Int) -> String {
        count == 1 ? "Apply" : count == 2 ? "Apply both" : "Apply all"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.markupProposalsSpacing) {
            ForEach(cards) { card in
                SHCommentCard(number: card.number, target: card.target, meta: "from your markup", text: card.text)
                    .equatable()
            }
            switch state {
            case .open, .working:
                HStack(spacing: SH.Space.m) {
                    Button(Self.applyTitle(cards.count), action: apply)
                        .buttonStyle(.sh(.primary, size: .l))
                    Button("Keep as comments", action: keep)
                        .buttonStyle(.sh(.secondary, size: .l))
                }
                .disabled(state == .working)
            case .settled(let line):
                Text(line)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
            }
            if let footnote {
                Text(footnote)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
