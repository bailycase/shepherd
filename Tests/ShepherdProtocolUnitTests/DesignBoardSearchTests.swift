import Foundation
import Testing
import ShepherdTestKit
@testable import ShepherdProtocol

/// `board_search`: text and regular expressions over a board's markup, words and labels, structure
/// over its template tree, and the usages of a piece.
@Suite("Design board search")
struct DesignBoardSearchTests {
    static let a = DesignPath("A.dc.html")!
    static let b = DesignPath("B.dc.html")!
    static let card = DesignPath("Card.dc.html")!

    /// A board with a top bar written as a `<div>`, not a `<header>`, a labelled close button, a
    /// repeated chip and an import of Card.
    static let boardA = DesignBoardTreeTests.board("""
    <helmet><style>.chip { color: red }</style></helmet>
    <main style="width: 400px; height: 300px" data-el="Page">
    <div class="topbar" data-el="Top bar" style="display: flex">
    <h1>Checkout funnel</h1>
    <button type="button" aria-label="Close">x</button>
    </div>
    <section data-el="Steps">
    <span class="chip">Cart</span><span class="chip primary">Pay now</span>
    <dc-import name="Card" item="{{ it }}"></dc-import>
    </section>
    </main>
    """)
    static let boardB = DesignBoardTreeTests.board("""
    <div style="width: 400px; height: 300px">
    <header aria-label="Top"><p>Pay now to continue</p></header>
    <dc-import name="Card"></dc-import><dc-import name="Card"></dc-import><dc-import name="Missing"></dc-import>
    </div>
    """)
    static let boardCard = DesignBoardTreeTests.board(#"<article style="width: 400px; height: 300px"><p>Card</p></article>"#)

    static let boards: [(path: DesignPath, source: String)] = [(a, boardA), (b, boardB), (card, boardCard)]
    static let known: Set<DesignPath> = [a, b, card]

    static func run(_ query: DesignSearchQuery) throws -> DesignSearchResult {
        try DesignBoardSearch.run(query, boards: boards, known: known)
    }

    // MARK: Text

    @Test func textInMarkupFindsTheBoardsLinesAndTheElementsTheyAreIn() throws {
        let result = try Self.run(DesignSearchQuery(text: "Pay now"))
        #expect(result.boards.map(\.path) == ["A.dc.html", "B.dc.html"])
        #expect(result.totalMatches == 2 && result.totalBoards == 2 && result.searched == 3)
        let first = try #require(result.boards.first?.matches.first)
        #expect(first.snippet.contains("Pay now") && first.tag == "span" && first.line != nil)
        #expect(first.ancestors == ["main[data-el=Page]", "section[data-el=Steps]"])
        #expect(first.element?.hasPrefix("A.dc.html#") == true)
    }

    @Test func aRegularExpressionMatchesInTheTextBetweenTheTags() throws {
        let result = try Self.run(DesignSearchQuery(text: #"^Pay\b.*"#, regex: true, scope: .text))
        #expect(result.totalMatches == 2)
        #expect(result.boards.map(\.path) == ["A.dc.html", "B.dc.html"])
        let b = try #require(result.boards.last?.matches.first)
        #expect(b.tag == "p" && b.snippet.contains("Pay now to continue"))
    }

    @Test func visibleTextIsNotMarkup() throws {
        // `chip` is a class in the markup, never words on the page.
        #expect(try Self.run(DesignSearchQuery(text: "chip", scope: .text)).totalMatches == 0)
        #expect(try Self.run(DesignSearchQuery(text: "chip", scope: .markup)).totalMatches >= 3)
    }

    @Test func labelsAreWhatTheMarkupNamesElements() throws {
        let result = try Self.run(DesignSearchQuery(text: "top", scope: .labels, ignoreCase: true))
        #expect(result.boards.map(\.path) == ["A.dc.html", "B.dc.html"])
        #expect(result.boards[0].matches.first?.snippet == #"data-el="Top bar""#)
        #expect(result.boards[1].matches.first?.snippet == #"aria-label="Top""#)
        #expect(try Self.run(DesignSearchQuery(text: "Card", scope: .labels)).boards.map(\.path) == ["A.dc.html", "B.dc.html"],
                "an import's name is a label")
    }

    @Test func caseMattersUnlessAsked() throws {
        #expect(try Self.run(DesignSearchQuery(text: "pay now")).totalMatches == 0)
        #expect(try Self.run(DesignSearchQuery(text: "pay now", ignoreCase: true)).totalMatches == 2)
    }

    // MARK: Structure

    @Test func aTopBarWrittenAsADivIsFoundByItsClassNotOnlyAsAHeader() throws {
        let result = try Self.run(DesignSearchQuery(elementClass: "topbar"))
        let match = try #require(result.boards.first?.matches.first)
        #expect(result.boards.map(\.path) == ["A.dc.html"] && match.tag == "div")
        #expect(match.snippet.contains(#"class="topbar""#))
        #expect(match.ancestors == ["main[data-el=Page]"])
        let id = try #require(match.element.flatMap(DesignElementID.init))
        #expect(id.board == "A.dc.html")
        let tree = try #require(DesignBoardTree(source: Self.boardA))
        #expect(tree.template.element(for: id)?.name == "div", "the id resolves to the element it names")
    }

    @Test func aTagAndAnAttributeNarrowEachOther() throws {
        #expect(try Self.run(DesignSearchQuery(tag: "button")).totalMatches == 1)
        #expect(try Self.run(DesignSearchQuery(tag: "div", attribute: "data-el")).totalMatches == 1)
        #expect(try Self.run(DesignSearchQuery(attribute: "aria-label", value: "Close")).boards.map(\.path) == ["A.dc.html"])
        #expect(try Self.run(DesignSearchQuery(attribute: "aria-label", value: "close")).totalMatches == 0)
        #expect(try Self.run(DesignSearchQuery(regex: true, attribute: "aria-label", value: "^C")).totalMatches == 1)
        #expect(try Self.run(DesignSearchQuery(tag: "header", attribute: "aria-label")).boards.map(\.path) == ["B.dc.html"])
    }

    @Test func aClassIsOneOfTheClassesAnElementHas() throws {
        let result = try Self.run(DesignSearchQuery(elementClass: "primary"))
        #expect(result.totalMatches == 1 && result.boards.first?.matches.first?.snippet.contains("Pay now") == true)
        #expect(try Self.run(DesignSearchQuery(tag: "span", elementClass: "chip")).totalMatches == 2)
    }

    @Test func aStructuralQueryTakesTheElementsWordsToo() throws {
        #expect(try Self.run(DesignSearchQuery(text: "Cart", tag: "span")).totalMatches == 1)
    }

    // MARK: Usages

    @Test func usagesAreTheBoardsThatImportAPieceWithTheirElements() throws {
        let result = try Self.run(DesignSearchQuery(usages: "Card"))
        #expect(result.piece == "Card.dc.html" && result.pieceExists == true)
        #expect(result.boards.map(\.path) == ["A.dc.html", "B.dc.html"])
        #expect(result.boards.map(\.count) == [1, 2])
        #expect(result.boards[0].matches[0].tag == "dc-import" && result.boards[0].matches[0].snippet.contains(#"name="Card""#))
        #expect(try Self.run(DesignSearchQuery(usages: "Card.dc.html")).totalMatches == 3)
    }

    @Test func aPieceNoBoardHasStillSaysSo() throws {
        let result = try Self.run(DesignSearchQuery(usages: "Missing"))
        #expect(result.piece == "Missing.dc.html" && result.pieceExists == false)
        #expect(result.boards.map(\.path) == ["B.dc.html"], "it is imported all the same")
    }

    // MARK: Bounds

    @Test func resultsAreBoundedPerBoardAndInBoardsWithATail() throws {
        let many = (1...12).map { "<p>needle \($0)</p>" }.joined(separator: "\n")
        let big = DesignBoardTreeTests.board(many)
        let boards = (1...30).map { (path: DesignPath("B\($0).dc.html")!, source: big) }
        let result = try DesignBoardSearch.run(DesignSearchQuery(text: "needle", limit: 3), boards: boards, known: [])
        #expect(result.boards.count == 3 && result.omittedBoards == 27 && result.totalBoards == 30)
        #expect(result.totalMatches == 360)
        #expect(result.boards.allSatisfy { $0.count == 12 && $0.matches.count == DesignBoardSearch.perBoard })
        #expect(try DesignBoardSearch.run(DesignSearchQuery(text: "needle"), boards: boards, known: []).boards.count == DesignBoardSearch.defaultLimit)
    }

    @Test func aSearchThatRunsOutOfTimeSaysSoAndKeepsWhatItFound() throws {
        let clock = Locked(Date(timeIntervalSince1970: 0))
        let result = try DesignBoardSearch.run(DesignSearchQuery(text: "Card"), boards: Self.boards, known: Self.known, now: {
            clock.withValue { $0 = $0.addingTimeInterval(DesignBoardSearch.budget / 2 + 1) }
            return clock.current
        })
        #expect(result.timedOut && result.searched < 3)
    }

    // MARK: Refusals

    @Test func aQueryNeedsSomethingToLookFor() {
        #expect(throws: DesignBoardSearch.Failure.empty) { try Self.run(DesignSearchQuery()) }
        #expect(throws: DesignBoardSearch.Failure.empty) { try Self.run(DesignSearchQuery(text: "")) }
    }

    @Test func aRegularExpressionThatIsNotOneIsRefusedWithWhy() {
        do {
            _ = try Self.run(DesignSearchQuery(text: "(unclosed", regex: true))
            Issue.record("the pattern was accepted")
        } catch let failure as DesignBoardSearch.Failure {
            #expect(failure.code == "invalid_search" && failure.description.contains("regular expression"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aPieceNameThatIsNoBoardIsRefused() {
        #expect(throws: DesignBoardSearch.Failure.badPiece("../x")) { try Self.run(DesignSearchQuery(usages: "../x")) }
    }

    @Test func aBoardWithoutATemplateMatchesOnlyItsRawText() throws {
        let boards = [(path: Self.a, source: "<html>no template here: needle</html>")]
        let result = try DesignBoardSearch.run(DesignSearchQuery(text: "needle"), boards: boards, known: [Self.a])
        #expect(result.totalMatches == 1 && result.boards.first?.matches.first?.element == nil)
        #expect(try DesignBoardSearch.run(DesignSearchQuery(tag: "div"), boards: boards, known: [Self.a]).totalMatches == 0)
    }

    @Test func theQueryRoundTripsAndDefaultsWhenKeysAreMissing() throws {
        let query = DesignSearchQuery(text: "x", regex: true, scope: .text, ignoreCase: true, tag: "div", attribute: "a", value: "v",
                                      elementClass: "c", usages: "Card", paths: ["A.dc.html"], limit: 7)
        #expect(try JSONDecoder().decode(DesignSearchQuery.self, from: JSONEncoder().encode(query)) == query)
        let bare = try JSONDecoder().decode(DesignSearchQuery.self, from: Data(#"{"text":"x"}"#.utf8))
        #expect(bare == DesignSearchQuery(text: "x"))
    }
}
