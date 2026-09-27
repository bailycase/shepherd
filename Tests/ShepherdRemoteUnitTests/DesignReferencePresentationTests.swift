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
         "Sends a picture, the board’s HTML, 1 style and 0 tokens."),
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
