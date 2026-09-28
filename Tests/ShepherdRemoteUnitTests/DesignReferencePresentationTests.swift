import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The words of design references (DesignRefStates): the Implement sheet's footer, the chip's
/// preview and state lines, the toasts, and which design_get calls one "Looked at…" line joins.
@Suite("Design reference presentation")
struct DesignReferencePresentationTests {
    @Test(arguments: [
        (DesignReferenceOutline(kind: .element, styles: 11, tokens: 8, system: "acme-web"),
         "Sends a picture, its HTML, 11 styles and 8 tokens from acme-web."),
        (DesignReferenceOutline(kind: .board, styles: 42, tokens: 14, system: "acme-web"),
         "Sends a picture, the board’s HTML, 42 styles and 14 tokens from acme-web."),
        (DesignReferenceOutline(kind: .board, styles: 1, tokens: 0),
         "Sends a picture, the board’s HTML and 1 style."),
        (DesignReferenceOutline(kind: .element, styles: 0, tokens: 0),
         "Sends a picture and its HTML."),
        (DesignReferenceOutline(kind: .design, styles: 0, tokens: 2, boards: 1, boardCount: 1),
         "Sends a picture and the HTML of each of its 1 board and 2 tokens."),
        (DesignReferenceOutline(kind: .design, styles: 3, tokens: 1, system: "acme-web", boards: 4, boardCount: 4),
         "Sends a picture and the HTML of each of its 4 boards, 3 styles and 1 token from acme-web."),
        (DesignReferenceOutline(kind: .design, styles: 3, tokens: 1, boards: 12, boardCount: 40),
         "Sends a picture and the HTML of each of its first 12 of 40 boards, 3 styles and 1 token."),
    ])
    func theFooterSaysExactlyWhatGoes(_ outline: DesignReferenceOutline, _ expected: String) {
        #expect(DesignReferencePresentation.sends(outline) == expected)
    }

    @Test func thePreviewSaysWhatTheAgentGets() {
        #expect(DesignReferencePresentation.gets(DesignReferenceOutline(kind: .element, styles: 11, tokens: 8))
            == ["picture", "html", "11 styles", "8 tokens"])
        #expect(DesignReferencePresentation.gets(DesignReferenceOutline(kind: .board, styles: 3, tokens: 0)) == ["picture", "html", "3 styles"])
        #expect(DesignReferencePresentation.version(23) == "v23" && DesignReferencePresentation.version(nil) == nil)
    }

    @Test func theChipSaysHowItStands() {
        #expect(DesignReferencePresentation.state(.current) == nil)
        #expect(DesignReferencePresentation.state(.updatedSince(latest: 26, changes: ["padding 24px → 20px"])) == "updated since · now v26")
        #expect(DesignReferencePresentation.state(.deleted) == "design deleted · the copy sent here is kept")
        #expect(DesignReferencePresentation.state(.hostOffline(cachedAt: 1_000), formatDate: { _ in "Sep 26" })
            == "offline · uses the copy from Sep 26")
        #expect(DesignReferencePresentation.sendLatest(.updatedSince(latest: 26, changes: [])) == "Send v26")
        #expect(DesignReferencePresentation.sendLatest(.current) == nil && DesignReferencePresentation.sendLatest(.deleted) == nil)
    }

    @Test func theToastsNameThePiece() {
        #expect(DesignReferencePresentation.sent("card “Checkout funnel”", to: "Checkout page polish")
            == "Sent card “Checkout funnel” to Checkout page polish.")
        #expect(DesignReferencePresentation.copied("card “Checkout funnel”")
            == "Copied a reference to card “Checkout funnel”. Paste it into any thread’s composer.")
        #expect(DesignReferencePresentation.piece((.element, "Checkout", "A · Funnel first", "card “Checkout funnel”")) == "card “Checkout funnel”")
        #expect(DesignReferencePresentation.piece((.board, "Checkout", "A · Funnel first", nil)) == "A · Funnel first")
        #expect(DesignReferencePresentation.piece((.design, "Checkout", nil, nil)) == "Checkout")
    }

    /// Consecutive design_get calls on one ref are one "Looked at…" line; another tool, or
    /// another ref, starts the next.
    @Test func consecutiveReadsOfOneReferenceAreOneLine() {
        func call(_ id: String, _ ref: String, _ what: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: id, role: "toolResult", blocks: [], toolName: "design_get",
                                argumentsText: #"{"ref":"\#(ref)","what":"\#(what)"}"#)
        }
        let a = "shepherd-design-ref://local/d1/A.dc.html@4", b = "shepherd-design-ref://local/d1/B.dc.html@4"
        let messages = [
            NativeThreadMessage(entryID: "u", role: "user", blocks: []),
            call("1", a, "summary"), call("2", a, "image"), call("3", a, "tokens"),
            NativeThreadMessage(entryID: "4", role: "toolResult", blocks: [], toolName: "read", argumentsText: "{}"),
            call("5", a, "html"), call("6", b, "image"),
            NativeThreadMessage(entryID: "7", role: "toolResult", blocks: [], toolName: "design_get", argumentsText: "not json"),
        ]
        let calls = DesignReferenceCall.calls(in: messages)
        #expect(calls.map(\.ref) == [a, a, b])
        #expect(calls.map(\.entryIDs) == [["1", "2", "3"], ["5"], ["6"]])
        #expect(calls.first?.aspects == [.summary, .image, .tokens])
    }
}

