import Foundation
import Testing
import ShepherdProtocol

/// Export's pure rules: which boards go and how the button counts them, where each lands, what a
/// ZIP carries of the canvas, and how uploads and tokens travel.
@Suite("Design export")
struct DesignExportTests {
    static func index() throws -> DesignIndex {
        try DesignIndex.decode(Data("""
            {"v":3,"title":"Checkout","boards":{
              "A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"title":"A · Funnel first"},
              "A-phone.dc.html":{"x":1360,"y":0,"w":390,"h":844,"title":"A · phone"},
              "B.dc.html":{"x":0,"y":920,"w":1280,"h":800,"title":"B · Step table"},
              "C.dc.html":{"x":1360,"y":920,"w":1280,"h":800}},
             "order":["A.dc.html","A-phone.dc.html","B.dc.html","C.dc.html"],
             "attachments":{"keep":true},"launch":{"view":"focused","file":"C.dc.html"}}
            """.utf8))
    }

    static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }

    @Test(arguments: [
        ([], 4, "Export 4 boards"),
        (["A.dc.html"], 1, "Export 1 board"),
        (["A.dc.html", "A-phone.dc.html"], 2, "Export 2 boards"),
        (["A.dc.html", "Gone.dc.html"], 1, "Export 1 board"),
    ])
    func theSheetOpensTickedFromTheSelectionAndCountsTheTicks(_ selected: [String], _ count: Int, _ title: String) throws {
        let selection = DesignExportSelection(index: try Self.index(), selected: selected.map(Self.path))
        #expect(selection.count == count)
        #expect(selection.exportTitle == title)
        #expect(selection.rows.map(\.title) == ["A · Funnel first", "A · phone", "B · Step table", "C"])
        #expect(selection.rows.map(\.size) == ["1280 × 800", "390 × 844", "1280 × 800", "1280 × 800"])
    }

    @Test func theExportCountFollowsTheTicks() throws {
        var selection = DesignExportSelection(index: try Self.index(), selected: [Self.path("A.dc.html"), Self.path("A-phone.dc.html")])
        #expect(selection.boards == [Self.path("A.dc.html"), Self.path("A-phone.dc.html")])
        selection.toggle(Self.path("C.dc.html"))
        #expect(selection.count == 3 && selection.exportTitle == "Export 3 boards")
        selection.toggle(Self.path("A.dc.html"))
        selection.toggle(Self.path("A-phone.dc.html"))
        selection.setTicked(Self.path("C.dc.html"), false)
        #expect(selection.count == 0 && selection.exportTitle == "Export 0 boards")
        // A board the canvas doesn't list never ticks.
        selection.setTicked(Self.path("Gone.dc.html"), true)
        #expect(selection.count == 0)
        // Ticked boards export in canvas order, whatever order they were ticked in.
        selection.toggle(Self.path("C.dc.html"))
        selection.toggle(Self.path("A.dc.html"))
        #expect(selection.boards == [Self.path("A.dc.html"), Self.path("C.dc.html")])
    }

    @Test(arguments: [
        ("A.dc.html", "A.html", "A@2x.png"),
        ("flows/Cart.dc.html", "flows/Cart.html", "flows/Cart@2x.png"),
    ])
    func eachBoardLandsUnderItsOwnName(_ raw: String, _ html: String, _ png: String) {
        #expect(DesignExportNames.html(Self.path(raw)) == html)
        #expect(DesignExportNames.png(Self.path(raw)) == png)
    }

    @Test(arguments: [
        ("Checkout funnel", "Checkout funnel"),
        ("a/b: c", "a-b- c"),
        ("  .hidden ", "hidden"),
        ("   ", "Design"),
    ])
    func aDesignsNameBecomesAFileName(_ name: String, _ file: String) {
        #expect(DesignExportNames.fileName(name) == file)
    }

    @Test func aZipCarriesTheBoardsTheExportedOnesImport() {
        let sources: [String: String] = [
            "A.dc.html": #"<x-dc><dc-import name="Card" hint-size="1,1"></dc-import><dc-import hint-size="1" name='Chart'></dc-import></x-dc>"#,
            "Card.dc.html": #"<x-dc><dc-import name="Badge"></dc-import></x-dc>"#,
            "Badge.dc.html": "<x-dc><span></span></x-dc>",
            "Chart.dc.html": #"<x-dc><dc-import name="Chart"></dc-import></x-dc>"#,
            "flows/Cart.dc.html": #"<x-dc><dc-import name="Line"></dc-import><dc-import name="../A"></dc-import></x-dc>"#,
        ]
        let members = DesignBundle.members([Self.path("A.dc.html"), Self.path("flows/Cart.dc.html")]) { sources[$0.rawValue] }
        #expect(members.map(\.rawValue) == ["A.dc.html", "flows/Cart.dc.html", "Card.dc.html", "Chart.dc.html", "flows/Line.dc.html", "Badge.dc.html"])
    }

    @Test func aZipsCanvasKeepsOnlyItsBoardsAndEveryOtherKey() throws {
        let narrowed = DesignBundle.index(try Self.index(), keeping: [Self.path("A.dc.html"), Self.path("A-phone.dc.html")])
        #expect(Set(narrowed.boards.keys) == [Self.path("A.dc.html"), Self.path("A-phone.dc.html")])
        #expect(narrowed.order == [Self.path("A.dc.html"), Self.path("A-phone.dc.html")])
        #expect(narrowed.extra["attachments"] == .object(["keep": .bool(true)]))
        #expect(narrowed.title == "Checkout")
        // It launched focused on a board it no longer holds: it opens on the canvas.
        #expect(narrowed.launch?.file == nil && narrowed.launch?.view == "canvas")
        #expect(narrowed.problems().isEmpty)
    }

    @Test func uploadsAreFoundAndSwappedByTheirBlobURL() {
        let html = #"<img src="/_blob/abc-1"><style>@font-face{src:url("/_blob/F_2")}</style><a href="/_blob/abc-1">x</a>"#
        #expect(DesignBundle.blobIDs(in: html) == ["abc-1", "F_2"])
        let swapped = DesignBundle.rewritingBlobs(html) { $0 == "F_2" ? "assets/F_2.woff2" : nil }
        #expect(swapped == #"<img src="/_blob/abc-1"><style>@font-face{src:url("assets/F_2.woff2")}</style><a href="/_blob/abc-1">x</a>"#)
        #expect(DesignBundle.dataURI(Data([1, 2, 3]), type: "font/woff2") == "data:font/woff2;base64,AQID")
    }

    @Test(arguments: [
        ("abc", true), ("abc-1_2.png", true), ("x.woff2", true), ("a.b.c", false), (".png", false),
        ("a b.png", false), ("../x.png", false), ("x.", false), ("x.p_g", false),
    ])
    func anAssetIsNamedByItsID(_ name: String, _ valid: Bool) {
        #expect(DesignBundle.isAssetName(name) == valid)
    }

    @Test func tokensCSSListsEveryTokenAndTheNoteOnlyTheUsedOnes() {
        let tokens = DesignTokens.read(css: ":root { --accent: #4F46E5; --ink: #111; --space-6: 24px; --radius-m: 0.5rem; }")
        let css = DesignExportTokens.css(tokens, heading: "Checkout · tokens")
        #expect(css == "/* Checkout · tokens */\n:root {\n  --accent: #4f46e5;\n  --ink: #111111;\n  --space-6: 24px;\n  --radius-m: 8px;\n}\n")
        let used = DesignExportTokens.used(tokens, in: [#"<div style="color: var(--accent); gap: var( --space-6 )">"#, "var(--missing)"])
        #expect(used.colors.map(\.name) == ["--accent"])
        #expect(used.lengths.map(\.name) == ["--space-6"])
    }
}

/// A board's print mode and a flow document's page breaks (print.md).
@Suite("Design print")
struct DesignPrintTests {
    @Test(arguments: [
        ([:], DesignPrint.fixed),
        (["print": JSONValue.string("fixed")], .fixed),
        (["print": .string("flow")], .flow(.letter)),
        (["print": .string("flow"), "paper": .string("a4")], .flow(.a4)),
        (["print": .string("flow"), "paper": .string("tabloid")], .flow(.letter)),
    ])
    func aBoardPrintsFixedUnlessItFlows(_ extra: [String: JSONValue], _ mode: DesignPrint) {
        #expect(DesignPrint.of(DesignIndex.Board(x: 0, y: 0, w: 816, h: 1056, extra: extra)) == mode)
    }

    @Test func aFlowDocumentFillsEachPageBetweenItsGaps() {
        // Letter: 1056 tall, 53 below each cut and above each later page's content.
        let pages = DesignPrint.pages(contentHeight: 2500, pageHeight: 1056)
        #expect(pages == [
            .init(start: 0, end: 1003, top: 0),
            .init(start: 1003, end: 1953, top: 53),
            .init(start: 1953, end: 2500, top: 53),
        ])
    }

    @Test func aCutFallsBetweenLinesAndNeverThroughAnImageThatFits() {
        let lines: [ClosedRange<Double>] = [980...1000, 1000...1020, 1020...1040]
        #expect(DesignPrint.pages(contentHeight: 1500, pageHeight: 1056, lines: lines).first?.end == 1000)
        let image: [ClosedRange<Double>] = [700...1400]
        #expect(DesignPrint.pages(contentHeight: 1500, pageHeight: 1056, blocks: image).first?.end == 700)
        // Taller than a page: cut where the page ends.
        let tall: [ClosedRange<Double>] = [100...1300]
        #expect(DesignPrint.pages(contentHeight: 1500, pageHeight: 1056, blocks: tall).first?.end == 1003)
    }

    @Test func aFlowDocumentStopsAtAHundredPages() {
        #expect(DesignPrint.pages(contentHeight: 1_000_000, pageHeight: 1056).count == DesignPrint.maxPages)
        #expect(DesignPrint.pages(contentHeight: 0, pageHeight: 1056).count == 1)
    }
}
