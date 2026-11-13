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

/// The iPhone and iPad draw a fence a reply is writing as blocks of finished lines and a tail, so a chunk lays out the
/// tail and not the fence.
@Suite("Fence blocks")
struct FenceBlocksTests {
    private static let size = SHFenceBlocks.linesPerBlock

    private static func line(_ n: Int) -> String {
        switch n % 5 {
        case 0: "func handle\(n)(_ row: OutboxRow, broker: Broker) async throws -> Ack {"
        case 1: "    let lease = try await row.lease(ttl: .seconds(\(10 + n % 20)))"
        case 2: "    defer { lease.release() } // \(n)"
        case 3: ""
        default: "}"
        }
    }

    private static func fence(lines: Int) -> String { (0..<lines).map(line).joined(separator: "\n") }

    /// The fence as a reply writes it: `chunk` characters at a time.
    private static func steps(of code: String, chunk: Int) -> [String] {
        var grown = "", steps: [String] = []
        var rest = Substring(code)
        while !rest.isEmpty {
            let piece = rest.prefix(chunk)
            grown += piece
            rest = rest.dropFirst(chunk)
            steps.append(grown)
        }
        return steps
    }

    /// The text a step lays out that the step before did not: the blocks that are new or changed, and the tail if it changed.
    private static func laidOut(_ next: SHFenceBlocks, after previous: SHFenceBlocks) -> Int {
        let before = Dictionary(uniqueKeysWithValues: previous.frozen.map { ($0.id, $0.text) })
        let blocks = next.frozen.filter { before[$0.id] != $0.text }.reduce(0) { $0 + $1.text.utf16.count }
        return blocks + (next.tail == previous.tail ? 0 : next.tail.utf16.count)
    }

    private static func whole(_ blocks: SHFenceBlocks, separator: String = "\n") -> String {
        (blocks.frozen.map(\.text) + [blocks.tail]).joined(separator: separator)
    }

    @Test(arguments: [0, 1, 31, 32, 33, 64, 65, 200])
    func theBlocksAndTheTailAreTheFenceAndCutOnlyAtLineBreaks(lines: Int) {
        let code = Self.fence(lines: lines)
        var blocks = SHFenceBlocks()
        blocks.update(to: code)
        #expect(Self.whole(blocks) == code)
        #expect(blocks.frozen.count == max(0, lines - 1) / Self.size)
        #expect(blocks.frozen.enumerated().allSatisfy { $0.element.id == $0.offset && $0.element.text.split(separator: "\n", omittingEmptySubsequences: false).count == Self.size })
        #expect(blocks.tail.split(separator: "\n", omittingEmptySubsequences: false).count <= Self.size)
    }

    @Test func aFenceGrownByChunksHoldsWhatAWholeCutHolds() {
        let code = Self.fence(lines: 400) + "\n"
        let grown = SHFenceBlocks.Cache()
        for (index, step) in Self.steps(of: code, chunk: 37).enumerated() {
            let blocks = grown.blocks(for: step)
            var fresh = SHFenceBlocks()
            fresh.update(to: step)
            #expect(blocks.frozen == fresh.frozen && blocks.tail == fresh.tail, "step \(index)")
        }
    }

    @Test func aBlockIsTheSameTextFromTheStepItIsCutOn() {
        let cache = SHFenceBlocks.Cache()
        var cut: [Int: String] = [:]
        for step in Self.steps(of: Self.fence(lines: 400), chunk: 23) {
            for block in cache.blocks(for: step).frozen {
                #expect(cut[block.id, default: block.text] == block.text, "block \(block.id)")
                cut[block.id] = block.text
            }
        }
        #expect(cut.count == 399 / Self.size)
    }

