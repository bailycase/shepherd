import Foundation
import Testing
@testable import ShepherdProtocol

/// What a write tells the design agent about the board it left: the diff, the tags, the root, the
/// size, the imports and the off-system values.
@Suite("Design board report")
struct DesignBoardReportTests {
    static let a = DesignPath("A.dc.html")!
    static let card = DesignPath("Card.dc.html")!
    static let frame = DesignIndex.Board(x: 0, y: 0, w: 400, h: 300, title: "A")

    static func board(_ body: String = "<p>Hi</p>", preview: (width: Int, height: Int)? = (400, 300),
                      root: String = #"<div style="width: 400px; height: 300px">"#) -> String {
        DesignBoardTreeTests.board("\(root)\n\(body)\n</div>", preview: preview)
    }

    static func report(old: String? = nil, new: String, frame: DesignIndex.Board? = frame, boards: Set<DesignPath> = [a]) -> DesignBoardReport {
        DesignBoardReporter.report(path: a, old: old, new: new, frame: frame, boards: boards, tokens: nil, enforcement: nil)
    }

    // MARK: Diff

    @Test func aDiffListsTheChangedLinesInOrderWithTheirLineNumbers() {
        let diff = DesignTextDiff.between("a\nb\nc\nd", "a\nB\nc\nd\ne")
        #expect(diff.added == 2 && diff.removed == 1)
        #expect(diff.lines == ["-2 b", "+2 B", "+5 e"] && diff.more == 0)
    }

    @Test func aDiffShowsAFewLinesAndCountsTheRest() {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let new = (1...30).map { "LINE \($0)" }.joined(separator: "\n")
        let diff = DesignTextDiff.between(old, new, shown: 4, width: 12)
        #expect(diff.lines.count == 4 && diff.more == 56 && diff.added == 30 && diff.removed == 30)
        #expect(diff.lines.allSatisfy { $0.count <= 12 + 4 })
    }

    @Test func aDiffOfCrlfBoardsStillSplitsIntoLines() {
        let diff = DesignTextDiff.between("a\r\nb\r\nc", "a\r\nB\r\nc")
        #expect(diff.lines == ["-2 b", "+2 B"])
    }

    @Test func changedLinesNameTheLinesLostAndGained() {
        let changed = DesignTextDiff.changedLines(old: "a\nb\nc", new: "a\nx\ny\nc")
        #expect(changed.removed == [2] && changed.inserted == [2, 3])
    }

    // MARK: The report

    @Test func aNewBoardReportsItsSizeAndNoDiff() {
        let report = Self.report(new: Self.board())
        #expect(report.created && report.delta == nil && report.diff == nil)
        #expect(report.bytes == Self.board().utf8.count)
        #expect(report.roots == 1 && report.imbalance == nil && report.missingImports.isEmpty)
        #expect(report.root == .init(width: 400, height: 300) && report.preview == report.root && report.frame == report.root)
        #expect(!report.hasProblem)
    }

    @Test func anEditedBoardReportsTheSizeDeltaAndACompactDiff() {
        let old = Self.board("<p>Pay now</p>")
        let new = Self.board("<p>Pay now and save</p>")
        let report = Self.report(old: old, new: new)
        #expect(!report.created && report.delta == new.utf8.count - old.utf8.count && report.delta == 9)
        #expect(report.diff?.lines.count == 2)
        #expect(report.diff?.lines.first?.hasPrefix("-") == true && report.diff?.lines.last?.hasPrefix("+") == true)
    }

    @Test func aDroppedEndTagIsReportedWithItsPosition() {
        let report = Self.report(new: Self.board("<section><span>Total</section>"))
        #expect(report.imbalance?.kind == .unclosed && report.imbalance?.tag == "span")
        #expect(report.hasProblem)
    }

    @Test func aSecondRootIsReported() {
        let report = Self.report(new: DesignBoardTreeTests.board("""
        <div style="width: 400px; height: 300px"></div>
        <div style="width: 400px; height: 300px"></div>
        """))
        #expect(report.roots == 2 && report.hasProblem)
    }

    @Test func aRootThatDoesNotMatchItsFrameIsReported() {
        let report = Self.report(new: Self.board(), frame: DesignIndex.Board(x: 0, y: 0, w: 390, h: 844))
        #expect(report.root == .init(width: 400, height: 300) && report.frame == .init(width: 390, height: 844))
        #expect(report.hasProblem)
        #expect(Self.report(new: Self.board(), frame: nil).frame == nil, "a board with no frame has none to differ from")
    }

    @Test func aBoardWithNoPreviewOrFixedRootStillReports() {
        let report = Self.report(new: DesignBoardTreeTests.board("<div><p>Hi</p></div>", preview: nil))
        #expect(report.root == nil && report.preview == nil && report.roots == 1)
    }

    @Test func importsOfBoardsThatDoNotExistAreNamedOnce() {
        let new = Self.board("""
        <dc-import name="Card" hint-size="1px,1px"></dc-import><dc-import name="Card"></dc-import>
        <dc-import name="Badge"></dc-import><dc-import name="parts/Chip"></dc-import>
        <dc-import name="{{ which }}"></dc-import>
        """)
        #expect(Self.report(new: new, boards: [Self.a, Self.card]).missingImports == ["Badge", "parts/Chip"])
        #expect(Self.report(new: new, boards: [Self.a, Self.card, DesignPath("Badge.dc.html")!, DesignPath("parts/Chip.dc.html")!])
            .missingImports.isEmpty)
    }

    @Test func importsResolveBesideTheBoardThatHoldsThem() {
        let nested = DesignPath("flows/Cart.dc.html")!
        let new = Self.board("""
        <dc-import name="Card"></dc-import>
        """)
        let report = DesignBoardReporter.report(path: nested, old: nil, new: new, frame: nil,
                                                boards: [nested, Self.card], tokens: nil, enforcement: nil)
        #expect(report.missingImports == ["Card"], "Card is flows/Card.dc.html from here, not the root's")
        let found = DesignBoardReporter.report(path: nested, old: nil, new: new, frame: nil,
                                               boards: [nested, DesignPath("flows/Card.dc.html")!], tokens: nil, enforcement: nil)
        #expect(found.missingImports.isEmpty)
    }

    @Test func theOffSystemValuesAThisWriteIntroducedGoInTheReportWithTheSystemsName() {
        let tokens = DesignTokenCheckTests.tokens
        let new = Self.board(#"<p style="color: #3a56d4">Hi</p>"#)
        let enforcement = DesignTokenCheck.enforce(.warn, tokens: tokens, old: nil, new: new)
        let report = DesignBoardReporter.report(path: Self.a, old: nil, new: new, frame: Self.frame, boards: [Self.a], tokens: tokens,
                                                enforcement: enforcement)
        #expect(report.tokenSource == "acme" && report.offSystem.map(\.value) == ["#3a56d4"] && report.hasProblem)
        let none = Self.report(new: new)
        #expect(none.tokenSource == nil && none.offSystem.isEmpty, "a design with no tokens has nothing to say")
    }

    @Test func theReportRoundTripsThroughJSON() throws {
        let report = Self.report(old: Self.board("<p>a</p>"), new: Self.board("<p>b</p><dc-import name=\"X\"></dc-import>"))
        let again = try JSONDecoder().decode(DesignBoardReport.self, from: JSONEncoder().encode(report))
        #expect(again == report)
    }
}
