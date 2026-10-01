import CoreGraphics
import Foundation
import ShepherdProtocol
import Testing
@testable import DesignSurfaceKit

/// What a `<dc-import>` carries into a shared piece (docs/designs.md › Shared pieces): attributes
/// become the piece's props (text, numbers, lists by a whole-value hole), markup written inside the
/// import is not passed down, the piece is the same wherever it is imported, imports nest only so
/// far, and a board that imports itself draws a placeholder.
@MainActor
@Suite("Design shared pieces", .serialized)
struct DesignPieceImportTests {
    static func board(_ body: String, logic: String = "class Component extends DCLogic { renderVals() { return {}; } }",
                      size: (Int, Int) = (400, 300)) -> String {
        """
        <!doctype html><html><head><script src="./support.js"></script></head><body>
        <x-dc>
        \(body)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(size.0),"height":\(size.1)}}'>
        \(logic)
        </script>
        </body></html>
        """
    }

    /// A panel that shows a title, a text for its children, and a list.
    static let panel = board("""
        <section id="panel" style="width: 400px; height: 300px">
        <h3 id="title">{{ title }}</h3>
        <span id="kids">{{ content }}</span>
        <ul><sc-for list="{{ items }}" as="item"><li class="it">{{ item.name }}</li></sc-for></ul>
        <i id="count">{{ count }}</i>
        </section>
        """, logic: """
        class Component extends DCLogic {
          renderVals() { return { title: this.props.title, content: this.props.children, items: this.props.items ?? [], count: this.props.itemCount }; }
        }
        """)

    @Test func attributesArePropsAndAWholeValueHoleKeepsItsListAndNumber() async throws {
        let main = Self.board("""
            <div style="width: 400px; height: 300px">
            <dc-import name="Panel" title="Hello" items="{{ rows }}" item-count="{{ total }}"></dc-import>
            </div>
            """, logic: """
            class Component extends DCLogic { renderVals() { return { rows: [{ name: "One" }, { name: "Two" }], total: 2 }; } }
            """)
        let harness = try BoardHarness(files: ["Panel.dc.html": Self.panel, "Home.dc.html": main])
        let view = try harness.view("Home.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Hello")
        #expect(try await harness.text(view, "return Array.from(document.querySelectorAll('.it')).map(e => e.textContent).join(',')") == "One,Two")
        #expect(try await harness.text(view, "return document.getElementById('count').textContent") == "2", "item-count reads as itemCount")
        #expect(harness.problems.isEmpty)
    }