    /// A reply is written forward, so the cost of a chunk is the same early in a fence and late in it.
    @Test func aChunkLaysOutTheTailAndNotTheFence() {
        let code = Self.fence(lines: 1_100)
        #expect(code.utf8.count > 34_000)
        let longest = code.split(separator: "\n", omittingEmptySubsequences: false).map(\.utf16.count).max() ?? 0
        let steps = Self.steps(of: code, chunk: 40)
        var blocks = SHFenceBlocks(), costs: [Int] = []
        for step in steps {
            let before = blocks
            blocks.update(to: step)
            costs.append(Self.laidOut(blocks, after: before))
        }
        // A chunk lays out a new block cut from the tail, and the tail it leaves: never more than two blocks of lines.
        let bound = 2 * Self.size * (longest + 1)
        #expect(costs.max() ?? .max <= bound, "most laid out by a chunk: \(costs.max() ?? 0), bound \(bound)")
        let early = costs[50..<100].max() ?? .max, late = costs.suffix(50).max() ?? 0
        #expect(late <= 2 * early, "\(late) units late in the fence, \(early) early")
        // One Text for the fence lays the whole fence out for each chunk.
        let whole = steps.reduce(0) { $0 + $1.utf16.count }
        #expect(costs.reduce(0, +) * 10 < whole, "\(costs.reduce(0, +)) units laid out, against \(whole)")
    }

    @Test func aFenceThatIsNotAGrowthOfTheBlocksCutStartsOver() {
        let code = Self.fence(lines: 100)
        var blocks = SHFenceBlocks()
        blocks.update(to: code)
        let edited = "// edited\n" + code
        blocks.update(to: edited)
        #expect(Self.whole(blocks) == edited)
        #expect(blocks.frozen.first?.text.hasPrefix("// edited") == true)

        blocks.update(to: "let a = 1")
        #expect(blocks.frozen.isEmpty && blocks.tail == "let a = 1")

        blocks.update(to: code)
        blocks.update(to: String(code.prefix(code.count / 2)))
        #expect(Self.whole(blocks) == String(code.prefix(code.count / 2)))
    }

    @Test func aFenceKeepsItsBlocksWhenTheLastLineChangesWithoutAnythingBeforeIt() {
        var blocks = SHFenceBlocks()
        blocks.update(to: Self.fence(lines: 70) + "x")
        let held = blocks.frozen
        blocks.update(to: Self.fence(lines: 70) + "y")
        #expect(blocks.frozen == held)
        #expect(blocks.tail.hasSuffix("y"))
    }

    @Test func aLineBreakEndingAFenceLeavesAnEmptyLastLine() {
        var blocks = SHFenceBlocks()
        blocks.update(to: (0..<Self.size).map { "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(blocks.frozen.count == 1 && blocks.tail.isEmpty)
        blocks.update(to: (0..<Self.size).map { "line \($0)" }.joined(separator: "\n"))
        #expect(blocks.frozen.isEmpty && blocks.tail.hasPrefix("line 0"), "the block is cut only once a line follows it")
    }

    @Test func aBreakOfReturnAndLineFeedIsNotSplitBetweenBlocks() {
        let code = (0..<(2 * Self.size + 5)).map { "line \($0)" }.joined(separator: "\r\n")
        var blocks = SHFenceBlocks()
        blocks.update(to: code)
        #expect(blocks.frozen.count == 2)
        #expect(blocks.frozen.allSatisfy { !$0.text.hasSuffix("\r") && !$0.text.hasSuffix("\n") })
        #expect(Self.whole(blocks, separator: "\r\n") == code)
    }

    @Test(arguments: [
        "let sheep = \"🐑\"\n", "naïve café — flock\n", "שלום\tworld\n", "e\u{301}\u{301} combining\n", "\u{2028}break\n", "日本語のコード\n",
    ])
    func textOfAnyScriptIsCutAtLineBreaksOnly(line: String) {
        let code = String(repeating: line, count: 3 * Self.size + 2) + "end"
        let cache = SHFenceBlocks.Cache()
        var last = SHFenceBlocks()
        for step in Self.steps(of: code, chunk: 5) { last = cache.blocks(for: step) }
        #expect(Self.whole(last) == code)
        var fresh = SHFenceBlocks()
        fresh.update(to: code)
        #expect(last.frozen == fresh.frozen && last.tail == fresh.tail)
    }

    @Test func aBlockSizeThatNeverFillsLaysOutTheWholeFenceForEachChunk() {
        var blocks = SHFenceBlocks(linesPerBlock: .max)
        let steps = Self.steps(of: Self.fence(lines: 200), chunk: 40)
        var cost = 0
        for step in steps {
            let before = blocks
            blocks.update(to: step)
            cost = Self.laidOut(blocks, after: before)
        }
        #expect(blocks.frozen.isEmpty && cost == steps.last?.utf16.count)
    }
}
