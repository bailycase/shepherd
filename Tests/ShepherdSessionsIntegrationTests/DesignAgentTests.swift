import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The design agent's tools against a real server: `shepherd-design.ts` reads and writes its
/// design over the extension socket, a write reaches the design's files and one broadcast, and
/// design agents remain scoped to their own design.
@Suite("Design agent", .integrationTimeLimit)
struct DesignAgentTests {
    /// A space with a design, its agent, and an agent scoped to a different design.
    private func workspace(_ h: ScratchServer) async throws -> (design: DesignID, drawer: AgentID, stranger: AgentID) {
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        var stranger = Fixture.agent(in: space, name: "another design agent")
        stranger.agent.designID = DesignID()
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel",
                                                   agentID: drawer.agent.id, createdAt: 1_000))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (designID, drawer.agent.id, stranger.agent.id)
    }

    @Test func anAgentsBoardWriteReachesTheFilesAndOneBroadcast() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designRead(id: 1, agentID: drawer, designID: design, path: nil))
        guard case .design(1, let before) = try await agent.reply() else { Issue.record("no snapshot"); return }
        #expect(before.index.title == "Checkout funnel" && before.boards.isEmpty)

        let board = DesignTests.board()
        try agent.send(.designWriteBoard(id: 2, agentID: drawer, designID: design, path: "A-phone.dc.html", source: board,
                                         baseRevision: before.revision))
        guard case .designWritten(2, let written) = try await agent.reply() else { Issue.record("no write result"); return }
        #expect(written.changed && written.created == true && written.revision == before.revision + 1)
        let url = try #require(h.server.designs.projectFolder(for: design)).appendingPathComponent("A-phone.dc.html")
        #expect(try String(contentsOf: url, encoding: .utf8) == board)

        try agent.send(.designUpdateIndex(id: 3, agentID: drawer, designID: design, changes: .object([
            "boards": .object(["A-phone.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844),
                                                           "title": .string("A · phone")])]),
        ]), baseRevision: written.revision))
        guard case .designWritten(3, let placed) = try await agent.reply() else { Issue.record("no index result"); return }
        #expect(placed.changed && placed.created == nil && placed.boardCount == 1)

        // Each write that changed the files broadcast once, the last with the board counted.
        try await eventually("both writes to broadcast") { h.broadcasts.current.count == 2 }
        #expect(h.broadcasts.current.last?.designs.first?.boardCount == 1)

        try agent.send(.designRead(id: 4, agentID: drawer, designID: design, path: "A-phone.dc.html"))
        guard case .designBoard(4, let read) = try await agent.reply() else { Issue.record("no board"); return }
        #expect(read.source == board && read.revision == placed.revision && read.sha256 == written.sha256)

        // A rewrite reads as an update.
        try agent.send(.designWriteBoard(id: 5, agentID: drawer, designID: design, path: "A-phone.dc.html",
                                         source: DesignTests.board(root: #"<div style="width: 390px; height: 844px">Bye</div>"#),
                                         baseRevision: nil))
        guard case .designWritten(5, let rewritten) = try await agent.reply() else { Issue.record("no rewrite result"); return }
        #expect(rewritten.changed && rewritten.created == false)
    }

    @Test func aWriteBasedOnAnOldRevisionIsRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)
        _ = try await h.server.writeDesignBoard(design, path: try DesignTests.path("A.dc.html"),
                                                source: DesignTests.board(), baseRevision: nil)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let files = DesignTests.contents(of: h.server.designs.projectFolder(for: design))

        try agent.send(.designWriteBoard(id: 1, agentID: drawer, designID: design, path: "B.dc.html", source: DesignTests.board(),
                                         baseRevision: 0))
        guard case .error(1, "stale_revision", let message) = try await agent.reply() else { Issue.record("a stale write went through"); return }
        #expect(message.contains("read it again"))
        try agent.send(.designUpdateIndex(id: 2, agentID: drawer, designID: design, changes: .object(["title": .string("Other")]),
                                          baseRevision: 0))
        guard case .error(2, "stale_revision", _) = try await agent.reply() else { Issue.record("a stale update went through"); return }

        await drainMainQueue()
        #expect(DesignTests.contents(of: h.server.designs.projectFolder(for: design)) == files)
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test func ordinaryThreadsCanListReadAndEditExplicitDesignsButNotSpeakAsTheirAgent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let design = DesignID()
        h.server.setDesignsServed(true)
        let worker = Fixture.agent(in: space, name: "implementation")
        try await h.seed(Fixture.workspace([worker], space: space))
        _ = try await h.server.createDesign(Design(id: design, name: "Checkout funnel", createdAt: 1_000))
        let client = try ExtensionClient(path: h.socketPath)
        try client.send(.designList(id: 1, agentID: worker.agent.id))
        guard case .designList(1, let listed) = try await client.reply() else { Issue.record("no designs"); return }
        #expect(listed.map(\.id) == [design])
        try client.send(.designRead(id: 2, agentID: worker.agent.id, designID: design, path: nil))
        guard case .design(2, let snapshot) = try await client.reply() else { Issue.record("no canvas"); return }
        try client.send(.designWriteBoard(id: 3, agentID: worker.agent.id, designID: design, path: "A.dc.html",
                                         source: DesignTests.board(), baseRevision: snapshot.revision))
        guard case .designWritten(3, let write) = try await client.reply() else { Issue.record("no write"); return }
        try client.send(.designEditBoard(id: 4, agentID: worker.agent.id, designID: design, path: "A.dc.html",
                                        edits: [.init(find: "<x-dc>", replace: "<x-dc>\n<!-- updated -->")],
                                        baseRevision: write.revision, tokens: nil))
        guard case .designEdited(4, _, _) = try await client.reply() else { Issue.record("no edit"); return }
        #expect(try await h.server.designBoard(design, path: DesignPath.validate("A.dc.html")).source.contains("<!-- updated -->"))
        try client.send(.designWriteBoard(id: 5, agentID: worker.agent.id, designID: design, path: "A.dc.html",
                                         source: DesignTests.board(), baseRevision: snapshot.revision))
        guard case .error(5, "stale_revision", _) = try await client.reply() else { Issue.record("stale write accepted"); return }
        try client.send(.designCommentReply(id: 6, agentID: worker.agent.id, designID: design, commentID: UUID().uuidString, text: "Done"))
        guard case .error(6, "not_your_design", _) = try await client.reply() else { Issue.record("thread spoke as design agent"); return }
        try client.send(.designProposeComments(id: 10, agentID: worker.agent.id, designID: design, call: "proposal", proposals: []))
        guard case .error(10, "not_your_design", _) = try await client.reply() else { Issue.record("thread proposed as design agent"); return }
        let build = DesignID()
        _ = try await h.server.createDesign(Design(id: build, name: "System build", createdAt: 1_000, buildsSystem: true, sourceSpaceID: space.id))
        try client.send(.designList(id: 11, agentID: worker.agent.id))
        guard case .designList(11, let canvases) = try await client.reply() else { Issue.record("no canvases"); return }
        #expect(canvases.map(\.id) == [design])
        try client.send(.designRead(id: 12, agentID: worker.agent.id, designID: build, path: nil))
        guard case .error(12, "not_your_design", _) = try await client.reply() else { Issue.record("thread read system build"); return }
        let renderReply = Locked<((Result<DesignRendered, DesignRenderFailure>) -> Void)?>(nil)
        h.server.onDesignRender = { _, respond in renderReply.withValue { $0 = respond } }
        try client.send(.designRender(id: 13, agentID: worker.agent.id, designID: design, request: .init(path: "A.dc.html")))
        try await eventually("the ordinary thread's render") { renderReply.current != nil }
        await #expect(throws: DesignGitError.agentWorking) {
            try await h.server.commitDesign(design, message: "during design operation", push: false)
        }
        renderReply.current?(.success(.init(image: BrowserImage(data: "iVBORw0KGgo=", mimeType: "image/png"), text: "rendered")))
        guard case .designRendered(13, _, _) = try await client.reply() else { Issue.record("render did not finish"); return }
        h.server.setDesignsServed(false)
        try client.send(.designList(id: 7, agentID: worker.agent.id))
        guard case .error(7, "design_disabled", _) = try await client.reply() else { Issue.record("listed with experiment off"); return }
        try client.send(.designRead(id: 8, agentID: worker.agent.id, designID: design, path: nil))
        guard case .error(8, "design_disabled", _) = try await client.reply() else { Issue.record("read with experiment off"); return }
        h.server.setDesignsServed(true)
        h.server.extensionPeerCheck = { _, _ in false }
        try client.send(.designList(id: 9, agentID: worker.agent.id))
        guard case .error(9, "wrong_process", _) = try await client.reply() else { Issue.record("unauthenticated listing"); return }
    }

    @Test func automationRunsCannotUseLiveDesignTools() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var space = Fixture.space()
        space.hidden = true
        let run = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([run], space: space))
        h.server.setDesignsServed(true)
        let design = DesignID()
        _ = try await h.server.createDesign(Design(id: design, name: "Checkout", createdAt: 1_000))
        let client = try ExtensionClient(path: h.socketPath)
        try client.send(.designList(id: 1, agentID: run.agent.id))
        guard case .error(1, "not_a_thread", _) = try await client.reply() else { Issue.record("automation listed designs"); return }
        try client.send(.designRead(id: 2, agentID: run.agent.id, designID: design, path: nil))
        guard case .error(2, "not_your_design", _) = try await client.reply() else { Issue.record("automation read design"); return }
    }

    @Test func designAgentsCannotReachOtherDesigns() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, stranger) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)
        let board = DesignTests.board()

        try agent.send(.designWriteBoard(id: 1, agentID: stranger, designID: design, path: "A.dc.html", source: board, baseRevision: nil))
        guard case .error(1, "not_your_design", _) = try await agent.reply() else { Issue.record("another agent wrote"); return }
        try agent.send(.designRead(id: 2, agentID: stranger, designID: design, path: nil))
        guard case .error(2, "not_your_design", _) = try await agent.reply() else { Issue.record("another agent read"); return }
        try agent.send(.designRead(id: 3, agentID: AgentID(), designID: design, path: nil))
        guard case .error(3, "no_such_agent", _) = try await agent.reply() else { Issue.record("a stranger read"); return }
        try agent.send(.designRead(id: 4, agentID: drawer, designID: DesignID(), path: nil))
        guard case .error(4, "not_your_design", _) = try await agent.reply() else { Issue.record("another design was read"); return }

        await drainMainQueue()
        #expect(DesignTests.contents(of: h.server.designs.projectFolder(for: design)).keys.sorted() == ["canvas.json"])
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test func badBoardsAndPathsAreAnsweredNotDropped() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designWriteBoard(id: 1, agentID: drawer, designID: design, path: "../escape.dc.html", source: DesignTests.board(),
                                         baseRevision: nil))
        guard case .error(1, "invalid_path", _) = try await agent.reply() else { Issue.record("a bad path went through"); return }
        try agent.send(.designRead(id: 2, agentID: drawer, designID: design, path: "notes.txt"))
        guard case .error(2, "invalid_path", _) = try await agent.reply() else { Issue.record("a bad read went through"); return }
        try agent.send(.designWriteBoard(id: 3, agentID: drawer, designID: design, path: "A.dc.html",
                                         source: DesignTests.board(extra: "<iframe src=\"https://example.com\"></iframe>"), baseRevision: nil))
        guard case .error(3, "forbidden_tag", _) = try await agent.reply() else { Issue.record("an iframe went through"); return }
        try agent.send(.designRead(id: 4, agentID: drawer, designID: design, path: "Missing.dc.html"))
        guard case .error(4, "no_such_board", _) = try await agent.reply() else { Issue.record("a missing board was read"); return }
        try agent.send(.designUpdateIndex(id: 5, agentID: drawer, designID: design, changes: .object([
            "boards": .object(["Missing.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])]),
        ]), baseRevision: nil))
        guard case .error(5, "missing_board_file", _) = try await agent.reply() else { Issue.record("a frame without a file"); return }

        // The connection still serves.
        try agent.send(.designRead(id: 6, agentID: drawer, designID: design, path: nil))
        guard case .design(6, _) = try await agent.reply() else { Issue.record("the connection stopped serving"); return }
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)
    }
}
