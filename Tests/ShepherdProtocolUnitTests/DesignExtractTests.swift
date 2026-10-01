import Foundation
import Testing
@testable import ShepherdProtocol

/// `board_extract`: an element becomes a piece, an import takes its place, and exact copies in other
/// boards follow (docs/designs.md › Shared pieces).
@Suite("Design extraction")
struct DesignExtractTests {
    static let a = DesignPath("A.dc.html")!
    static let b = DesignPath("B.dc.html")!
    static let card = DesignPath("Card.dc.html")!

    static let cardMarkup = """
    <div class="card" style="width: 320px; height: 120px" data-el="Card">
      <h2>Pay now</h2>
      <p>Secure &amp; fast</p>
    </div>
    """

    static func board(_ body: String, head: String = "") -> String {
        DesignBoardTreeTests.board("""
        <helmet><style>:root { --accent: #3056d3 }</style></helmet>
        <main style="width: 390px; height: 844px">
        <h1>Checkout</h1>
        \(body)
        </main>
        """).replacingOccurrences(of: DesignBoardCheck.supportScript, with: DesignBoardCheck.supportScript + head)
    }

    /// The element's tid on the board.
    static func tid(_ source: String, _ name: String, _ nth: Int = 0) -> Int {
        let tree = DesignBoardTree(source: source)!
        return tree.elements.filter { $0.name == name }[nth].tid
    }

    static func plan(_ request: DesignExtractRequest, _ sources: [DesignPath: String], board: DesignPath = a, piece: DesignPath = card) throws -> DesignExtraction.Plan {
        try DesignExtraction.plan(request, board: board, piece: piece, sources: sources)
    }

    static func request(_ source: String, element: String = "div", props: [DesignExtractRequest.Prop] = [], size: DesignBoardCheck.Size? = nil,
                        copies: [String] = [], allCopies: Bool = false) -> DesignExtractRequest {
        DesignExtractRequest(path: "A.dc.html", element: String(tid(source, element)), piece: "Card", props: props, size: size,
                             copies: copies, allCopies: allCopies)
    }

    static func failure(_ request: DesignExtractRequest, _ sources: [DesignPath: String]) -> String? {
        do { _ = try plan(request, sources); return nil } catch let failure as DesignExtraction.Failure { return failure.message } catch { return "\(error)" }
    }

    // MARK: The piece and the import

    @Test func anElementBecomesAPieceAndAnImportTakesItsPlace() throws {
        let source = Self.board(Self.cardMarkup)
        let plan = try Self.plan(Self.request(source), [Self.a: source])
        #expect(plan.importTag == #"<dc-import name="Card" hint-size="320px,120px"></dc-import>"#)
        let changed = try #require(plan.sources[Self.a])
        #expect(changed == source.replacingOccurrences(of: Self.cardMarkup, with: plan.importTag))
        #expect(plan.replaced.isEmpty && plan.skipped.isEmpty && plan.warnings.isEmpty)

        // The piece is a board in its own right: it passes the checks a write does, has one root of the element's size, and
        // keeps the source board's helmet so it draws alone as it does in its board.
        #expect(try DesignBoardCheck.check(plan.pieceSource).isEmpty)
        let piece = try #require(DesignBoardTree(source: plan.pieceSource))
        #expect(piece.roots.count == 1 && piece.roots[0].name == "div" && piece.imbalance == nil)
        #expect(DesignBoardCheck.previewSize(of: plan.pieceSource) == .init(width: 320, height: 120))
        #expect(plan.pieceSource.contains("<helmet><style>:root { --accent: #3056d3 }</style></helmet>"))
        #expect(plan.pieceSource.contains(Self.cardMarkup))
        #expect(plan.pieceSource.contains("<title>Card</title>"))
    }

    @Test func theSourceBoardsHeadLinesAfterSupportJsGoWithThePiece() throws {
        let link = #"<link rel="stylesheet" href="ds/acme/tokens.css">"#
        let source = Self.board(Self.cardMarkup, head: link)
        let plan = try Self.plan(Self.request(source), [Self.a: source])
        let head = try #require(plan.pieceSource.range(of: "</head>"))
        #expect(plan.pieceSource[..<head.lowerBound].contains(DesignBoardCheck.supportScript + "\n" + link))
    }

