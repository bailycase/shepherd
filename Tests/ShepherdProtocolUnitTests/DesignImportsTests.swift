import Foundation
import Testing
@testable import ShepherdProtocol

/// Shared pieces: which boards a board imports, which import a piece, and which import a board
/// that isn't there.
@Suite("Design imports and usage")
struct DesignImportsTests {
    static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }

    @Test(arguments: [
        ("Card", "A.dc.html", "Card.dc.html"),
        ("Card", "flows/Cart.dc.html", "flows/Card.dc.html"),
        ("parts/Chip", "A.dc.html", "parts/Chip.dc.html"),
        ("parts/Chip", "flows/Cart.dc.html", "flows/parts/Chip.dc.html"),
        ("Card.v2", "A.dc.html", "Card.v2.dc.html"),
        ("_Private-1", "A.dc.html", "_Private-1.dc.html"),
    ] as [(String, String, String?)])
    func aNameResolvesBesideTheBoardThatImportsIt(_ name: String, _ board: String, _ expected: String?) {
        #expect(DesignImports.resolve(name: name, from: Self.path(board))?.rawValue == expected)
    }

    @Test(arguments: ["", "../Card", "a/../b", "/Card", "Card/", "Car d", "{{ which }}", "ds/x", ".hidden", "a\\b", "Card.dc.html/"])
    func aNameTheRuntimeRefusesResolvesToNothing(_ name: String) {
        // The runtime refuses `..`, a leading dot, spaces and anything outside its grammar (and the
        // check never calls a design system's file a board); so does the check.
        #expect(DesignImports.resolve(name: name, from: Self.path("A.dc.html")) == nil)
    }

    @Test func importsAreReadInTemplateOrderWithTheirLines() throws {
        let source = DesignBoardTreeTests.board("""
        <div style="width: 400px; height: 300px">
        <dc-import name="Card" item="{{ it }}"></dc-import>
        <sc-for list="{{ rows }}" as="row"><dc-import name="parts/Chip"></dc-import></sc-for>
        <dc-import name="{{ which }}"></dc-import>
        <dc-import></dc-import>
        </div>
        """)
        let tree = try #require(DesignBoardTree(source: source))
        let references = DesignImports.references(in: tree, of: Self.path("A.dc.html"))
        #expect(references.map(\.name) == ["Card", "parts/Chip", "{{ which }}"], "an import with no name names nothing")
        #expect(references.map(\.target?.rawValue) == ["Card.dc.html", "parts/Chip.dc.html", nil])
        #expect(references.map(\.isDynamic) == [false, false, true])
        let lines = source.components(separatedBy: "\n")
        #expect(references[0].line == (lines.firstIndex { $0.contains(#"name="Card""#) } ?? -2) + 1)
    }

    @Test func theUsageIndexCountsEachBoardOnceNoMatterHowOftenItImports() {
        let a = Self.path("A.dc.html"), b = Self.path("B.dc.html"), card = Self.path("Card.dc.html"), chip = Self.path("Chip.dc.html")
        func refs(_ board: DesignPath, _ names: [String]) -> [DesignImports.Reference] {
            DesignImports.references(names.enumerated().map { DesignImports.Raw(tid: $0.offset, name: $0.element, line: $0.offset + 1) }, of: board)
        }
        let index = DesignUsageIndex.build(imports: [
            a: refs(a, ["Card", "Card", "Chip"]), b: refs(b, ["Card", "Gone", "{{ x }}"]), card: refs(card, ["Chip", "Card"]),
            chip: [],
        ], boards: [a, b, card, chip])
        #expect(index.importers[card] == [a, b], "a board that imports itself is not its own user")
        #expect(index.importers[chip] == [a, card])
        #expect(index.usedIn(card) == 2 && index.usedIn(a) == 0)
        #expect(index.missing == [b: ["Gone"]], "a name with a hole can't be said to be missing")
        #expect(index.imports[a] == [card, chip] && index.imports[card] == [chip] && index.imports[b] == [card])
        #expect(index.label(for: card) == "used in 2 boards" && index.label(for: a) == nil)
        #expect(DesignUsageIndex(importers: [a: [b]]).label(for: a) == "used in 1 board")
    }

    @Test func aBoardDependsOnEverythingItsImportsDrawFromAndACycleEndsWhereItCloses() {
        let a = Self.path("A.dc.html"), b = Self.path("B.dc.html"), c = Self.path("C.dc.html"), d = Self.path("D.dc.html")
        let index = DesignUsageIndex(imports: [a: [b], b: [c, a], c: [d]])
        #expect(index.dependencies(of: a) == [b, c, d], "through B to C, and C to D; the cycle back to A is not A's own dependency")
        #expect(index.dependencies(of: b) == [a, c, d])
        #expect(index.dependencies(of: d).isEmpty)
        #expect(DesignUsageIndex().dependencies(of: a).isEmpty)
    }
}
