import Foundation
import Testing
import ShepherdProtocol

/// A canvas's pages and notes as the canvas shows them, and where Duplicate puts a copy.
@Suite("Design canvas layout")
struct DesignCanvasLayoutTests {
    static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }

    static func board(_ x: Double, _ y: Double, _ w: Double = 1280, _ h: Double = 800, page: String? = nil,
                      title: String? = nil) -> DesignIndex.Board {
        DesignIndex.Board(x: x, y: y, w: w, h: h, title: title, page: page)
    }

    // MARK: Pages

    static let paged = DesignIndex(
        title: "Checkout",
        boards: [path("A.dc.html"): board(0, 0, page: "flows"), path("B.dc.html"): board(0, 0, page: "system"),
                 path("C.dc.html"): board(0, 0), path("D.dc.html"): board(0, 0, page: "gone")],
        order: [path("A.dc.html"), path("B.dc.html"), path("C.dc.html"), path("D.dc.html")],
        pages: [.init(id: "flows", name: "Flows"), .init(id: "system", name: "System")])

    /// A board is on the page it names; one naming no page, or a page the index doesn't have, is
    /// on the first, so nothing listed goes missing.
    @Test(arguments: [("A.dc.html", "flows"), ("B.dc.html", "system"), ("C.dc.html", "flows"), ("D.dc.html", "flows")])
    func aBoardIsOnItsPageElseTheFirst(_ raw: String, _ page: String) {
        #expect(Self.paged.page(of: Self.path(raw)) == page)
        #expect(Self.paged.isOnPage(Self.path(raw), page))
    }

    @Test func aCanvasWithoutPagesShowsEveryBoardOnNone() {
        var index = Self.paged
        index.pages = []
        #expect(index.page(of: Self.path("B.dc.html")) == nil)
        #expect(index.isOnPage(Self.path("B.dc.html"), nil))
        #expect(index.openingPage == nil)
    }

    @Test(arguments: [(nil as String?, "flows"), ("system", "system"), ("gone", "flows")])
    func aCanvasOpensOnItsLaunchPageWhenItHasIt(_ launch: String?, _ opening: String) {
        var index = Self.paged
        index.launch = DesignIndex.Launch(view: "canvas", page: launch)
        #expect(index.openingPage == opening)
    }

    // MARK: Notes

    @Test(arguments: [("title1" as String?, DesignIndex.Note.Shown.title), ("title2", .title), ("sticky", .sticky), ("pen", .drawing),
                      ("rect", .drawing), ("arrow", .drawing), (nil, .drawing)])
    func aNoteIsATitleAStickyOrADrawing(_ kind: String?, _ shown: DesignIndex.Note.Shown) {
        #expect(DesignIndex.Note(x: 0, y: 0, text: "Flows", kind: kind).shown == shown)
    }

    @Test func aNoteRunsAsWideAsItsMaxWidthElseItsWidth() {
        #expect(DesignIndex.Note(x: 0, y: 0, text: "T", kind: "title1", extra: ["w": .number(240), "maxW": .number(4960)]).width == 4960)
        #expect(DesignIndex.Note(x: 0, y: 0, text: "T", kind: "sticky", extra: ["w": .number(240)]).width == 240)
        #expect(DesignIndex.Note(x: 0, y: 0, text: "T", kind: "sticky").width == nil)
    }

    @Test func aNoteIsOnItsPageElseTheFirst() {
        #expect(Self.paged.page(of: DesignIndex.Note(x: 0, y: 0, text: "T", kind: "title1", page: "system")) == "system")
        #expect(Self.paged.page(of: DesignIndex.Note(x: 0, y: 0, text: "T", kind: "title1")) == "flows")
    }

    // MARK: Duplicate

    @Test(arguments: [
        ("A.dc.html", [], "A-copy.dc.html"),
        ("A.dc.html", ["A-copy.dc.html"], "A-copy-2.dc.html"),
        ("A.dc.html", ["a-COPY.dc.html", "A-copy-2.dc.html"], "A-copy-3.dc.html"),
        ("flows/Cart.dc.html", [], "flows/Cart-copy.dc.html"),
        // Another folder's board shares the stem namespace: stems are unique in the design.
        ("flows/Cart.dc.html", ["Cart-copy.dc.html"], "flows/Cart-copy-2.dc.html"),
    ])
    func aCopyTakesTheFirstFreeName(_ raw: String, _ taken: [String], _ copy: String) {
        let path = Self.path(raw)
        #expect(DesignIndex.duplicatePath(for: path, taken: Set(taken.map(Self.path) + [path])) == Self.path(copy))
    }

    @Test func aCopyWhoseNameWouldBeTooLongHasNone() {
        let long = Self.path(String(repeating: "x", count: 190) + ".dc.html")
        #expect(DesignIndex.duplicatePath(for: long, taken: [long]) == nil)
    }

    /// The skill's rows: 80 apart. A copy of A lands past the boards of its row it would overlap,
    /// 80 after the last; a board on another page is no obstacle.
    @Test func aCopyGoesBesideTheBoardPastWhatItWouldOverlap() {
        let index = DesignIndex(
            title: "T",
            boards: [Self.path("A.dc.html"): Self.board(0, 0, page: "p"), Self.path("B.dc.html"): Self.board(1360, 0, page: "p"),
                     Self.path("Phone.dc.html"): Self.board(2720, 0, 390, 844, page: "p"),
                     Self.path("Below.dc.html"): Self.board(0, 920, page: "p"),
                     Self.path("Elsewhere.dc.html"): Self.board(3190, 0, page: "q")],
            order: [], pages: [.init(id: "p", name: "P"), .init(id: "q", name: "Q")])
        #expect(index.duplicatePlacement(of: Self.path("A.dc.html"))! == (3190, 0))
        #expect(index.duplicatePlacement(of: Self.path("Below.dc.html"))! == (1360, 920))
        #expect(index.duplicatePlacement(of: Self.path("Elsewhere.dc.html"))! == (4550, 0))
    }

    @Test func aDuplicatedEntryIsATitledCopyAfterItsBoardWithItsTweaks() throws {
        let a = Self.path("A.dc.html"), b = Self.path("B.dc.html"), copy = Self.path("A-copy.dc.html")
        var index = DesignIndex(title: "T", boards: [a: Self.board(0, 0, title: "A · Funnel first"), b: Self.board(0, 920)],
                                order: [a, b])
        index.boards[a]?.isInteractive = true
        index.boards[a]?.extra = ["frameless": .bool(true)]
        index.extra[DesignIndex.tweaksKey] = .object([a.rawValue: .object(["rows": .number(6)])])
        let next = try #require(index.duplicating(a, as: copy))
        let entry = try #require(next.boards[copy])
        #expect(entry.title == "A · Funnel first copy")
        #expect((entry.x, entry.y, entry.w, entry.h) == (1360, 0, 1280, 800))
        #expect(entry.isInteractive == true && entry.extra["frameless"] == .bool(true))
        #expect(next.order == [a, copy, b])
        #expect(next.tweaks(for: copy) == ["rows": .number(6)])
        #expect(next.tweaks(for: a) == ["rows": .number(6)])
        #expect(next.problems().isEmpty)
        #expect(index.duplicating(a, as: b) == nil, "a copy never replaces a board")
        #expect(index.duplicateTitle(of: b) == "B copy", "a board without a title is named by its stem")
    }
}
