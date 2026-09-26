import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The design agent's tools against a real server: `shepherd-design.ts` reads and writes its
/// design over the extension socket, a write reaches the design's files and one broadcast, and
/// only the agent that draws the design may touch it.
@Suite("Design agent", .integrationTimeLimit)
struct DesignAgentTests {
    /// A space with a design, the agent that draws it, and an agent that doesn't.
    private func workspace(_ h: ScratchServer) async throws -> (design: DesignID, drawer: AgentID, stranger: AgentID) {
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", spaceID: space.id,
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

    @Test func onlyTheDrawingAgentReachesTheDesign() async throws {
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
