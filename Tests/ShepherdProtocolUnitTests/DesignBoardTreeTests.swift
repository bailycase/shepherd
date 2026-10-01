import Foundation
import Testing
@testable import ShepherdProtocol

/// A board's tags read for the write report: where they stop balancing, where each element ends,
/// the text between them, and the imports.
@Suite("Design board tree")
struct DesignBoardTreeTests {
    /// A whole board around `template`.
    static func board(_ template: String, preview: (width: Int, height: Int)? = (400, 300)) -> String {
        let props = preview.map { #"data-props='{"$preview":{"width":\#($0.width),"height":\#($0.height)}}'"# } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Board</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        \(template)
        </x-dc>
        <script type="text/x-dc" data-dc-script \(props)>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    static func tree(_ template: String) throws -> DesignBoardTree {
        try #require(DesignBoardTree(source: board(template)))
    }

    static let root = #"<div style="width: 400px; height: 300px">"#

    @Test func aBalancedBoardHasNoImbalance() throws {
        let tree = try Self.tree("""
        <helmet><style>body { margin: 0 }</style></helmet>
        \(Self.root)
        <header><h1>Checkout</h1></header>
        <ul><li>One<li>Two</ul>
        <p>Pay now<br><img src="a.png" alt="">
        <svg viewBox="0 0 8 8"><path d="M0 0" /><g><circle r="2"></circle></g></svg>
        <button type="button">Go</button>
        </div>
        """)
        #expect(tree.imbalance == nil)
    }

    @Test func aDroppedEndTagIsFoundWhereTheNextEndTagArrives() throws {
        let tree = try Self.tree("""
        \(Self.root)
        <section>
        <span>Total
        </section>
        </div>
        """)
        let imbalance = try #require(tree.imbalance)
        #expect(imbalance.kind == .unclosed && imbalance.tag == "span")
        #expect(imbalance.reached == "section")
        #expect(imbalance.description.contains("<span>") && imbalance.description.contains("</section>"))
    }

    @Test func theLinesOfAnImbalanceAreTheBoardsOwn() throws {
        let source = Self.board("""
        \(Self.root)
        <span>One
        </div>
        """)
        let tree = try #require(DesignBoardTree(source: source))
        let lines = source.components(separatedBy: "\n")
        let span = try #require(lines.firstIndex { $0.contains("<span>") }).advanced(by: 1)
        let div = try #require(lines.lastIndex { $0 == "</div>" }).advanced(by: 1)
        let imbalance = try #require(tree.imbalance)
        #expect(imbalance.line == span && imbalance.reachedLine == div)
    }

    @Test func anElementLeftOpenAtTheEndOfTheTemplateIsReported() throws {
        let tree = try Self.tree("""
        \(Self.root)
        <main>
        <p>Hi</p>
        </div>
        """)
        let imbalance = try #require(tree.imbalance)
        #expect(imbalance.kind == .unclosed && imbalance.tag == "main" && imbalance.reached == "div")
        let open = try Self.tree("<div><section>x</section>")
        let atEnd = try #require(open.imbalance)
        #expect(atEnd.kind == .unclosedAtEnd && atEnd.tag == "div")
    }

    @Test func anEndTagThatClosesNothingIsStray() throws {
        let tree = try Self.tree("\(Self.root)<p>Hi</p></span></div>")
        let imbalance = try #require(tree.imbalance)
        #expect(imbalance.kind == .stray && imbalance.tag == "span")
        #expect(imbalance.description.contains("</span>") && imbalance.description.contains("closes nothing"))
    }

    @Test func aSelfClosedHTMLElementStaysOpenSoItIsReported() throws {
        let tree = try Self.tree("""
        \(Self.root)
        <dc-import name="Card" hint-size="100px,20px" />
        </div>
        """)
        let imbalance = try #require(tree.imbalance)
        #expect(imbalance.kind == .selfClosed && imbalance.tag == "dc-import")
    }

    @Test func voidElementsSvgShapesAndImpliedEndTagsNeverCount() throws {
        let tree = try Self.tree("""
        \(Self.root)
        <table><tr><td>a<td>b<tr><td>c</table>
        <select><option>one<option>two</select>
        <dl><dt>t<dd>d<dt>u<dd>e</dl>
        <input type="text"><hr><meta name="x">
        <svg><rect width="1" height="1"/><use href="#a"/></svg>
        </div>
        """)
        #expect(tree.imbalance == nil)
    }

    @Test func textInsideStyleAndScriptBlocksIsNotMarkup() throws {
        let tree = try Self.tree("""
        <helmet><style>.a > .b { color: red } a<b { }</style></helmet>
        \(Self.root)<p>1 < 2 and 3 > 2</p></div>
        """)
        #expect(tree.imbalance == nil)
    }

    @Test func aRootCountOfOneIsAboutTheElementsBesidesHelmet() throws {
        #expect(try Self.tree("<helmet><style>a{}</style></helmet>\(Self.root)</div>").roots.count == 1)
        #expect(try Self.tree("\(Self.root)</div><div></div>").roots.count == 2)
        #expect(try Self.tree("<helmet></helmet>").roots.isEmpty)
    }

    @Test func anElementsRangeRunsFromItsStartTagToTheEndOfItsEndTag() throws {
        let source = Self.board("""
        \(Self.root)
        <section data-el="Steps"><h2>Steps</h2><p>One<p>Two</section>
        <hr>
        </div>
        """)
        let tree = try #require(DesignBoardTree(source: source))
        let section = try #require(tree.elements.first { $0.name == "section" })
        #expect(tree.markup(of: section.tid) == #"<section data-el="Steps"><h2>Steps</h2><p>One<p>Two</section>"#)
        let hr = try #require(tree.elements.first { $0.name == "hr" })
        #expect(tree.markup(of: hr.tid) == "<hr>")
        let first = try #require(tree.elements.first { $0.name == "p" })
        #expect(tree.markup(of: first.tid) == "<p>One", "an element HTML ends by implication ends where the next begins")
        #expect(tree.markup(of: 0)?.hasSuffix("</div>") == true)
    }

    @Test func attributesAreReadAsWritten() throws {
        let tree = try Self.tree(#"<div style="width: 400px; height: 300px" aria-label="Top bar" data-el='Top "bar"' hidden></div>"#)
        let element = try #require(tree.elements.first)
        #expect(tree.attribute("aria-label", of: element.tid) == "Top bar")
        #expect(tree.attribute("data-el", of: element.tid) == #"Top "bar""#)
        #expect(tree.attribute("hidden", of: element.tid) == "")
        #expect(tree.attribute("missing", of: element.tid) == nil)
    }

    @Test func theTextsAreTheTemplatesWordsWithTheElementTheyAreIn() throws {
        let tree = try Self.tree("""
        <helmet><style>body { margin: 0 }</style></helmet>
        \(Self.root)<h1>Checkout funnel</h1><p>Drop-off is {{ share }}</p><span> </span></div>
        """)
        let words = tree.texts.map { String(decoding: tree.bytes[$0.range], as: UTF8.self) }
        #expect(words == ["Checkout funnel", "Drop-off is {{ share }}"])
        let owners = tree.texts.compactMap { $0.element.map { tree.template.elements[$0].name } }
        #expect(owners == ["h1", "p"])
    }
}