    @Test func aPropTurnsTextIntoAHoleTheImporterFills() throws {
        let source = Self.board(Self.cardMarkup)
        let props = [DesignExtractRequest.Prop(name: "label", text: "Pay now"), .init(name: "note", text: "Secure &amp; fast")]
        let plan = try Self.plan(Self.request(source, props: props), [Self.a: source])
        #expect(plan.importTag == #"<dc-import name="Card" hint-size="320px,120px" label="Pay now" note="Secure &amp; fast"></dc-import>"#)
        #expect(plan.pieceSource.contains("<h2>{{ label }}</h2>") && plan.pieceSource.contains("<p>{{ note }}</p>"))
        #expect(plan.pieceSource.contains(#"label: this.props.label ?? "Pay now","#))
        #expect(plan.pieceSource.contains(#"note: this.props.note ?? "Secure & fast","#), "the default is the text as the board reads it")
        #expect(try DesignBoardCheck.check(plan.pieceSource).isEmpty)
        #expect(plan.warnings.isEmpty, "a hole a prop fills is the piece's own")
    }

    @Test func aHoleAsAPropPassesTheBoardsValueAndDefaultsToNothing() throws {
        let source = Self.board("""
        <sc-for list="{{ steps }}" as="step"><div style="width: 320px; height: 120px"><h2>{{ step.name }}</h2><b>{{ step.share }}</b></div></sc-for>
        """)
        let props = [DesignExtractRequest.Prop(name: "stepName", text: "{{ step.name }}")]
        let plan = try Self.plan(Self.request(source, props: props), [Self.a: source])
        #expect(plan.importTag == #"<dc-import name="Card" hint-size="320px,120px" step-name="{{ step.name }}"></dc-import>"#,
                "camelCase reads as kebab-case in an attribute, and a whole hole keeps its value's type")
        #expect(plan.pieceSource.contains("<h2>{{ stepName }}</h2>") && plan.pieceSource.contains(#"stepName: this.props.stepName ?? "","#))
        #expect(plan.warnings.count == 1 && plan.warnings[0].contains("{{ step.share }}"), "the hole no prop covers is warned about")
    }

    @Test func aQuoteInAPropsTextCannotEndTheAttributeOrTheScriptString() throws {
        let source = Self.board(#"<div style="width: 320px; height: 120px"><p>Say "hi" &lt;/script&gt; now</p></div>"#)
        let text = #"Say "hi" &lt;/script&gt; now"#
        let plan = try Self.plan(Self.request(source, element: "div", props: [.init(name: "greeting", text: text)]), [Self.a: source])
        #expect(plan.importTag.contains(#"greeting="Say &quot;hi&quot; &lt;/script&gt; now""#))
        #expect(plan.pieceSource.contains(#"greeting: this.props.greeting ?? "Say \"hi\" <\/script> now","#), "the default is the decoded text, as an escaped literal")
        #expect(DesignBoardTree(source: plan.pieceSource)?.imbalance == nil)
        #expect(plan.pieceSource.components(separatedBy: "</script>").count == 3, "only the support line's and the logic script's own end tags")
    }

    @Test(arguments: [
        ("name", "Pay now", "can't be a prop name"),
        ("Label", "Pay now", "can't be a prop name"),
        ("hint", "Pay now", "can't be a prop name"),
        ("hintSize", "Pay now", "can't be a prop name"),
        ("la-bel", "Pay now", "can't be a prop name"),
        ("label", "Not there", "is not in the element"),
        ("label", "a", "times"),
        ("label", "", "1 to 500 characters"),
    ] as [(String, String, String)])
    func aBadPropIsRefusedWithWhy(_ name: String, _ text: String, _ words: String) {
        let source = Self.board(Self.cardMarkup)
        let message = Self.failure(Self.request(source, props: [.init(name: name, text: text)]), [Self.a: source])
        #expect(message?.contains(words) == true, "\(name) / \(text): \(message ?? "accepted")")
    }

    @Test func propsMayNotBeNamedTwiceOrOverlap() {
        let source = Self.board(Self.cardMarkup)
        #expect(Self.failure(Self.request(source, props: [.init(name: "a", text: "Pay now"), .init(name: "a", text: "Secure")]), [Self.a: source])?
            .contains("named twice") == true)
        let overlap = Self.board(#"<div style="width: 320px; height: 120px"><p>Pay now please</p></div>"#)
        #expect(Self.failure(Self.request(overlap, props: [.init(name: "a", text: "Pay now"), .init(name: "b", text: "now please")]), [Self.a: overlap])?
            .contains("overlap") == true)
    }

    // MARK: Size

    @Test func aPieceNeedsAFixedSizeFromItsRootOrTheRequest() throws {
        let source = Self.board(#"<div class="chip"><p>Hi</p></div>"#)
        let message = Self.failure(Self.request(source), [Self.a: source])
        #expect(message?.contains("no fixed px width and height") == true && message?.contains("pass size") == true)
        let plan = try Self.plan(Self.request(source, size: .init(width: 200, height: 48)), [Self.a: source])
        #expect(DesignBoardCheck.previewSize(of: plan.pieceSource) == .init(width: 200, height: 48))
        #expect(plan.importTag.contains(#"hint-size="200px,48px""#))
        #expect(Self.failure(Self.request(source, size: .init(width: 10, height: 10)), [Self.a: source]) != nil, "a size is 40 px and up")
    }

    @Test func aSizeThatDiffersFromTheRootsOwnIsRefused() {
        let source = Self.board(Self.cardMarkup)
        #expect(Self.failure(Self.request(source, size: .init(width: 300, height: 100)), [Self.a: source])?.contains("same size") == true)
    }

    // MARK: The element

    @Test func anElementIdIsReadInItsForms() throws {
        let source = Self.board(Self.cardMarkup)
        let tid = Self.tid(source, "div")
        let path = try #require(DesignBoardTree(source: source)).elements[tid].path.map(String.init).joined(separator: "/")
        for raw in ["\(tid)", "\(tid):\(path)", "A.dc.html#\(tid)", "A.dc.html#\(tid):\(path)", " \(tid) "] {
            var request = Self.request(source)
            request.element = raw
            #expect(Self.failure(request, [Self.a: source]) == nil, "\(raw)")
        }
    }

    @Test(arguments: ["x", "", "#", "99999", "-1", "4:a", "4:1//2"])
    func aBadElementIdIsRefused(_ raw: String) {
        let source = Self.board(Self.cardMarkup)
        var request = Self.request(source)
        request.element = raw
        #expect(Self.failure(request, [Self.a: source]) != nil)
    }

    @Test func aStalePathIsRefusedAsTheBoardHavingChanged() {
        let source = Self.board(Self.cardMarkup)
        var request = Self.request(source)
        request.element = "\(Self.tid(source, "div")):7/7"
        #expect(Self.failure(request, [Self.a: source])?.contains("the board changed; read it again") == true)
    }

    @Test func theRootAndTheHelmetCannotBeExtracted() {
        let source = Self.board(Self.cardMarkup)
        var request = Self.request(source)
        request.element = String(Self.tid(source, "main"))
        #expect(Self.failure(request, [Self.a: source])?.contains("the board's root") == true)
        request.element = String(Self.tid(source, "helmet"))
        #expect(Self.failure(request, [Self.a: source])?.contains("<helmet> is not a piece") == true)
    }

    @Test func aBoardWhoseTagsDontBalanceIsFixedFirst() {
        let source = Self.board("<div style=\"width: 320px; height: 120px\"><span>x</div>")
        let message = Self.failure(Self.request(source), [Self.a: source])
        #expect(message?.contains("tags don't balance") == true && message?.contains("<span>") == true)
    }

    // MARK: Copies

    @Test func exactCopiesInOtherBoardsBecomeImportsWhateverTheirIndentation() throws {
        let source = Self.board(Self.cardMarkup)
        let flat = #"<div class="card" style="width: 320px; height: 120px" data-el="Card"><h2>Pay now</h2><p>Secure &amp; fast</p></div>"#
        let other = Self.board("<section>\n\(flat)\n<hr>\n\(Self.cardMarkup.replacingOccurrences(of: "\n", with: "\n      "))</section>")
        let different = Self.board(Self.cardMarkup.replacingOccurrences(of: "Pay now", with: "Pay later"))
        let plan = try Self.plan(Self.request(source, copies: ["B.dc.html", "C.dc.html"]),
                                 [Self.a: source, Self.b: other, DesignPath("C.dc.html")!: different])
        #expect(plan.replaced == [Self.b: 2], "C's card says something else")
        let text = try #require(plan.sources[Self.b])
        #expect(text.components(separatedBy: plan.importTag).count == 3 && !text.contains("<h2>Pay now</h2>"))
        #expect(plan.sources[DesignPath("C.dc.html")!] == nil, "an unchanged board is not written")
    }

    @Test func copiesInTheSourceBoardItselfAreReplacedToo() throws {
        let source = Self.board(Self.cardMarkup + "\n<hr>\n" + Self.cardMarkup)
        let plan = try Self.plan(Self.request(source), [Self.a: source])
        #expect(plan.replaced == [Self.a: 1])
        #expect(plan.sources[Self.a]?.components(separatedBy: plan.importTag).count == 3)
    }

    @Test func aSpaceBetweenInlineTagsIsOnThePageSoItMakesACopyDiffer() throws {
        let one = Self.board(#"<div style="width: 320px; height: 120px"><b>a</b> <i>b</i></div>"#)
        let two = Self.board(#"<div style="width: 320px; height: 120px"><b>a</b><i>b</i></div>"#)
        let plan = try Self.plan(Self.request(one, copies: ["B.dc.html"]), [Self.a: one, Self.b: two])
        #expect(plan.replaced.isEmpty)
    }

    @Test func anImportNamesThePieceFromEachBoardsFolderAndNeverClimbsOut() throws {
        let nested = DesignPath("flows/Cart.dc.html")!
        let elsewhere = DesignPath("other/Page.dc.html")!
        let piece = DesignPath("flows/Card.dc.html")!
        let source = Self.board(Self.cardMarkup)
        let plan = try DesignExtraction.plan(DesignExtractRequest(path: "flows/Cart.dc.html", element: String(Self.tid(source, "div")), piece: "Card",
                                                                  copies: ["A.dc.html", "other/Page.dc.html"]), board: nested, piece: piece,
                                             sources: [nested: source, Self.a: source, elsewhere: source])
        #expect(plan.importTag.hasPrefix(#"<dc-import name="Card""#), "beside the board that holds it")
        #expect(plan.sources[Self.a]?.contains(#"<dc-import name="flows/Card""#) == true, "a board above imports a piece below it by its path from there")
        #expect(plan.replaced == [Self.a: 1])
        #expect(plan.sources[elsewhere] == nil)
        #expect(plan.skipped.map(\.path) == ["other/Page.dc.html"] && plan.skipped[0].why.contains("never climbs out"))
        #expect(DesignExtraction.importName(of: piece, in: Self.a) == "flows/Card")
        #expect(DesignExtraction.importName(of: piece, in: nested) == "Card")
        #expect(DesignExtraction.importName(of: Self.card, in: nested) == nil, "a root piece is above flows/")
        #expect(DesignExtraction.importName(of: Self.card, in: Self.b) == "Card")
    }

    @Test func aCopyInABoardWithUnbalancedTagsIsSkippedNotGuessedAt() throws {
        let source = Self.board(Self.cardMarkup)
        let broken = Self.board("<span>x" + Self.cardMarkup)
        let plan = try Self.plan(Self.request(source, copies: ["B.dc.html"]), [Self.a: source, Self.b: broken])
        #expect(plan.skipped.map(\.path) == ["B.dc.html"] && plan.skipped[0].why.contains("tags don't balance"))
    }

    // MARK: Names

    @Test(arguments: [
        ("Card", "A.dc.html", "Card.dc.html"), ("Card.dc.html", "A.dc.html", "Card.dc.html"), ("Card", "flows/Cart.dc.html", "flows/Card.dc.html"),
        ("flows/Card", "flows/Cart.dc.html", "flows/Card.dc.html"),
    ] as [(String, String, String)])
    func aPieceIsNamedBesideItsSourceBoard(_ raw: String, _ board: String, _ expected: String) throws {
        #expect(try DesignExtraction.piecePath(raw, beside: DesignPath(board)!).rawValue == expected)
    }

    @Test(arguments: ["", "../Card", "Car d", "other/Card", "ds/Card", "Card.html"])
    func aPieceNameThatIsNoBoardBesideTheSourceIsRefused(_ raw: String) {
        #expect(throws: DesignExtraction.Failure.self) { try DesignExtraction.piecePath(raw, beside: Self.a) }
    }

    @Test func theResultAndRequestRoundTripAndTheRequestDefaultsWhatItLeavesOut() throws {
        let request = try JSONDecoder().decode(DesignExtractRequest.self, from: Data(#"{"path":"A.dc.html","element":"4","piece":"Card"}"#.utf8))
        #expect(request == DesignExtractRequest(path: "A.dc.html", element: "4", piece: "Card"))
        #expect(!request.allCopies && request.props.isEmpty && request.copies.isEmpty && request.frame == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DesignExtractRequest.self, from: Data(#"{"path":"A.dc.html"}"#.utf8)) }
    }
}
