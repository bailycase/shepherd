import SwiftUI

/// A description with inline markup, as the Settings boards write it: `` `code` `` for a flag,
/// file or tool name (mono on `bgSunken`, `xs` corners and side padding, no line) and
/// `**name**` for an option the sentence explains (medium weight, a step brighter in
/// `textPrimary`). Everything else takes the caller's color.
///
/// The markup is parsed once per string (Settings' copy is static), never per render.
public struct NWMarkupText: View {
    let source: String
    let size: CGFloat
    let codeSize: CGFloat
    let lineHeight: CGFloat

    /// `size` and `lineHeight` set the sentence (12.5/1.45 in a settings row); code is set at
    /// `codeSize`.
    public init(_ source: String, size: CGFloat = 12.5, codeSize: CGFloat = 11.5, lineHeight: CGFloat = 1.45) {
        self.source = source
        self.size = size
        self.codeSize = codeSize
        self.lineHeight = lineHeight
    }

    public var body: some View {
        let pieces = NWMarkupTextParser.pieces(source)
        if pieces.contains(where: \.isCode) {
            Self.text(pieces, size: size, codeSize: codeSize)
                .nwText(size: size, lineHeight: lineHeight)
                .textRenderer(NWInlineCodeRenderer(fill: Color.nw.bgSunken))
        } else {
            Self.text(pieces, size: size, codeSize: codeSize)
                .nwText(size: size, lineHeight: lineHeight)
        }
    }

    /// The sentence as one `Text`. Code is padded `xs` on each side: the character before it and
    /// its own last character are kerned by the padding, and the renderer fills that room.
    @MainActor static func text(_ pieces: [NWMarkupTextParser.Piece], size: CGFloat, codeSize: CGFloat) -> Text {
        let pad = NWInlineCodeRenderer.padding
        var result = Text(verbatim: "")
        for (index, piece) in pieces.enumerated() {
            let nextIsCode = index + 1 < pieces.count && pieces[index + 1].isCode
            switch piece {
            case .plain(let string):
                result = Text("\(result)\(kernedTail(Text(verbatim: string), string: string, kern: nextIsCode ? pad : 0))")
            case .strong(let string):
                let strong = { (part: String) in
                    Text(verbatim: part).font(.nwSans(size, .medium)).foregroundStyle(Color.nw.textPrimary)
                }
                if nextIsCode, let last = string.last {
                    result = Text("\(result)\(strong(String(string.dropLast())))\(strong(String(last)).kerning(pad))")
                } else {
                    result = Text("\(result)\(strong(string))")
                }
            case .code(let string):
                let code = { (part: String) in
                    Text(verbatim: part).font(.nwMono(codeSize)).customAttribute(NWInlineCodeAttribute())
                }
                guard let last = string.last else { continue }
                result = Text("\(result)\(code(String(string.dropLast())))\(code(String(last)).kerning(pad))")
            }
        }
        return result
    }

    /// `text` with its last character kerned by `kern` (room for a code run's leading padding).
    private static func kernedTail(_ text: Text, string: String, kern: CGFloat) -> Text {
        guard kern > 0, let last = string.last else { return text }
        return Text("\(Text(verbatim: String(string.dropLast())))\(Text(verbatim: String(last)).kerning(kern))")
    }
}

/// Splits inline Markdown into plain, strong and code pieces, and remembers each string's pieces.
@MainActor enum NWMarkupTextParser {
    enum Piece: Equatable {
        case plain(String)
        case strong(String)
        case code(String)

        var isCode: Bool {
            if case .code = self { return true }
            return false
        }
    }

    private static var cache: [String: [Piece]] = [:]

    static func pieces(_ source: String) -> [Piece] {
        if let cached = cache[source] { return cached }
        let parsed = parse(source)
        cache[source] = parsed
        return parsed
    }

    /// Adjacent runs of one kind merge, so a sentence is as few pieces as its markup allows.
    nonisolated static func parse(_ source: String) -> [Piece] {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return [.plain(source)] }
        var pieces: [Piece] = []
        for run in attributed.runs {
            let string = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let piece: Piece = intent.contains(.code) ? .code(string)
                : intent.contains(.stronglyEmphasized) ? .strong(string)
                : .plain(string)
            switch (pieces.last, piece) {
            case (.plain(let a)?, .plain(let b)): pieces[pieces.count - 1] = .plain(a + b)
            case (.strong(let a)?, .strong(let b)): pieces[pieces.count - 1] = .strong(a + b)
            default: pieces.append(piece)
            }
        }
        return pieces
    }
}

/// Marks the runs of an inline code piece, so `NWInlineCodeRenderer` fills behind them.
struct NWInlineCodeAttribute: TextAttribute {}

/// Draws a rounded fill behind each stretch of inline code on a line (its runs merged, padded by
/// `padding` on each side and a point above and below), then every run of the text over it.
struct NWInlineCodeRenderer: TextRenderer {
    /// `NW.Space.xs`: the room each side of the code.
    static let padding: CGFloat = NW.Space.xs
    let fill: Color

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 1, leading: Self.padding, bottom: 1, trailing: Self.padding)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var stretch: CGRect?
            for run in line {
                if run[NWInlineCodeAttribute.self] != nil {
                    let bounds = run.typographicBounds.rect
                    stretch = stretch.map { $0.union(bounds) } ?? bounds
                } else if let finished = stretch {
                    fillBehind(finished, in: &context)
                    stretch = nil
                }
            }
            if let finished = stretch { fillBehind(finished, in: &context) }
        }
        for line in layout {
            context.draw(line)
        }
    }

    /// The code's own last character carries the trailing padding as kerning, so only the
    /// leading side grows here.
    private func fillBehind(_ bounds: CGRect, in context: inout GraphicsContext) {
        let rect = CGRect(x: bounds.minX - Self.padding, y: bounds.minY - 1,
                          width: bounds.width + Self.padding, height: bounds.height + 2)
        context.fill(RoundedRectangle(cornerRadius: NW.Radius.xs).path(in: rect), with: .color(fill))
    }
}

#Preview("Inline markup") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWMarkupText("Preselected in the New Agent sheet. “Use pi's default” passes no `--model` at all.")
            NWMarkupText("**Remote default** starts clean from origin's default branch. **Current branch** stacks on your checkout's in-progress work.")
            NWMarkupText("Runs `pi update --extensions` once a day.")
        }
        .foregroundStyle(Color.nw.textSecondary)
        .frame(width: 420, alignment: .leading)
        .padding(NW.Space.xl)
    }
}
