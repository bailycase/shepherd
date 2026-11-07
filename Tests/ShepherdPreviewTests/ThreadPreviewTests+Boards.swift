import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Boards in a thread (ThreadBoardShown, ThreadBoardStale): the agent looks at a board it was
/// sent and shows it with design_show; the card keeps what the agent saw after the design moves
/// on. The thread's references answer from fixtures, as the host would.
extension ThreadPreviewTests {
    static let boardSize = CGSize(width: 1440, height: 900)
    static let boardCopy = UUID(uuidString: "7A51C0DE-0000-4000-8000-0000000000B1")!
    static let boardReference = DesignReference(designID: referenceDesign, board: referenceBoard, revision: 13)!

    /// Board A · Funnel first at 2x: a white page with three counts across the top and the steps
    /// as bars, widest at Cart.
    static func funnelPicture() -> CGImage {
        let width = 1120, height = 820
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let h = CGFloat(height)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ height: CGFloat, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: h - y - height, width: w, height: height))
        }
        let ink = CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let muted = CGColor(red: 0.62, green: 0.63, blue: 0.66, alpha: 1)
        let line = CGColor(red: 0.89, green: 0.9, blue: 0.91, alpha: 1)
        let blue = CGColor(red: 0.16, green: 0.43, blue: 0.9, alpha: 1)
        box(0, 0, CGFloat(width), h, CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        box(48, 40, 60, 14, ink)
        box(900, 40, 170, 12, muted)
        box(48, 120, 220, 10, muted)
        box(48, 150, 380, 34, ink)
        box(48, 210, 420, 12, muted)
        for index in 0..<3 {
            let x = 48 + CGFloat(index) * 345
            box(x, 270, 325, 140, line)
            box(x + 2, 272, 321, 136, CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            box(x + 26, 300, 120, 10, muted)
            box(x + 26, 340, [150, 150, 80][index], 36, ink)
        }
        for (index, share) in [1.0, 0.66, 0.44].enumerated() {
            let y = 460 + CGFloat(index) * 46
            box(48, y, 70, 12, muted)
            box(176, y - 2, 480 * share, 14, blue)
            box(176 + 480 * share + 14, y, 50, 12, ink)
        }
        return context.makeImage()!
    }

    /// What the user asked, the agent's look at the board, its words, the card and its offer.
    static func boardSnapshot(asked: String, said: String, after: String) -> NativeThreadSnapshot {
        var snapshot = Threads.empty
        snapshot.supportedActions += ["designReferences"]
        let start = Date().timeIntervalSince1970 * 1000 - 120_000
        let ref = boardReference.string
        var show = NativeThreadMessage(entryID: "s1", role: "toolResult", blocks: [.init(kind: .text, text: "Showed it.")], toolName: "design_show",
                                       toolCallID: "s1", argumentsText: #"{"ref":"\#(ref)"}"#, status: "complete",
                                       timestamp: start + 9_000, startedAt: start + 8_800)
        show.designBoard = boardCopy
        snapshot.messages = [
            NativeThreadMessage(entryID: "u1", role: "user", blocks: [.init(kind: .text, text: asked)], timestamp: start),
            NativeThreadMessage(entryID: "g1", role: "toolResult", blocks: [.init(kind: .text, text: "fenced design data")], toolName: "design_get",
                                toolCallID: "g1", argumentsText: #"{"ref":"\#(ref)","what":"summary"}"#, status: "complete",
                                timestamp: start + 4_000, startedAt: start + 3_600),
            NativeThreadMessage(entryID: "a1", role: "assistant", blocks: [.init(kind: .text, text: said)], timestamp: start + 8_000),
            show,
            NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [.init(kind: .text, text: after)], timestamp: start + 10_000),
        ]
        return snapshot
    }

    static func boardChips(freshness: DesignReferenceFreshness) -> DesignReferenceChips {
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "preview"), io: DesignReferenceChips.IO(
            lookedAt: { ref, aspects in
                DesignReferenceLookedAt(ref: ref, title: "Checkout redesign › A · Funnel first", aspects: Array(aspects))
            }))
        let stale = freshness != .current
        chips.seed(boards: [boardCopy: DesignReferenceChips.Board(
            design: "Checkout redesign", board: "A · Funnel first",
            meta: ["Checkout", "560 × 410", stale ? "shown at revision 13" : "revision 13"],
            note: DesignReferencePresentation.boardNote(freshness), showLatest: DesignReferencePresentation.showLatest(freshness),
            size: CGSize(width: 560, height: 410),
            picture: SHReferenceImage(id: "funnel", image: Image(decorative: funnelPicture(), scale: 2)), hasPicture: true,
            reference: boardReference)])
        return chips
    }

    private func renderBoard(_ surface: String, _ snapshot: NativeThreadSnapshot, chips: DesignReferenceChips) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        let store = fixture.store
        try await Preview.render(surface, size: Self.boardSize, ready: { store.ready && !store.rows.isEmpty }) {
            fixture.thread(title: "Build the checkout funnel page", workingDirectory: "~/Developer/dashboard-web")
                .environment(\.designReferences, chips)
        }
    }

    /// ThreadBoardShown: the board the agent looked at, shown in the thread.
    @Test func threadBoardShown() async throws {
        try await renderBoard("thread-board-shown", Self.boardSnapshot(
            asked: "What did we decide the funnel should look like? I don’t want to open the design.",
            said: "This is the board from Checkout redesign. Three counts across the top, then the steps as bars, widest at Cart. The comment pinned on the bars asks for the drop-off percent next to each count.",
            after: "Want me to build it in dashboard-web? I’d reuse the existing stat card for the three counts."),
            chips: Self.boardChips(freshness: .current))
    }

    /// ThreadBoardStale: the design moved on; the card keeps revision 13 and offers Show v14.
    @Test func threadBoardStale() async throws {
        try await renderBoard("thread-board-stale", Self.boardSnapshot(
            asked: "What did we decide the funnel should look like?",
            said: "This is the board from Checkout redesign.",
            after: "Someone changed the board since I showed it. The card still shows revision 13, the version I looked at."),
            chips: Self.boardChips(freshness: .updatedSince(latest: 14, changes: ["the board changed"])))
    }
}
