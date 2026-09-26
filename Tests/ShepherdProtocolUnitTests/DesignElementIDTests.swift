import Foundation
import Testing
import ShepherdProtocol

/// Element ids (`File.dc.html#tid:path`) and the numbering behind them.
@Suite("Design element ids")
struct DesignElementIDTests {
    static let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Designs")

    static func board(_ name: String) throws -> String {
        try String(contentsOf: designs.appendingPathComponent("boards/\(name)"), encoding: .utf8)
    }

    static func listing(_ template: DesignTemplate) -> [String] {
        template.elements.map { "\($0.tid):" + $0.path.map(String.init).joined(separator: "/") + " \($0.name)" }
    }

    // MARK: Parsing

    @Test(arguments: [
        ("Main.dc.html#5:1/1/0", "Main.dc.html", 5, [1, 1, 0], nil as Int?),
        ("Main.dc.html#0:0", "Main.dc.html", 0, [0], nil),
        ("flows%2FCart.dc.html#12:3/0@2", "flows%2FCart.dc.html", 12, [3, 0], 2),
        ("Coffee%20%26%20Deck.dc.html#9999:99/99/99/99/99/99/99/99/99", "Coffee%20%26%20Deck.dc.html", 9999,
         [99, 99, 99, 99, 99, 99, 99, 99, 99], nil),
    ])
    func anIDInsideTheGrammarParsesAndPrintsBack(_ raw: String, _ board: String, _ tid: Int, _ path: [Int], _ instance: Int?) throws {
        let id = try #require(DesignElementID(raw))
        #expect(id.board == board && id.tid == tid && id.path == path && id.instance == instance)
        #expect(id.description == raw)
    }

    @Test(arguments: [
        "Main.dc.html", "Main.dc.html#", "Main.dc.html#5", "Main.dc.html#5:", "Main.dc.html#5:1/", "Main.html#5:1",
        "Main.dc.html#10000:1", "Main.dc.html#5:100", "Main.dc.html#5:1/2/3/4/5/6/7/8/9/10", "Main.dc.html#-1:0",
        "Main.dc.html#5:1@1000", "Coffee & Deck.dc.html#1:0", "a/b.dc.html#1:0", "%2f.dc.html#1:0", ".dc.html#1:0",
        "Main.dc.html#5:1 ", "Main.dc.html#5:a",
    ])
    func anIDOutsideTheGrammarIsRefused(_ raw: String) {
        #expect(DesignElementID(raw) == nil)
    }

    @Test func anIDRoundTripsAsAString() throws {
        let id = try #require(DesignElementID("Main.dc.html#5:1/1/0"))
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["Main.dc.html#5:1\/1\/0"]"#)
        #expect(try JSONDecoder().decode([DesignElementID].self, from: data) == [id])
    }

    @Test(arguments: [("Main", "Main"), ("Coffee & Deck", "Coffee%20%26%20Deck"), ("flows/Cart", "flows%2FCart"),
                      ("a-b_c.d!~*'()", "a-b_c.d!~*'()"), ("Café", "Caf%C3%A9")])
    func aBoardNameEncodesLikeEncodeURIComponent(_ raw: String, _ encoded: String) {
        #expect(DesignElementID.encodeComponent(raw) == encoded)
    }

    // MARK: Numbering

    /// view-state.md's worked example: helmet `0:0`, its style `1:0/0`, the div `2:1`, the h1
    /// `3:1/0`, the sc-for `4:1/1` and the div inside it `5:1/1/0`.
    @Test func theFormatsMinimalBoardNumbersAsDocumented() throws {
        let template = try #require(DesignTemplate(board: Self.board("Minimal.dc.html")))
        #expect(Self.listing(template) == ["0:0 helmet", "1:0/0 style", "2:1 div", "3:1/0 h1", "4:1/1 sc-for", "5:1/1/0 div"])
    }

    /// `Tests/Designs/element-ids.json` holds WebKit's own numbering of each fixture board, real
    /// boards from Shepherd's canvas among them. The board runtime is checked against it too.
    @Test func everyFixtureBoardNumbersAsTheGoldenFileSays() throws {
        let data = try Data(contentsOf: Self.designs.appendingPathComponent("element-ids.json"))
        let golden = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["boards"] as? [String: [String]])
        #expect(golden.count == 5)
        for (name, expected) in golden.sorted(by: { $0.key < $1.key }) {
            let template = try #require(DesignTemplate(board: Self.board(name)), "\(name) has a template")
            #expect(Self.listing(template) == expected, "\(name)")
        }
    }

    @Test(arguments: [
        // Raw text, comments, and stray end tags make no elements.
        ("<textarea><b>x</b></textarea><!-- <i> --><style>a<b{}</style></span><p>", ["0:0 textarea", "1:1 style", "2:2 p"]),
        // A block closes an open paragraph; a list item closes the one before.
        ("<p>a<div>b</div><ul><li>1<li>2</ul>", ["0:0 p", "1:1 div", "2:2 ul", "3:2/0 li", "4:2/1 li"]),
        // A table implies its tbody and a cell its row.
        ("<table><td>x</table>", ["0:0 table", "1:0/0 tbody", "2:0/0/0 tr", "3:0/0/0/0 td"]),
        // `/>` closes in SVG, not in HTML.
        ("<svg><path/><g/></svg><div/><span></span>", ["0:0 svg", "1:0/0 path", "2:0/1 g", "3:1 div", "4:1/0 span"]),
        // Void elements take no children.
        ("<img src=x><br><input>", ["0:0 img", "1:1 br", "2:2 input"]),
    ])
    func htmlsImpliedStructureIsNumbered(_ fragment: String, _ expected: [String]) throws {
        let template = try #require(DesignTemplate(board: "<x-dc>\(fragment)</x-dc>"))
        #expect(Self.listing(template) == expected)
    }

    @Test func theTemplateEndsAtTheLastCloseTag() throws {
        let template = try #require(DesignTemplate(board: #"<x-dc><div>"</x-dc>"</div><b></b></x-dc><script></script>"#))
        #expect(Self.listing(template) == ["0:0 div", "1:1 b"])
        #expect(DesignTemplate(board: "<html><body><div></div></body></html>") == nil)
    }

    @Test func anIDResolvesOnlyWhenItsTidAndPathAgree() throws {
        let template = try #require(DesignTemplate(board: Self.board("Minimal.dc.html")))
        let id = try #require(DesignElementID("Minimal.dc.html#5:1/1/0"))
        let element = try #require(template.element(for: id))
        #expect(element.name == "div" && element.parent == 4)
        #expect(template.element(for: try #require(DesignElementID("Minimal.dc.html#5:1/0"))) == nil)
        #expect(template.element(for: try #require(DesignElementID("Minimal.dc.html#99:1"))) == nil)
    }

    @Test func anElementBeyondTheGrammarHasNoID() throws {
        let deep = String(repeating: "<div>", count: 10)
        let template = try #require(DesignTemplate(board: "<x-dc>\(deep)</x-dc>"))
        let board = try #require(DesignPath("Deep.dc.html"))
        let ids = template.elements.map { DesignElementID(board: board, element: $0)?.description }
        #expect(ids[8] == "Deep.dc.html#8:0/0/0/0/0/0/0/0/0")
        #expect(ids[9] == nil, "ten levels is past the grammar")
    }
}
