import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A design's chat at its real width (`AppLayout.designChatWidth`, the column beside the canvas),
/// and an ordinary thread at the narrowest columns it meets (`AppLayout.threadMinWidth`, a
/// phone's), holding what a design agent really leaves in a long session: paragraphs that run
/// long, activity lines whose label names boards, calls whose arguments are one long JSON string,
/// failures that name long paths, a compaction, and a comment's card with the agent's answer
/// inside it (docs/designs.md › Comments). Every row fits its column: its words wrap, its meta
/// and an over-long label truncate, and Show summary stays in reach (docs/design/thread.md ›
/// Activity lines, Compactions).
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests/designChat
extension ThreadPreviewTests {
    /// The design chat of the user's report: a comment's card with the agent's long answer inside it,
    /// and a compaction in the middle of the work.
    @Test func designChatLongRows() async throws {
        let fixture = ThreadFixture(DesignChatThreads.story)
        defer { fixture.store.stop() }
        let size = CGSize(width: AppLayout.designChatWidth, height: 1300)
        try await Preview.renderMatrix("design-chat-long-rows", size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty }) {
            DesignChatThreads.chat(fixture, width: size.width, height: size.height)
        }
    }

    /// Every kind of row that can outgrow its column, in the design chat, four to a picture.
    @Test(arguments: DesignChatThreads.parts) func designChatEveryRow(part: Int) async throws {
        let fixture = ThreadFixture(DesignChatThreads.everyRow(designChat: true, part: part))
        defer { fixture.store.stop() }
        let size = CGSize(width: AppLayout.designChatWidth, height: DesignChatThreads.partHeight)
        try await Preview.renderMatrix("design-chat-every-row-\(part)", size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty }) {
            DesignChatThreads.chat(fixture, width: size.width, height: size.height)
        }
    }

    /// The same rows in an ordinary thread at its narrowest column and at a phone's width.
    @Test(arguments: [AppLayout.threadMinWidth, 320.0], DesignChatThreads.parts)
    func threadEveryRowAtANarrowWidth(width: Double, part: Int) async throws {
        let fixture = ThreadFixture(DesignChatThreads.everyRow(designChat: false, part: part))
        defer { fixture.store.stop() }
        let size = CGSize(width: width, height: DesignChatThreads.partHeight)
        try await Preview.renderMatrix("thread-every-row-\(Int(width))-\(part)", size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty }) {
            DesignChatThreads.chat(fixture, width: size.width, height: size.height, designChat: false)
        }
    }
}

@MainActor
enum DesignChatThreads {
    /// The cards a design's screen derives from its comments, by the screen's own function.
    static func cards() -> DesignCommentCards {
        let comment = DesignComment(id: LongThreads.commentID, number: 1, board: DesignPath("withdrawals-mobile-approve.dc.html")!, tid: 4, path: [1, 1],
                                    label: "Details", target: "Details and Claims", text: LongThreads.prompt,
                                    createdAt: ActivityThreads.now - 5 * 60_000)
        let cards = DesignCommentCards()
        cards.set(DesignScreenModel.cards([comment]))
        return cards
    }

    /// The report's thread as the host serves it: the viewer's pinned comment, and the agent's
    /// answer: prose, three boards updated by name, a call to a helper, a render and a search that
    /// failed, a read that failed on a long path, a failed request, a compaction, and the work that
    /// goes on after it.
    static var story: NativeThreadSnapshot {
        typealias L = LongThreads
        let t = ActivityThreads.now - 40 * 60_000
        func at(_ offset: Double) -> Double { t + offset }
        var messages: [NativeThreadMessage] = [
            L.user("u", L.prompt, at: at(0), origin: .designComment(id: L.commentID)),
            L.assistant("a1", L.paragraph, at: at(5_000)),
        ]
        messages += L.boards.enumerated().map { index, board in
            L.tool("e\(index)", "board_edit", ["path": "\(board).dc.html", "edits": [["find": "<div class=\"tabs\">", "replace": "<nav class=\"tabs\">"]]],
                   output: "Edited \(board).dc.html · 1 edit, 1 match\nTags balance, one root.", at: at(6_000 + Double(index) * 500))
        }
        messages += [
            L.tool("m1", "shepherd_child_message", ["id": L.childID, "message": "Update withdrawals-mobile-approve.dc.html: move Details and Claims into plain tabs."],
                   output: #"{"id":"\#(L.childID)","delivered":true,"queued":false,"state":"running"}"#, at: at(8_000)),
            L.tool("r1", "board_render", ["path": "withdrawals-mobile-approve.dc.html", "width": 390],
                   output: "no board at withdrawals-mobile-approve.dc.html: the canvas holds A.dc.html, B.dc.html and C.dc.html", error: true, at: at(9_000)),
            L.tool("s1", "board_search", ["text": "menuOpen|has-next-page|width:390px|<table|summary-row|claims-tab|details-tab", "regex": true],
                   output: "invalid regular expression: nothing to repeat at offset 61 in menuOpen|has-next-page", error: true, at: at(10_000)),
            L.tool("x1", "read", ["path": L.longPath], output: "ENOENT: no such file or directory, open '\(L.longPath)'", error: true, at: at(11_000)),
            L.failure("f1", #"429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization"},"request_id":"req_011CTwJkXq9P2cE8yM4s7nHdVb3Zs"}"#, at: at(12_000)),
            L.compaction("c1", reason: .threshold, at: at(20_000)),
            L.assistant("a2", "Picking up from the summary: the helpers have drawn the remaining boards, so I am checking each against the design system before I answer.", at: at(25_000)),
            L.tool("c2", "design_check", [:], output: "Checked against acme-web · 0 off-system values", at: at(26_000)),
            L.assistant("a3", "All boards check clean. Details and Claims are plain tabs on A, A · phone and the withdrawals boards.", at: at(30_000)),
        ]
        return ActivityThreads.snapshot(messages)
    }

    /// The rows are drawn four to a picture, so each stays short enough to read.
    nonisolated static let parts = [0, 1, 2, 3]
    static let partHeight: CGFloat = 3400

    /// One part of the kinds of row in `LongThreads`, each its own turn.
    static func everyRow(designChat: Bool, part: Int) -> NativeThreadSnapshot {
        let rows = LongThreads.rows
        let size = (rows.count + parts.count - 1) / parts.count
        var messages = LongThreads.conversation(Array(rows[(part * size)..<min(rows.count, (part + 1) * size)]), designChat: designChat)
        // A moment ago, so each turn's footer reads a time.
        let shift = ActivityThreads.now - 60 * 60_000 - LongThreads.start
        for index in messages.indices {
            messages[index].timestamp = messages[index].timestamp.map { $0 + shift }
            messages[index].startedAt = messages[index].startedAt.map { $0 + shift }
        }
        return ActivityThreads.snapshot(messages)
    }

    /// The chat as the design screen composes it (`designChat`), or an ordinary thread, `width` wide.
    static func chat(_ fixture: ThreadFixture, width: CGFloat, height: CGFloat, designChat: Bool = true) -> some View {
        ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview",
                   agentName: "Checkout funnel", workingDirectory: "~/Library/Application Support/Shepherd/designs/checkout",
                   inspectSubagent: { _ in }, review: { _ in }, designChat: designChat)
            .environment(\.threadCommands, fixture.commands)
            .environment(\.designCommentCards, designChat ? cards() : nil)
            .nwComposerSize(designChat ? .compact : .regular)
            .frame(width: width, height: height)
    }
}
