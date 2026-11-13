import CoreGraphics
import Testing
@testable import ShepherdUI

/// How much of a composer field's text is laid out for its height (`SHComposerFit`).
@Suite("Composer fit")
struct ComposerFitTests {
    /// A text of `length` units that wraps every `unitsPerLine`, in a field that shows `ceiling` lines.
    final class FakeText {
        let length: Int
        let unitsPerLine: Int
        let ceiling = 8
        let lineHeight: CGFloat = 20
        private(set) var asked: [Int] = []

        init(length: Int, unitsPerLine: Int) {
            self.length = length
            self.unitsPerLine = unitsPerLine
        }

        func measure(_ count: Int) -> (height: CGFloat, whole: Bool, final: Bool) {
            asked.append(count)
            let held = min(count, length)
            let lines = max(1, (held + unitsPerLine - 1) / unitsPerLine)
            return (CGFloat(min(lines, ceiling)) * lineHeight, held == length, lines > ceiling)
        }
    }

    @Test func aLongTextIsDecidedByItsFirstSample() {
        let text = FakeText(length: 500_000, unitsPerLine: 40)
        let height = SHComposerFit.height(measure: text.measure)
        #expect(text.asked == [SHComposerFit.firstSample])
        #expect(height == CGFloat(text.ceiling) * text.lineHeight)
    }

    @Test func aShortTextIsMeasuredOnceWhole() {
        let text = FakeText(length: 100, unitsPerLine: 40)
        let height = SHComposerFit.height(measure: text.measure)
        #expect(text.asked == [SHComposerFit.firstSample])
        #expect(height == 3 * text.lineHeight)
    }

    @Test func textThatFitsTheFirstSampleGrowsItFourfold() {
        // 3,000 units a line: the first 2,048 and 8,192 hold fewer than nine lines, 32,768 hold ten.
        let text = FakeText(length: 500_000, unitsPerLine: 3_000)
        let height = SHComposerFit.height(measure: text.measure)
        #expect(text.asked == [2_048, 8_192, 32_768])
        #expect(height == CGFloat(text.ceiling) * text.lineHeight)
    }

    @Test func aTextNoSampleDecidesEndsWhole() {
        // Twenty thousand units on three lines: it never reaches a ninth, so the sample grows to all of it.
        let text = FakeText(length: 20_000, unitsPerLine: 8_000)
        let height = SHComposerFit.height(measure: text.measure)
        #expect(text.asked == [2_048, 8_192, 32_768])
        #expect(height == 3 * text.lineHeight)
    }
}

/// What a composer field measures again (`SHComposerFitCache`): the same text at the same width is measured once, however often layout asks.
@Suite("Composer fit cache")
struct ComposerFitCacheTests {
    /// A field that counts how often its text is laid out.
    final class Field {
        struct Key: Equatable {
            var revision = 0
            var style = "body"
        }

        var cache = SHComposerFitCache<Key, CGFloat>()
        var key = Key()
        private(set) var measured = 0

        func ask(_ width: CGFloat) -> CGFloat {
            cache.answer(width: width, key: key) {
                measured += 1
                return width / 10 + CGFloat(key.revision)
            }
        }
    }

    @Test func repeatedAsksForTheSameTextAndWidthMeasureOnce() {
        let field = Field()
        let first = field.ask(300)
        for _ in 0..<20 { #expect(field.ask(300) == first) }
        #expect(field.measured == 1)
    }

    @Test func eachEditMeasuresAgain() {
        let field = Field()
        for edit in 1...5 {
            field.key.revision = edit
            #expect(field.ask(300) == 30 + CGFloat(edit))
            _ = field.ask(300)
        }
        #expect(field.measured == 5)
    }

    @Test func aNewWidthIsMeasuredOnceAndTheOldOneIsKept() {
        let field = Field()
        _ = field.ask(300)
        _ = field.ask(400)
        for _ in 0..<5 {
            #expect(field.ask(300) == 30)
            #expect(field.ask(400) == 40)
        }
        #expect(field.measured == 2)
    }

    @Test func aNewStyleIsMeasuredAgain() {
        let field = Field()
        _ = field.ask(300)
        field.key.style = "title"
        _ = field.ask(300)
        _ = field.ask(300)
        #expect(field.measured == 2)
    }

    @Test func anEditForgetsEveryWidth() {
        let field = Field()
        _ = field.ask(300)
        _ = field.ask(400)
        field.key.revision = 1
        _ = field.ask(400)
        _ = field.ask(300)
        #expect(field.measured == 4)
    }

    @Test func moreWidthsThanItKeepsStillAnswerEveryAsk() {
        let field = Field()
        let widths = (1...(SHComposerFitCache<Field.Key, CGFloat>.widths + 3)).map { CGFloat($0) * 100 }
        for width in widths { #expect(field.ask(width) == width / 10) }
        let measured = field.measured
        #expect(measured == widths.count)
        // The latest width is still known.
        #expect(field.ask(widths.last ?? 0) == (widths.last ?? 0) / 10)
        #expect(field.measured == measured)
    }
}
