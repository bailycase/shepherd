import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Comments on a design against a real server: kept in the design's comments.json with their own
/// revision, found again when a rewrite moves their element, handed to the design agent as a
/// queued turn of their own (never into the turn it is working on), answered under the pin by the
/// agent's `comment_reply`, and resolved only by the viewer.
@Suite("Design comments", .integrationTimeLimit)
struct DesignCommentIntegrationTests {
    static let board = DesignPath("A.dc.html")!
    /// `helmet` (0), its `style` (1), then the card (2, `1`) holding a title (3, `1/0`) and a
    /// total (4, `1/1`).
    static let card = #"<div data-el="Checkout funnel" style="width: 390px; height: 844px"><h2>Checkout funnel</h2><p>48,210 people</p></div>"#

    static func draft(tid: Int = 4, path: [Int] = [1, 1], text: String = "Show the absolute counts next to the percentages.") -> DesignCommentDraft {
        DesignCommentDraft(board: board, tid: tid, path: path, label: "whatever the client says", target: "Checkout funnel",
                           rect: DesignCommentRect(x: 0, y: 40, w: 390, h: 20), text: text)
    }

    /// A design drawn by `agentID`, with board A placed on its canvas.
    private func design(_ h: ScratchServer, space: SpaceID, agentID: AgentID?) async throws -> DesignID {
        let id = DesignID()
        _ = try await h.server.createDesign(Design(id: id, name: "Checkout funnel", spaceID: space, agentID: agentID, createdAt: 1_000))
        _ = try await h.server.writeDesignBoard(id, path: Self.board, source: DesignTests.board(root: Self.card))
        _ = try await h.server.updateDesignIndex(id, patch: .object(["boards": .object([Self.board.rawValue: .object([
            "x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844), "title": .string("A · Funnel first"),
        ])])]))
        return id
    }

    private func prompts(_ pi: PiAgent) -> [String] {
        pi.stdin("prompt").compactMap { $0["message"] as? String }
    }

    // MARK: Delivery

