import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Code colors")
struct CodeColorsTests {
    private typealias Span = SHCodeColors.Span

    private func span(_ range: Range<Int>, _ color: Color) -> Span { Span(range: range, color: color) }

    @Test func recoloringFromALocationKeepsEarlierColorsAndReplacesTheRest() {
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [span(0..<3, .red), span(5..<9, .green), span(12..<15, .blue)])

        colors.recolor(from: 9, with: [span(10..<11, .orange)])

        #expect(colors.spans == [span(0..<3, .red), span(5..<9, .green), span(10..<11, .orange)])
        #expect(colors.revision == 2 && colors.changedFrom == 9)
    }

    /// A color that began before the location and runs past it keeps only the part before.
    @Test func aColorThatCrossesTheLocationIsCutThere() {
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [span(2..<20, .red), span(25..<30, .green)])

        colors.recolor(from: 10, with: [span(10..<14, .blue)])

        #expect(colors.spans == [span(2..<10, .red), span(10..<14, .blue)])
    }

    @Test func recoloringFromTheEndOnlyAppends() {
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [span(0..<4, .red)])
        colors.recolor(from: 4, with: [span(6..<8, .green)])
        #expect(colors.spans == [span(0..<4, .red), span(6..<8, .green)])
        colors.recolor(from: 8, with: [])
        #expect(colors.spans.count == 2 && colors.revision == 3)
    }

    @Test func theSpansFromALocationAreThoseThatReachPastIt() {
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [span(0..<4, .red), span(6..<10, .green), span(12..<14, .blue)])
        #expect(colors.spans(from: 0).count == 3)
        #expect(colors.spans(from: 4).map(\.range) == [6..<10, 12..<14])
        #expect(colors.spans(from: 9).map(\.range) == [6..<10, 12..<14])
        #expect(colors.spans(from: 10).map(\.range) == [12..<14])
        #expect(colors.spans(from: 14).isEmpty)
    }

    /// Two colors are the same while they come from one fence at one revision, however long they are.
    @Test func colorsAreComparedByTheirFenceAndRevision() {
        var colors = SHCodeColors()
        colors.recolor(from: 0, with: [span(0..<4, .red)])
        let before = colors
        #expect(colors == before)
        colors.recolor(from: 4, with: [])
        #expect(colors != before)
        var other = SHCodeColors()
        other.recolor(from: 0, with: [span(0..<4, .red)])
        #expect(other != before, "another fence at the same revision")
    }
}
