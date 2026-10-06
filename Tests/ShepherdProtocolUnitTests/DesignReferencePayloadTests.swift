import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// A reference's kept copy (docs/designs.md › Design references › The copy): its manifest, what
/// it counts, the record pi reads, what a "Looked at…" line says of it, and a chip's short lines
/// of what changed since.
@Suite("Design reference copies")
struct DesignReferencePayloadTests {
    static func board(_ template: String) -> String {
        "<!doctype html>\n<html><head></head><body>\n<x-dc>\n\(template)\n</x-dc>\n</body></html>\n"
    }

    /// The card (0) holds a title (1) and a button (2) with a label inside it (3).
    static let card = board("""
        <div data-el="card" style="padding: 24px; gap: 8px; --local: 1px; background: var(--accent)">
        <h2 style="font-size: 20px">Checkout funnel</h2>
        <button style="border-radius: var(--radius-md); padding: 12px"><span>Pay now</span></button>
        </div>
        """)
    static let button = DesignReference(string: "shepherd-design-ref://local/d1/A.dc.html#2:0/1@4")!
    static let whole = DesignReference(string: "shepherd-design-ref://local/d1/A.dc.html@4")!

    @Test func aPieceDeclaresTheStylesOfItsElementsInOrderOfFirstUse() {
        #expect(DesignReferenceReading.declaredStyles(in: Self.card, element: nil) == ["padding", "gap", "background", "font-size", "border-radius"],
                "custom properties are tokens, not styles")
        #expect(DesignReferenceReading.declaredStyles(in: Self.card, element: Self.button.element) == ["border-radius", "padding"])
        #expect(DesignReferenceReading.declaredStyles(in: "no template", element: nil).isEmpty)
    }

    @Test(arguments: [
        ("card" as String?, "Checkout funnel" as String?, nil as String?, "card “Checkout funnel”"),
        ("card", "card", nil, "card"),
        (nil, "Pay now", "button", "button “Pay now”"),
        (nil, nil, "div", "div"),
        ("  ", "Pay now", nil, "element “Pay now”"),
    ])
    func anElementIsNamedByItsNameOrTagThenItsWords(_ name: String?, _ label: String?, _ tag: String?, _ expected: String) {
        #expect(DesignReferenceReading.elementTitle(name: name, label: label, tag: tag) == expected)
    }

    /// Where the board names an element nothing, the host calls it what the canvas's tag does, so
    /// a chip and the picker agree with the canvas ("card “Checkout funnel”", not "div …").
    @Test(arguments: [
        (#"<div style="padding: 12px; background: #fff"><p>Checkout funnel</p></div>"#, "card"),
        (#"<div style="border: 1px solid #e4e4ea"><p>Steps</p></div>"#, "card"),
        (#"<div style="box-shadow: 0 1px 2px #0003"><p>Steps</p></div>"#, "card"),
        (#"<div style="padding: 12px; background: transparent; border: 0"><p>Steps</p></div>"#, "group"),
        (#"<div><p>Steps</p></div>"#, "group"),
        (#"<p>Steps</p>"#, "text"),
        (#"<div style="height: 4px; background: #4f46e5"></div>"#, "shape"),
        (#"<button>Pay now</button>"#, "button"),
        (#"<div role="button"><span>Pay</span></div>"#, "button"),
        (#"<a href="/docs">Docs</a>"#, "link"),
        (#"<input value="x">"#, "field"),
        (#"<img alt="Logo" src="a.png">"#, "image"),
        (#"<hr>"#, "line"),
        (#"<div data-el="funnel card"><p>Steps</p></div>"#, "funnel card"),
    ])
    func anUnnamedElementIsCalledWhatTheCanvasCallsIt(_ template: String, _ expected: String) {
        #expect(DesignReferenceReading.elementNoun(DesignElementID("A.dc.html#0:0")!, in: Self.board(template)) == expected)
    }

    @Test func anElementsNameIsItsDataElUnlessTheLogicBindsIt() {
        #expect(DesignReferenceReading.elementName(DesignElementID("A.dc.html#0:0")!, in: Self.card) == "card")
        let bound = Self.board(#"<div data-el="{{ name }}">x</div>"#)
        #expect(DesignReferenceReading.elementName(DesignElementID("A.dc.html#0:0")!, in: bound) == nil)
    }

    static func payload(_ reference: DesignReference = button) -> DesignReferencePayload {
        DesignReferencePayload(
            id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!, agentID: AgentID(rawValue: "a1"), reference: reference,
            design: "Checkout funnel dashboard", boardTitle: "A · Funnel first", elementLabel: "Checkout funnel", elementName: "card",
            revision: 23, capturedAt: 1_000, width: 1280, height: 800, boardSHA: "aa",
            picture: .init(name: "A-2@2x.png", bytes: 1_000, pixelWidth: 756, pixelHeight: 612),
            html: .init(name: "A.html", bytes: 6_200), element: .init(name: "A-2.element.html", bytes: 300),
            elementStyles: .init(name: "A-2.styles.json", bytes: 900), source: .init(name: "A.source.dc.html", bytes: 2_000),
            tokensNote: .init(name: "A-2-tokens.md", bytes: 400),
            styles: ["padding", "gap", "border-radius", "background", "color"],
            tokens: [
                .init(name: "--accent", value: "#4f46e5", kind: "color", system: "acme-web", file: "web/static/tokens.css", line: 16),
                .init(name: "--text", value: "#111", kind: "color", system: "acme-web", file: "web/static/tokens.css", line: 4),
                .init(name: "--radius-md", value: "8px", kind: "radius", system: "acme-web"),
                .init(name: "--space-4", value: "16px", kind: "spacing", system: "acme-web", file: "web/static/space.css", line: 2),
            ],
            system: "acme-web")
    }

    @Test func aCopyRoundTripsThroughItsManifest() throws {
        let payload = Self.payload()
        #expect(try DesignReferencePayload.decode(payload.encoded()) == payload)
        var whole = Self.payload(DesignReference(string: "shepherd-design-ref://local/d1@23")!)
        whole.boards = [.init(board: DesignPath("A.dc.html")!, title: "A", width: 10, height: 10, sha256: "aa",
                              picture: .init(name: "01-A@2x.png", bytes: 1), html: .init(name: "01-A.html", bytes: 1))]
        whole.boardCount = 40
        #expect(try DesignReferencePayload.decode(whole.encoded()) == whole)
    }

    @Test func aPageCopyRetainsItsTitleCountsAndBackwardCompatibleFields() throws {
        let ref = try #require(DesignReference(designID: DesignID(rawValue: "d1"), page: "flows", revision: 23))
        let board = DesignPath("A.dc.html")!
        let payload = DesignReferencePayload(agentID: AgentID(rawValue: "a1"), reference: ref, design: "Checkout",
            revision: 23, capturedAt: 1, boards: [.init(board: board, title: "A", width: 10, height: 10, sha256: "aa")],
            boardCount: 1, pageTitle: "Flows")
        #expect(try DesignReferencePayload.decode(payload.encoded()) == payload)
        #expect(payload.page == "flows" && payload.label == "Checkout › Page · Flows")
        #expect(payload.outline.kind == .page && payload.outline.boards == 1)
        let record = payload.record(folder: URL(fileURLWithPath: "/copy"))
        #expect(record.page == "flows" && record.pageTitle == "Flows" && record.label == payload.label)
        #expect(try JSONDecoder().decode(DesignReferenceRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(DesignReferenceLookedAt.make(payload, aspects: [.summary]).title == payload.label)
        #expect(DesignReferenceReading.summary(payload, versions: [23]).contains("page: flows (Flows)"))
        #expect(DesignReferenceReading.summary(payload, versions: [23]).contains("boards: all 1 on this page"))
        #expect(DesignReferenceReading.tokensReport(payload).contains("All 1 board on page Flows"))
        let old = try JSONDecoder().decode(DesignReferenceRecord.self, from: Data(#"{"ref":"shepherd-design-ref://local/d1@3"}"#.utf8))
        #expect(old.page == nil && old.pageTitle == nil)
        var fields = try #require(JSONSerialization.jsonObject(with: Self.payload().encoded()) as? [String: Any])
        fields.removeValue(forKey: "page")
        fields.removeValue(forKey: "pageTitle")
        let oldPayload = try DesignReferencePayload.decode(JSONSerialization.data(withJSONObject: fields))
        #expect(oldPayload.page == nil && oldPayload.pageTitle == nil)
    }

    @Test func aCopysRecordListsItsFilesWhereTheyAreKept() {
        let folder = URL(fileURLWithPath: "/support/design-refs/a1/copy", isDirectory: true)
        let record = Self.payload().record(folder: folder)
        #expect(record.ref == Self.button.string && record.payload == "7C9E6679-7425-40DE-944B-E07FC1F90AE7")
        #expect(record.files == ["A-2@2x.png", "A.html", "A-2.element.html", "A-2.styles.json", "A-2-tokens.md"].map { "/support/design-refs/a1/copy/\($0)" })
        #expect(record.elementLabel == "Checkout funnel" && record.revision == 23 && record.boards == nil)
        #expect(Self.payload().label == "Checkout funnel dashboard › A · Funnel first › card “Checkout funnel”")
    }

    @Test func theOutlineCountsWhatTheCopyHolds() {
        #expect(Self.payload().outline == DesignReferenceOutline(kind: .element, styles: 5, tokens: 4, system: "acme-web"))
    }

    @Test func lookingAtACopySaysWhatTheAgentGotAndWhereEachTokenLives() {
        let all = DesignReferenceLookedAt.make(Self.payload(), aspects: [.image, .html, .element, .tokens])
        #expect(all.title == "Checkout funnel dashboard › A · Funnel first")
        #expect(all.meta == ["picture", "html", "5 styles", "4 tokens"])
        #expect(all.picture?.label == "A · Funnel first › card “Checkout funnel” @2x" && all.picture?.pixelWidth == 756)
        #expect(all.html == .init(name: "A.html", bytes: 6_200))
        #expect(all.styles?.names == ["padding", "gap", "border-radius", "background"])
        #expect(all.tokens?.names == ["--accent", "--text", "--radius-md", "--space-4"])
        #expect(all.tokens?.sources == ["web/static/tokens.css:4–16", "web/static/space.css:2"])
        let summary = DesignReferenceLookedAt.make(Self.payload(), aspects: [.summary])
        #expect(summary.meta.isEmpty && summary.aspects == [.summary])
    }

    // MARK: What changed, for a chip

    @Test func anElementsChangesAreItsStylesWordsAndWhatsInside() {
        let edited = Self.card
            .replacingOccurrences(of: "border-radius: var(--radius-md); padding: 12px", with: "border-radius: var(--radius-lg); padding: 10px; gap: 4px")
            .replacingOccurrences(of: "<span>Pay now</span>", with: "<span style=\"color: red\">Pay now</span><i></i>")
        let lines = DesignReferenceReading.changeLines(reference: Self.button, label: "Pay now", before: Self.card, after: edited)
        #expect(lines == ["border-radius --radius-md → --radius-lg", "padding 12px → 10px", "gap — → 4px",
                          "span “Pay now”: color — → red", "+ <i>"])
        let reworded = Self.card.replacingOccurrences(of: "<span>Pay now</span>", with: "<span>Pay $24</span>")
        #expect(DesignReferenceReading.changeLines(reference: Self.button, label: "Pay now", before: Self.card, after: reworded)
            == ["words “Pay now” → “Pay $24”", "span “Pay $24”: words “Pay now” → “Pay $24”"])
        #expect(DesignReferenceReading.changeLines(reference: Self.button, label: "Pay now", before: Self.card,
                                                   after: Self.card.replacingOccurrences(of: "<span>Pay now</span>", with: "")).contains("− span “Pay now”"))
    }

    @Test func aBoardsChangesAreItsElementsAddedRemovedAndRestyled() {
        let edited = Self.card
            .replacingOccurrences(of: "padding: 24px", with: "padding: 20px")
            .replacingOccurrences(of: #"<h2 style="font-size: 20px">Checkout funnel</h2>"#, with: "")
        let lines = DesignReferenceReading.changeLines(reference: Self.whole, label: nil, before: Self.card, after: edited)
        #expect(lines.first == "div “Checkout funnel Pay now”: padding 24px → 20px" || lines.contains { $0.hasSuffix("padding 24px → 20px") })
        #expect(lines.contains { $0.hasPrefix("− ") || $0.hasPrefix("+ ") })
    }

    @Test func manyChangesEndWithHowManyMore() {
        let many = Self.board((0..<12).map { "<p style=\"margin: \($0)px\">p\($0)</p>" }.joined())
        let moved = Self.board((0..<12).map { "<p style=\"margin: \($0 + 1)px\">p\($0)</p>" }.joined())
        let lines = DesignReferenceReading.changeLines(reference: Self.whole, label: nil, before: many, after: moved, limit: 4)
        #expect(lines.count == 4 && lines.last == "+ 9 more")
        #expect(DesignReferenceReading.changeLines(reference: Self.whole, label: nil, before: many, after: many).isEmpty)
    }

    @Test func anElementThatIsGoneSaysSo() {
        let gone = Self.board("<div><p>Other</p></div>")
        #expect(DesignReferenceReading.changeLines(reference: Self.button, label: "Pay now", before: Self.card, after: gone)
            == ["the element is no longer on the board"])
    }

    @Test func aWholeDesignsChangesAreItsBoards() {
        let a = DesignPath("A.dc.html")!, b = DesignPath("B.dc.html")!, c = DesignPath("C.dc.html")!
        let lines = DesignReferenceReading.designChangeLines(before: [(a, "A · Funnel", "1"), (b, nil, "2")],
                                                             after: [(a, "A · Funnel", "9"), (c, "C · Trend", "3")])
        #expect(lines == ["+ board C · Trend", "− board B", "A · Funnel changed"])
    }

    @Test func theCanvasOrderIsItsListThenTheRestByPath() {
        var index = DesignIndex(title: nil)
        for name in ["C.dc.html", "A.dc.html", "B.dc.html"] {
            index.boards[DesignPath(name)!] = DesignIndex.Board(x: 0, y: 0, w: 10, h: 10)
        }
        index.order = [DesignPath("C.dc.html")!, DesignPath("Z.dc.html")!]
        #expect(DesignReferenceReading.canvasOrder(index).map(\.rawValue) == ["C.dc.html", "A.dc.html", "B.dc.html"])
    }

    @Test func freshnessRoundTrips() throws {
        for value: DesignReferenceFreshness in [.current, .updatedSince(latest: 26, changes: ["padding 24px → 20px"]), .deleted,
                                                 .hostOffline(cachedAt: 1_000)] {
            #expect(try JSONDecoder().decode(DesignReferenceFreshness.self, from: JSONEncoder().encode(value)) == value)
        }
    }
}

/// Notes a thread leaves on a piece it was sent (docs/designs.md › Notes back).
@Suite("Design thread notes")
struct DesignThreadNoteTests {
    @Test(arguments: [
        ("Implemented in #142 on agent/checkout-funnel.", "Implemented in #142 on agent/checkout-funnel." as String?),
        ("  Done.\n\nBars use --accent;\tcounts use the table cell.  ", "Done. Bars use --accent; counts use the table cell."),
        ("a\u{0}b\u{1B}[31mc\u{202E}d", "a b [31mc d"),
        ("   \n\t ", nil),
        (String(repeating: "x", count: DesignThreadNote.maxLength + 1), nil),
        ("👩‍💻 shipped", "👩‍💻 shipped"),
    ])
    func aNoteIsOneShortParagraphOfPlainText(_ text: String, _ expected: String?) {
        #expect(DesignThreadNote.cleaned(text) == expected)
    }

    @Test func aThreadsNewNoteOnAPieceReplacesItsLastAndTheOldestGo() {
        let thread = AgentID(rawValue: "a1"), other = AgentID(rawValue: "a2")
        let board = DesignPath("A.dc.html")!, element = DesignElementID("A.dc.html#2:0/1")!
        func note(_ agent: AgentID, _ element: DesignElementID?, _ text: String) -> DesignThreadNote {
            DesignThreadNote(agentID: agent, thread: "t", board: board, element: element, revision: 4, text: text, createdAt: 1)
        }
        var file = DesignThreadNotes()
        file.add(note(thread, element, "first"))
        file.add(note(other, element, "theirs"))
        file.add(note(thread, nil, "on the board"))
        file.add(note(thread, element, "second"))
        #expect(file.notes.map(\.text) == ["theirs", "on the board", "second"])
        for index in 0..<DesignThreadNote.maxPerDesign { file.add(note(AgentID(rawValue: "x\(index)"), nil, "\(index)")) }
        #expect(file.notes.count == DesignThreadNote.maxPerDesign && file.notes.first?.text == "0")
        let decoded = try? JSONDecoder().decode(DesignThreadNotes.self, from: JSONEncoder().encode(file))
        #expect(decoded == file)
    }
}