    @Test func aChildrenAttributeIsTextAndMarkupWrittenInsideTheImportIsNotPassedDown() async throws {
        let main = Self.board("""
            <div style="width: 400px; height: 300px">
            <dc-import name="Panel" title="With attribute" children="from an attribute"><b id="markup-child">Markup child</b></dc-import>
            <dc-import name="Panel" title="With markup only"><b id="second-child">Second markup child</b></dc-import>
            </div>
            """)
        let harness = try BoardHarness(files: ["Panel.dc.html": Self.panel, "Home.dc.html": main])
        let view = try harness.view("Home.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return Array.from(document.querySelectorAll('#kids')).map(e => e.textContent).join('|')")
                == "from an attribute|", "an attribute named children is the piece's children, as text")
        #expect(try await harness.text(view, "return String(document.querySelectorAll('#markup-child, #second-child').length)") == "0",
                "markup inside a <dc-import> is not drawn: a piece has no slots for it")
        #expect(harness.problems.isEmpty)
    }

    @Test func aPieceIsTheSameInEveryBoardThatImportsItAndAChangeReachesAllAtTheirNextLoad() async throws {
        let main = { (n: Int) in Self.board(#"<div style="width: 400px; height: 300px"><dc-import name="Panel" title="Board \#(n)"></dc-import></div>"#) }
        let harness = try BoardHarness(files: ["Panel.dc.html": Self.panel, "One.dc.html": main(1), "Two.dc.html": main(2)])
        let one = try harness.view("One.dc.html"), two = try harness.view("Two.dc.html")
        try await one.load()
        try await two.load()
        let panelStyle = "return getComputedStyle(document.getElementById('panel')).backgroundColor"
        #expect(try await harness.text(one, panelStyle) == "rgba(0, 0, 0, 0)")
        try harness.write("Panel.dc.html", Self.panel.replacingOccurrences(of: #"style="width: 400px; height: 300px""#,
                                                                           with: #"style="width: 400px; height: 300px; background: rgb(1, 2, 3)""#))
        // A board already drawn keeps what it imported until it loads again.
        _ = try await one.load()
        _ = try await two.load()
        #expect(try await harness.text(one, panelStyle) == "rgb(1, 2, 3)")
        #expect(try await harness.text(two, panelStyle) == "rgb(1, 2, 3)", "every importer follows the one piece")
        #expect(try await harness.text(two, "return document.getElementById('title').textContent") == "Board 2", "each keeps its own props")
    }

    @Test func importsNestEightLevelsDeepAndNoDeeperAndAPieceInsideAPieceIsDrawnBeforeTheBoardSettles() async throws {
        // P0 imports P1 imports P2 …; each draws its own marker, so the deepest drawn level shows. The
        // board has settled (load() returned) with every level drawn: a piece inside a piece is not left
        // for a later look.
        var files: [String: String] = [:]
        for level in 0..<12 {
            let next = level < 11 ? #"<dc-import name="P\#(level + 1)"></dc-import>"# : ""
            files["P\(level).dc.html"] = Self.board(#"<div style="width: 400px; height: 300px"><b class="level">L\#(level)</b>\#(next)</div>"#)
        }
        let harness = try BoardHarness(files: files)
        let view = try harness.view("P0.dc.html")
        try await view.load()
        let drawn = try await harness.text(view, "return Array.from(document.querySelectorAll('.level')).map(e => e.textContent).join(',')")
        let levels = drawn.split(separator: ",").count
        #expect(levels == 9, "the board and eight levels of imports below it: \(drawn)")
        #expect(harness.problems.contains { $0.message.contains("imports nest more than 8 deep") })
    }

    @Test func aBoardThatImportsItselfDrawsAPlaceholderAndSaysSo() async throws {
        let loop = Self.board(#"<div style="width: 400px; height: 300px"><b id="loop">Loop</b><dc-import name="Loop" hint-size="20px,10px"></dc-import></div>"#)
        let harness = try BoardHarness(files: ["Loop.dc.html": loop])
        let view = try harness.view("Loop.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return String(document.querySelectorAll('#loop').length)") == "1", "drawn once, not forever")
        #expect(harness.problems.contains { $0.message.contains("a board imports itself") })
    }

    @Test func twoBoardsThatImportEachOtherStopWhereTheLoopCloses() async throws {
        let a = Self.board(#"<div style="width: 400px; height: 300px"><b class="m">A</b><dc-import name="B"></dc-import></div>"#)
        let b = Self.board(#"<div style="width: 400px; height: 300px"><b class="m">B</b><dc-import name="A"></dc-import></div>"#)
        let harness = try BoardHarness(files: ["A.dc.html": a, "B.dc.html": b])
        let view = try harness.view("A.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return Array.from(document.querySelectorAll('.m')).map(e => e.textContent).join(',')") == "A,B")
        #expect(harness.problems.contains { $0.message.contains("a board imports itself") })
    }

    @Test func aPieceInAFolderIsImportedByItsPathFromTheImportingBoardNeverFromAbove() async throws {
        let piece = Self.board(#"<div style="width: 400px; height: 300px"><b id="deep">Deep</b></div>"#)
        let below = Self.board(#"<div style="width: 400px; height: 300px"><dc-import name="parts/Deep"></dc-import></div>"#)
        let above = Self.board(#"<div style="width: 400px; height: 300px"><dc-import name="../Home"></dc-import></div>"#)
        let harness = try BoardHarness(files: ["parts/Deep.dc.html": piece, "Home.dc.html": below, "parts/Up.dc.html": above])
        let view = try harness.view("Home.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return document.getElementById('deep').textContent") == "Deep")
        let up = try harness.view("parts/Up.dc.html")
        try await up.load()
        #expect(harness.problems.contains { $0.message.contains("not a board name") }, "an import never climbs out of its folder")
    }

    @Test func aMissingPieceDrawsItsPlaceholderAndTheBoardGoesOn() async throws {
        let main = Self.board(#"<div style="width: 400px; height: 300px"><b id="before">Before</b><dc-import name="Gone" hint-size="50px,20px"></dc-import><b id="after">After</b></div>"#)
        let harness = try BoardHarness(files: ["Home.dc.html": main])
        let view = try harness.view("Home.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return document.getElementById('before').textContent + document.getElementById('after').textContent") == "BeforeAfter")
        #expect(harness.problems.contains { $0.message.contains("no board at") })
    }
}
