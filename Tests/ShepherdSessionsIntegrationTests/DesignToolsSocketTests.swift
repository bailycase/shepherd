import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The batch tools over the extension socket, as the design extension sends them: only the agent
/// that draws the design is served, every failure is answered with its code, and the connection
/// keeps serving.
@Suite("Design agent tools over the socket", .integrationTimeLimit)
struct DesignToolsSocketTests {
    typealias T = DesignToolsStoreTests

    private func workspace(_ h: ScratchServer) async throws -> (design: DesignID, drawer: AgentID, stranger: AgentID) {
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", agentID: drawer.agent.id, createdAt: 1_000))
        _ = try await h.server.writeDesignBoards(designID, sources: [T.a: T.chips(), T.b: T.chips()])
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (designID, drawer.agent.id, stranger.agent.id)
    }

    @Test func anAgentEditsManyBoardsAndSearchesAndSavesACheckpointOverTheSocket() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designSearch(id: 1, agentID: drawer, designID: design, query: DesignSearchQuery(text: "Pay now", scope: .text)))
        guard case .designSearchResult(1, let found) = try await agent.reply() else { Issue.record("no search result"); return }
        #expect(found.boards.map(\.path) == ["A.dc.html", "B.dc.html"] && found.totalMatches == 4)

        try agent.send(.designCheckpoint(id: 2, agentID: drawer, designID: design, request: DesignCheckpointRequest(action: .create, name: "before")))
        guard case .designCheckpoints(2, let created) = try await agent.reply() else { Issue.record("no checkpoint"); return }
        #expect(created.checkpoint?.name == "before" && created.checkpoint?.boards == 2)

        try agent.send(.designEditBoards(id: 3, agentID: drawer, designID: design, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html"), .init(path: "B.dc.html"), .init(path: "C.dc.html")],
            edits: [DesignBoardEdit(find: "Pay now", replace: "Buy now", all: true)])))
        guard case .designBatchEdited(3, let batch) = try await agent.reply() else { Issue.record("no batch result"); return }
        #expect(batch.boards.map(\.status) == [.edited, .edited, .missing] && batch.result.changed)

        try agent.send(.designCheckpoint(id: 4, agentID: drawer, designID: design, request: DesignCheckpointRequest(action: .restore, name: "before")))
        guard case .designCheckpoints(4, let restored) = try await agent.reply() else { Issue.record("no restore"); return }
        #expect(restored.restored == ["A.dc.html", "B.dc.html"] && restored.automatic != nil && restored.write?.changed == true)

        try agent.send(.designCheckpoint(id: 5, agentID: drawer, designID: design, request: DesignCheckpointRequest(action: .list)))
        guard case .designCheckpoints(5, let listed) = try await agent.reply() else { Issue.record("no list"); return }
        #expect(listed.checkpoints.map(\.name) == ["before", "before restore before"])
    }

    @Test func theWriteToolsTakeATokensModeAndAnswerWithAReport() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let tokens: JSONValue = .object(["format": .string(DesignSystemTokens.format), "name": .string("acme"),
                                         "colors": .array([.object(["name": .string("--accent"), "value": .string("#3056d3")])]),
                                         "spacing": .array([.object(["name": .string("--space-3"), "px": .number(12)])])])
        _ = try await h.server.writeDesignSystem(DesignSystemWrite(namespace: "acme", tokens: tokens, install: true), for: design)
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designWriteBoard(id: 1, agentID: drawer, designID: design, path: "C.dc.html",
                                         source: T.board(#"<p style="color: #3a56d4">Hi</p>"#), baseRevision: nil, tokens: .strict))
        guard case .error(1, let code, let message) = try await agent.reply() else { Issue.record("strict wrote off-system values"); return }
        #expect(code == "tokens_off_system" && message.contains("#3a56d4"))

        try agent.send(.designWriteBoard(id: 2, agentID: drawer, designID: design, path: "C.dc.html",
                                         source: T.board(#"<p style="color: #3a56d4">Hi</p>"#), baseRevision: nil, tokens: .snap))
        guard case .designWritten(2, let written) = try await agent.reply() else { Issue.record("no write"); return }
        #expect(written.report?.snapped.map(\.to) == ["var(--accent)"] && written.report?.created == true)

        try agent.send(.designEditBoard(id: 3, agentID: drawer, designID: design, path: "C.dc.html",
                                        edits: [DesignBoardEdit(find: ">Hi<", replace: ">Hello<")], baseRevision: nil, tokens: nil))
        guard case .designEdited(3, let edited, _) = try await agent.reply() else { Issue.record("no edit"); return }
        #expect(edited.report?.diff?.lines.count == 2 && edited.report?.offSystem.isEmpty == true)
    }

    @Test func onlyTheDrawingAgentIsServedAndEveryFailureIsAnsweredWithItsCode() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, stranger) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)
        let project = DesignTests.contents(of: h.server.designs.projectFolder(for: design))
        let edit = DesignBoardEdit(find: "Pay", replace: "Buy")

        let cases: [(Int, ExtensionMessage, String)] = [
            (10, .designEditBoards(id: 10, agentID: stranger, designID: design, request: DesignBatchEditRequest(boards: [.init(path: "A.dc.html")], edits: [edit])), "not_your_design"),
            (11, .designSearch(id: 11, agentID: stranger, designID: design, query: DesignSearchQuery(text: "Pay")), "not_your_design"),
            (12, .designCheckpoint(id: 12, agentID: stranger, designID: design, request: DesignCheckpointRequest(action: .create, name: "x")), "not_your_design"),
            (13, .designRender(id: 13, agentID: stranger, designID: design, request: DesignRenderRequest(path: "A.dc.html")), "not_your_design"),
            (14, .designEditBoards(id: 14, agentID: drawer, designID: DesignID(), request: DesignBatchEditRequest(boards: [.init(path: "A.dc.html")], edits: [edit])), "not_your_design"),
            (15, .designEditBoards(id: 15, agentID: drawer, designID: design, request: DesignBatchEditRequest(boards: [], edits: [edit])), "invalid_edit"),
            (16, .designSearch(id: 16, agentID: drawer, designID: design, query: DesignSearchQuery()), "invalid_search"),
            (17, .designCheckpoint(id: 17, agentID: drawer, designID: design, request: DesignCheckpointRequest(action: .restore, name: "nope")), "no_such_checkpoint"),
            (18, .designCheckpoint(id: 18, agentID: drawer, designID: design, request: DesignCheckpointRequest(action: .create, name: "../x")), "invalid_checkpoint"),
            (19, .designRender(id: 19, agentID: drawer, designID: design, request: DesignRenderRequest(path: "../x.dc.html")), "invalid_path"),
            (20, .designRender(id: 20, agentID: drawer, designID: design, request: DesignRenderRequest(path: "Missing.dc.html")), "no_such_board"),
            (21, .designRender(id: 21, agentID: drawer, designID: design, request: DesignRenderRequest(path: "A.dc.html", width: 5)), "invalid_render"),
            (22, .designRender(id: 22, agentID: drawer, designID: design, request: DesignRenderRequest(path: "A.dc.html")), "render_unavailable"),
        ]
        for (id, message, code) in cases {
            try agent.send(message)
            guard case .error(let answered, let got, _) = try await agent.reply(), answered == id, got == code else {
                Issue.record("message \(id) was not answered \(code)"); continue
            }
        }
        try agent.send(.designRead(id: 30, agentID: drawer, designID: design, path: nil))
        guard case .design(30, _) = try await agent.reply() else { Issue.record("the connection stopped serving"); return }
        #expect(DesignTests.contents(of: h.server.designs.projectFolder(for: design)) == project, "nothing was written")
    }

    // MARK: board_render

    private func png() -> BrowserImage { BrowserImage(data: "iVBORw0KGgo=", mimeType: "image/png") }

    @Test func aRenderGoesToTheAppWithTheBoardsFilesAndComesBackAsAnImage() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let job = Locked<DesignRenderJob?>(nil)
        h.server.onDesignRender = { request, respond in
            job.withValue { $0 = request }
            respond(.success(DesignRendered(image: BrowserImage(data: "iVBORw0KGgo=", mimeType: "image/png"), text: "A.dc.html · 390×844 at 2x")))
        }
        let agent = try ExtensionClient(path: h.socketPath)
        try agent.send(.designRender(id: 1, agentID: drawer, designID: design, request: DesignRenderRequest(
            path: "A.dc.html", width: 390, scale: 2, props: .object(["density": .string("compact")]))))
        guard case .designRendered(1, let text, let image) = try await agent.reply() else { Issue.record("no picture"); return }
        #expect(text == "A.dc.html · 390×844 at 2x" && image == png())
        let seen = try #require(job.current)
        #expect(seen.designID == design && seen.path == T.a && seen.request.scale == 2 && seen.request.props == .object(["density": .string("compact")]))
        #expect(seen.files.boards == [T.a] && seen.files.sources[T.a]?.contains("Pay now") == true, "the files the renderer needs, read by the host")
    }

    @Test func aRenderTheAppRefusesIsAnsweredWithItsOwnCodeAndWords() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        h.server.onDesignRender = { _, respond in
            respond(.failure(DesignRenderFailure(code: "render_failed", message: "A.dc.html couldn't be drawn: the board never booted")))
        }
        let agent = try ExtensionClient(path: h.socketPath)
        try agent.send(.designRender(id: 1, agentID: drawer, designID: design, request: DesignRenderRequest(path: "A.dc.html")))
        guard case .error(1, let code, let message) = try await agent.reply() else { Issue.record("no error"); return }
        #expect(code == "render_failed" && message.contains("never booted"))
    }

    @Test func aRenderThatNeverComesBackTimesOutAndALateAnswerIsIgnored() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        h.server.designRenderDeadline = 0.2
        let late = Locked<((Result<DesignRendered, DesignRenderFailure>) -> Void)?>(nil)
        h.server.onDesignRender = { _, respond in late.withValue { $0 = respond } }
        let agent = try ExtensionClient(path: h.socketPath)
        try agent.send(.designRender(id: 1, agentID: drawer, designID: design, request: DesignRenderRequest(path: "A.dc.html")))
        guard case .error(1, let code, let message) = try await agent.reply() else { Issue.record("no error"); return }
        #expect(code == "timeout" && message.contains("not drawn"))
        late.current?(.success(DesignRendered(image: png(), text: "too late")))
        try agent.send(.designRead(id: 2, agentID: drawer, designID: design, path: nil))
        guard case .design(2, _) = try await agent.reply() else { Issue.record("the late answer was not ignored"); return }
    }
}
