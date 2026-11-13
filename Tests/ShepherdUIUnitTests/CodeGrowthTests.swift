import AppKit
import SwiftUI
import Testing
@testable import ShepherdUI

/// A fence a reply is writing changes at its end, and its field takes only the change.
@Suite("Code growth")
@MainActor
struct CodeGrowthTests {
    private static let font = NSFont.monospacedSystemFont(ofSize: SHTextStyle.code.size, weight: .regular)
    private static let lineSpacing = SHTextStyle.code.lineSpacing + 0.6
    private static var styling: SHNativeCodeText.Styling {
        SHNativeCodeText.Styling(font: font, lineSpacing: lineSpacing, foreground: Color.sh.textPrimary)
    }

    private static func field() -> SHNativeCodeText.Field {
        let field = SHNativeCodeText.Field(labelWithString: "")
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.font = font
        return field
    }

    // MARK: The text two versions share

    @Test(arguments: [
        ("", "", 0), ("", "a", 0), ("abc", "abc", 3), ("abc", "abd", 2), ("abc", "abcdef", 3), ("abcdef", "abc", 3),
        ("🐑 a", "🐑 b", 3), ("a🐑", "a🐏", 1), ("é", "è", 0), ("sheep é", "sheep é!", 7), ("a\nb", "a\nc", 2),
    ] as [(String, String, Int)])
    func theTextTwoVersionsShareIsMeasuredInUTF16UnitsAndNeverCutsAScalar(a: String, b: String, shared: Int) {
        #expect(SHNativeCodeText.Field.sharedPrefixLength(a, b) == shared)
        #expect(SHNativeCodeText.Field.sharedPrefixLength(b, a) == shared)
    }

    // MARK: The field

    private func attributed(_ code: String, colors: SHCodeColors) -> AttributedString {
        var value = AttributedString(code)
        for span in colors.spans {
            let start = value.index(value.startIndex, offsetByCharacters: span.range.lowerBound)
            let end = value.index(start, offsetByCharacters: span.range.count)
            value[start..<end].foregroundColor = span.color
        }
        return value
    }

    /// Colors for the lines `range` of `lines`: the `let`, the string and the comment of each.
    private func spans(of lines: [String], _ range: Range<Int>) -> [SHCodeColors.Span] {
        let palette = [Color.sh.synKeyword, Color.sh.synString, Color.sh.synComment]
        var spans: [SHCodeColors.Span] = []
        var offset = lines[..<range.lowerBound].reduce(0) { $0 + $1.utf16.count + 1 }
        for line in lines[range] {
            let text = line as NSString
            for (index, word) in ["let", "\"flock\"", "// note"].enumerated() {
                let found = text.range(of: word)
                if found.location != NSNotFound {
                    spans.append(SHCodeColors.Span(range: (offset + found.location)..<(offset + found.location + found.length), color: palette[index]))
                }
            }
            offset += text.length + 1
        }
        return spans
    }

    /// Chunks grow the text, colors land some lines behind it, and one recoloring reaches back before the lines it
    /// follows: after each, the field holds what a field built whole from the same text and colors holds.
    @Test func aFieldGrownByChunksHoldsWhatAWholeBuildHolds() {
        let lines = (0..<120).map { "let sheep\($0) = \"flock\" // note \($0)" }
        let field = Self.field()
        var colors = SHCodeColors()
        var colored = 0
        for end in stride(from: 3, through: 120, by: 3) {
            // Colors land every second chunk; the rest of the lines stay plain until they do.
            if end.isMultiple(of: 6) {
                let from = colored > 6 && end == 60 ? colored - 6 : colored
                colors.recolor(from: lines[..<from].reduce(0) { $0 + $1.utf16.count + 1 }, with: spans(of: lines, from..<(end - 2)))
                colored = end - 2
            }
            let code = lines[..<end].joined(separator: "\n")
            field.showGrowing(code, colors: colors, styling: Self.styling)
            let whole = SHNativeCodeText.attributedCode(code, highlighted: attributed(code, colors: colors), font: Self.font, lineSpacing: Self.lineSpacing)
            #expect(field.attributedStringValue.isEqual(to: whole), "\(end) lines")
        }
        #expect(colors.revision > 10)
    }

    @Test func aFieldStartsOverWhenTheTextIsNotAGrowthOfWhatItHolds() {
        let field = Self.field()
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [SHCodeColors.Span(range: 0..<3, color: Color.sh.synKeyword)])
        field.showGrowing("let a = 1", colors: colors, styling: Self.styling)
        field.showGrowing("let a = 1\nlet b = 2", colors: colors, styling: Self.styling)
        #expect(field.attributedStringValue.string == "let a = 1\nlet b = 2")

        field.showGrowing("var c = 3", colors: colors, styling: Self.styling)
        #expect(field.attributedStringValue.string == "var c = 3")
        #expect(field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor(Color.sh.synKeyword))

        var another = SHCodeColors()
        another.recolor(from: 0, with: [])
        field.showGrowing("var c = 3", colors: another, styling: Self.styling)
        #expect(field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor(Color.sh.textPrimary),
                "the colors of another fence are not a revision of these")
    }

    @Test func theCodeIsLeftAloneWhenNothingChanged() {
        let field = Self.field()
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [])
        field.showGrowing("let a = 1", colors: colors, styling: Self.styling)
        let held = field.attributedStringValue
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        field.showGrowing("let a = 1", colors: colors, styling: Self.styling)
        #expect(field.attributedStringValue === held || field.attributedStringValue.isEqual(to: held))
        #expect(SHRenderProbe.count("thread.codeAttributes") == 0)
    }

    @Test func aGrownFencePastAnAccentedLetterKeepsTheTextOfAWholeBuild() {
        let field = Self.field()
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [])
        for code in ["let a = \"é", "let a = \"é🐑 flock\"", "let a = \"é🐑 flock\" // 🐏 done\nlet b"] {
            field.showGrowing(code, colors: colors, styling: Self.styling)
            #expect(field.attributedStringValue.string == code)
        }
    }

    // MARK: What the renderer lays out is what the field measures

    /// The size of a fence a reply is writing comes from its renderer's layout, which only the new text changes.
    /// It is the size the field's own cell measures, for any shape of text.
    @Test(arguments: [
        "x", "let sheep = 1", "a\nb", "a\n\nb", "\tindent\n\t\tmore", " trailing  ", String(repeating: "x", count: 3_000),
        (0..<1_500).map { "let item\($0) = compute(\($0), from: sheep)" }.joined(separator: "\n"),
        (0..<3_000).map { "let item\($0) = compute(\($0), from: sheep)" }.joined(separator: "\n"),
    ])
    func theRenderersLayoutHasTheSizeOfTheFieldsOwnMeasure(code: String) throws {
        let field = Self.field()
        field.setCode(SHNativeCodeText.attributedCode(code, highlighted: nil, font: Self.font, lineSpacing: Self.lineSpacing))
        let renderer = SHNativeCodeText.RendererPool(limit: 1).take(
            frame: .zero, inset: NSSize(width: field.alignmentRectInsets.left, height: field.alignmentRectInsets.top))
        renderer.textStorage?.setAttributedString(field.attributedStringValue)

        let size = try #require(SHNativeCodeText.Field.layoutSize(of: renderer))

        #expect(size == field.intrinsicContentSize, "\(code.count) characters")
    }

    @Test func aRendererHoldingNothingHasNoSize() {
        let renderer = SHNativeCodeText.RendererPool(limit: 1).take(frame: .zero, inset: .zero)
        #expect(SHNativeCodeText.Field.layoutSize(of: renderer) == nil)
    }
}