    @Test func aCommentMadeWhileTheAgentWorksWaitsForItsTurnThenGoesFenced() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, space: pi.agent.spaceID, agentID: pi.agent.id)
        _ = try await pi.send("tools:1 build", from: try await pi.ready())
        _ = try await pi.snapshot("the first tool call to run") { s in
            s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" }
        }

        let outcome = try await h.server.addDesignComment(designID, draft: Self.draft(text: "tools:0 Show the counts."))
        #expect(outcome.undelivered == nil)
        let comment = outcome.comment
        #expect(comment.number == 1 && comment.tid == 4 && comment.path == [1, 1])
        #expect(comment.label == "48,210 people", "the words are the server's reading of the board, not the client's")

        // It waits in the queue as typed: the turn pi is working on doesn't take it.
        let queued = try await pi.snapshot("the comment in the queue") { $0.queue?.items.map(\.id) == [comment.id] }
        #expect(queued.queue?.items.first?.text == "tools:0 Show the counts.")
        #expect(queued.running)
        #expect(prompts(pi).count == 1, "nothing was steered into the running turn")

        pi.finishTool(1)
        let done = try await pi.snapshot("the comment's turn to settle") { s in
            !s.running && s.queue?.items.isEmpty == true && s.messages.contains { $0.origin?.designComment == comment.id }
                && s.messages.last?.role == "assistant"
        }
        let prompt = try #require(prompts(pi).last)
        let parsed = try #require(DesignCommentFence.parse(prompt))
        #expect(parsed.fence == DesignCommentFence(comment))
        #expect(parsed.text == "tools:0 Show the counts.")
        let message = try #require(done.messages.first { $0.origin?.designComment == comment.id })
        #expect(message.blocks.map(\.text) == ["tools:0 Show the counts."], "the thread shows the viewer's words")
        #expect(message.role == "user")

        // A reply under the pin goes the same way, as words alone in the thread.
        let reply = try await h.server.replyToDesignComment(designID, commentID: comment.id, text: "tools:0 And the phone.")
        #expect(reply.undelivered == nil && reply.comment.replies.map(\.author) == [.user])
        let answered = try await pi.snapshot("the reply's turn to settle") { s in
            !s.running && s.messages.contains { $0.role == "user" && $0.blocks.map(\.text) == ["tools:0 And the phone."] }
                && s.messages.last?.role == "assistant"
        }
        let replyMessage = try #require(answered.messages.last { $0.role == "user" })
        #expect(replyMessage.origin?.designComment == nil)
        #expect(DesignCommentFence.parse(try #require(prompts(pi).last))?.fence.reply == true)
    }

    /// Words that start with "/" are a comment, never a command: pi gets them behind the fence.
    @Test func aCommentStartingWithASlashStillGoesFenced() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let designID = try await design(h, space: pi.agent.spaceID, agentID: pi.agent.id)
        _ = try await pi.ready()

        let outcome = try await h.server.addDesignComment(designID, draft: Self.draft(text: "/tighten the header tools:0"))
        #expect(outcome.undelivered == nil)
        _ = try await pi.snapshot("the comment's turn to settle") { s in
            !s.running && s.messages.contains { $0.origin?.designComment == outcome.comment.id }
                && s.messages.last?.role == "assistant"
        }
        let prompt = try #require(prompts(pi).last)
        let parsed = try #require(DesignCommentFence.parse(prompt))
        #expect(parsed.fence.comment == outcome.comment.id)
        #expect(parsed.text == "/tighten the header tools:0")
    }

    @Test func aCommentWithoutAnAgentToTakeItIsKeptAndSaysWhy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, space: space.id, agentID: nil)
        let outcome = try await h.server.addDesignComment(designID, draft: Self.draft())
        #expect(outcome.undelivered == "The design has no agent.")
        #expect(try await h.server.designComments(designID).comments == [outcome.comment])
    }

    // MARK: The agent's reply

    @Test func theAgentsReplyAttachesUnderItsPin() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", spaceID: space.id, createdAt: 1_000))
        _ = try await h.server.writeDesignBoard(designID, path: Self.board, source: DesignTests.board(root: Self.card))
        _ = try await h.server.updateDesignIndex(designID, patch: .object(["boards": .object([Self.board.rawValue: .object([
            "x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))
        let comment = try await h.server.addDesignComment(designID, draft: Self.draft()).comment
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designComments(id: 1, agentID: drawer.agent.id, designID: designID))
        guard case .designComments(1, let listed) = try await agent.reply() else { Issue.record("no comments"); return }
        #expect(listed.comments.map(\.id) == [comment.id])

        try agent.send(.designCommentReply(id: 2, agentID: drawer.agent.id, designID: designID, commentID: comment.id.uuidString,
                                           text: "Done on A and A · phone."))
        guard case .designComment(2, let replied) = try await agent.reply() else { Issue.record("no reply"); return }
        #expect(replied.replies.map(\.author) == [.agent] && replied.replies.map(\.text) == ["Done on A and A · phone."])
        #expect(replied.isOpen, "a reply never resolves")

        // It is in comments.json, where the canvas reads it.
        let file = try #require(h.server.designs.folder(for: designID)).appendingPathComponent("comments.json")
        let saved = try JSONDecoder().decode(DesignComments.self, from: Data(contentsOf: file))
        #expect(saved.comments.first?.replies.last?.text == "Done on A and A · phone.")
        #expect(try await h.server.designComments(designID) == saved)

        try agent.send(.designCommentReply(id: 3, agentID: drawer.agent.id, designID: designID, commentID: "nope", text: "x"))
        guard case .error(3, "no_such_comment", _) = try await agent.reply() else { Issue.record("a bad id answered"); return }
        try agent.send(.designCommentReply(id: 4, agentID: stranger.agent.id, designID: designID, commentID: comment.id.uuidString,
                                           text: "x"))
        guard case .error(4, "not_your_design", _) = try await agent.reply() else { Issue.record("a stranger replied"); return }
    }

    // MARK: The store

    @Test func commentsKeepTheirOwnRevisionAndOnlyTheViewerResolves() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, space: space.id, agentID: nil)
        let before = try await h.server.designSnapshot(designID).revision

        let first = try await h.server.addDesignComment(designID, draft: Self.draft(), baseRevision: 0).comment
        #expect(try await h.server.designSnapshot(designID).revision == before, "a comment never makes a board write stale")
        await #expect(throws: DesignStoreError.stale(base: 0, current: 1)) {
            try await h.server.addDesignComment(designID, draft: Self.draft(), baseRevision: 0)
        }
        let second = try await h.server.addDesignComment(designID, draft: Self.draft(tid: 3, path: [1, 0], text: "Bigger"), baseRevision: 1).comment
        #expect(second.number == 2 && second.label == "Checkout funnel")

        let resolved = try await h.server.resolveDesignComment(designID, commentID: first.id)
        #expect(!resolved.isOpen)
        let all = try await h.server.designComments(designID)
        #expect(all.revision == 3 && all.open.map(\.id) == [second.id])
        #expect(try await h.server.resolveDesignComment(designID, commentID: first.id, resolved: false).isOpen)

        // Numbers keep counting past resolved comments.
        _ = try await h.server.resolveDesignComment(designID, commentID: second.id)
        #expect(try await h.server.addDesignComment(designID, draft: Self.draft()).comment.number == 3)
    }

    static let refusedDrafts: [(String, DesignCommentDraft, String)] = [
        ("an element the board doesn't have", draft(tid: 40, path: [1, 9]), "invalid_comment"),
        ("a tid and path that disagree", draft(tid: 4, path: [1, 0]), "invalid_comment"),
        ("blank words", draft(text: " \n "), "invalid_comment"),
        ("a board with no frame", DesignCommentDraft(board: DesignPath("B.dc.html")!, tid: 0, path: [0], text: "Hi"), "no_such_board"),
    ]

    @Test(arguments: refusedDrafts)
    func aCommentOnNothingTheBoardDrawsIsRefused(_ name: String, _ draft: DesignCommentDraft, _ code: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, space: space.id, agentID: nil)
        do {
            _ = try await h.server.addDesignComment(designID, draft: draft)
            Issue.record("\(name) was kept")
        } catch let error as DesignStoreError {
            #expect(error.code == code, "\(name)")
        }
        #expect(try await h.server.designComments(designID).comments.isEmpty)
    }

    @Test func aRewriteReanchorsItsCommentsAndARemovedBoardDetachesThem() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, space: space.id, agentID: nil)
        let comment = try await h.server.addDesignComment(designID, draft: Self.draft()).comment

        // A badge drawn ahead of the total moves it to 1/2 and tid 5.
        let moved = #"<div data-el="Checkout funnel" style="width: 390px; height: 844px"><h2>Checkout funnel</h2><span>New</span><p>48,210 people</p></div>"#
        _ = try await h.server.writeDesignBoard(designID, path: Self.board, source: DesignTests.board(root: moved))
        var now = try #require(try await h.server.designComments(designID).comments.first)
        #expect(now.id == comment.id && now.tid == 5 && now.path == [1, 2] && !now.detached)

        // Its words changed where it stands: it stays.
        let edited = moved.replacingOccurrences(of: "48,210 people", with: "48,210 people · 100%")
        _ = try await h.server.writeDesignBoard(designID, path: Self.board, source: DesignTests.board(root: edited))
        now = try #require(try await h.server.designComments(designID).comments.first)
        #expect(now.tid == 5 && now.path == [1, 2] && !now.detached)

        // The board leaves the canvas: the comment detaches where it was.
        _ = try await h.server.updateDesignIndex(designID, patch: .object(["boards": .object([Self.board.rawValue: .null])]))
        now = try #require(try await h.server.designComments(designID).comments.first)
        #expect(now.detached && now.tid == 5 && now.path == [1, 2])
    }

    @Test func commentsOutliveTheStoreThatWroteThem() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([], space: space))
        let designID = try await design(h, space: space.id, agentID: nil)
        let comment = try await h.server.addDesignComment(designID, draft: Self.draft()).comment
        let reread = DesignStore(directory: h.server.designs.directory)
        let comments = try await reread.comments(designID)
        #expect(comments.comments == [comment] && comments.revision == 1)
    }
}
