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