/// The composer's @ picker (MentionPicker): a design's rows from what the host read, the scopes
/// the picker drills through, and search across every level.
@Suite("Design mentions")
struct DesignMentionTests {
    static let design = Design(id: DesignID(rawValue: "d1"), name: "Checkout funnel dashboard", createdAt: 1)

    static func board(_ template: String) -> String {
        "<!doctype html>\n<html><head></head><body>\n<x-dc>\n<helmet><style>body{margin:0}</style></helmet>\n\(template)\n</x-dc>\n</body></html>\n"
    }

    static let funnel = board("""
        <div data-el="card"><h2>Checkout funnel</h2><ol><li>Cart viewed</li><li>Order placed</li></ol></div>
        <section><p>Top exit reasons</p></section>
        <sc-for each="{{ rows }}"><span>{{ row }}</span></sc-for>
        """)

    static func snapshot() -> DesignSnapshot {
        var index = DesignIndex(title: nil)
        index.boards[DesignPath("B.dc.html")!] = DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "B · Step table")
        index.boards[DesignPath("A.dc.html")!] = DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first")
        index.order = [DesignPath("A.dc.html")!, DesignPath("B.dc.html")!]
        return DesignSnapshot(designID: design.id, revision: 3, index: index, boards: [:])
    }

    static func catalog() throws -> DesignMentionCatalog {
        let entries = try #require(DesignMentionCatalog.entries(design: design, snapshot: snapshot(),
                                                                sources: [DesignPath("A.dc.html")!: funnel], system: "acme-web"))
        return DesignMentionCatalog(designs: [entries.design], boards: [design.id: entries.boards], elements: entries.elements)
    }

    @Test func aDesignsRowsAreItsBoardsInCanvasOrderThenTheirElements() throws {
        let catalog = try Self.catalog()
        let design = try #require(catalog.designs.first)
        #expect(design.kind == .design && design.reference.board == nil && design.system == "acme-web" && design.boardCount == 2)
        let rows = catalog.rows(in: .design(Self.design.id))
        #expect(rows.map(\.title) == ["Checkout funnel dashboard", "A · Funnel first", "B · Step table"], "the whole design first")
        let board = rows[1]
        #expect(board.breadcrumb == ["Checkout funnel dashboard"] && board.width == 1280 && board.elementCount == 6)
        let inside = catalog.rows(in: .board(board.reference.pinned(at: 3)))
        #expect(inside.first == board, "Whole board first")
        #expect(inside.dropFirst().map(\.title) == [
            "card “Checkout funnel Cart viewed Order placed”", "text “Checkout funnel”", "group “Cart viewed Order placed”",
            "text “Cart viewed”", "text “Order placed”", "group “Top exit reasons”",
        ], "the helmet, its style and the loop's scaffold left out; a <p> that repeats its section's words too; each named as the canvas names it")
        #expect(inside.last?.breadcrumb == ["Checkout funnel dashboard", "A · Funnel first"])
        #expect(inside[1].inside == 4 && inside[1].tag == "div")
        #expect(catalog.rows(in: .board(rows[2].reference)).count == 1, "a board with no source lists no elements")
        #expect(inside.dropFirst().allSatisfy { $0.reference.revision == nil && $0.reference.element != nil })
    }

    @Test func searchMatchesEveryLevelInCatalogOrder() throws {
        let catalog = try Self.catalog()
        #expect(catalog.search("funnel").map(\.kind) == [.design, .board, .element, .element, .element, .element, .element, .element, .board])
        #expect(catalog.search("order placed").map(\.title) == ["card “Checkout funnel Cart viewed Order placed”", "group “Cart viewed Order placed”", "text “Order placed”"])
        #expect(catalog.search("step table").map(\.title) == ["B · Step table"])
        #expect(catalog.search("pricng").isEmpty)
        #expect(catalog.search("  ").map(\.kind) == [.design], "no words: the designs")
        #expect(catalog.search("funnel", limit: 2).count == 2)
        #expect(catalog.search("CHECKOUT FÜNNEL").first?.kind == .design, "case and accents aside")
    }
}
