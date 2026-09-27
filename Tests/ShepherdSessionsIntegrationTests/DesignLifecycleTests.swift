import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Deleting a design with Undo, duplicating one, Remove from Recents, and deleting a design
/// system (docs/designs.md › Deleting and importing): each a `SessionServer` mutation that
/// commits and broadcasts once, and leaves the files it promises to leave.
@Suite("Design lifecycle", .integrationTimeLimit)
struct DesignLifecycleTests {
    /// A server with a worker thread, and a design drawn by an agent whose pane runs a shell.
    private struct Drawn {
        let h: ScratchServer
        let design: Design
        let worker: Agent
        let drawer: Agent
        let tab: ShepherdCore.Tab
        let session: SessionID
        let callbacks: Callbacks
    }

    private func drawnDesign(window: TimeInterval = 60, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Drawn {
        let h = try ScratchServer.fresh()
        h.server.designUndoWindow = window
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let design = Design(name: "Checkout funnel dashboard", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        _ = try await h.server.writeDesignBoard(design.id, path: DesignPath("A.dc.html")!, source: DesignTests.board())
        let callbacks = Callbacks(h.server)
        let session = try await h.shell("sleep 30")
        let designs = try await h.server.designsSpaceID()
        let agentID = AgentID()
        let pane = LeafPane(sessionID: session.id, cwd: h.dir.path, agentID: agentID)
        let tab = ShepherdCore.Tab(spaceID: designs, order: 1, layout: .leaf(pane))
        let drawer = Agent(id: agentID, name: design.name, spaceID: designs, tabID: tab.id, paneID: pane.id, designID: design.id)
        var state = h.server.state
        state.tabs.append(tab)
        state.agents.append(drawer)
        try await h.server.putState(state)
        try await h.server.setDesignAgent(design.id, agentID: agentID)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return Drawn(h: h, design: try #require(h.server.state.designs.first { $0.id == design.id }, sourceLocation: sourceLocation),
                     worker: worker.agent, drawer: drawer, tab: tab, session: session.id, callbacks: callbacks)
    }

    private func committed(_ h: ScratchServer, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ShepherdState {
        await drainMainQueue()
        let state = h.server.state
        #expect(try h.persisted() == state.persisted, "state.json matches memory", sourceLocation: sourceLocation)
        #expect(h.broadcasts.current == [state], "one broadcast of the committed state", sourceLocation: sourceLocation)
        h.broadcasts.withValue { $0.removeAll() }
        return state
    }

    private func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: Delete and Undo

    /// Delete takes the design and the agent that drew it out of every surface at once, stops
    /// its process, and sets its folder aside; the thread beside it stays.
    @Test func deletingADesignTakesItAndItsAgentAwayAtOnce() async throws {
        let d = try await drawnDesign()
        defer { d.h.stop() }

        let deletion = try await d.h.server.deleteDesign(d.design.id)

        #expect(deletion.designID == d.design.id && deletion.name == "Checkout funnel dashboard")
        #expect(deletion.undoUntil > Date().timeIntervalSince1970 * 1000)
        let state = try await committed(d.h)
        #expect(state.designs.isEmpty)
        #expect(state.agents.map(\.id) == [d.worker.id], "the design's agent goes; the thread stays")
        #expect(!state.tabs.contains { $0.id == d.tab.id })
        try await eventually("the design agent's process to stop") { d.callbacks.exited(d.session) }
        #expect(!exists(d.h.server.designs.folder(for: d.design.id)), "nothing serves it now")
        #expect(exists(d.h.server.designs.stagedFolder(for: d.design.id)), "its files wait out the undo window")
        #expect(await d.h.server.pendingDesignDeletionIDs() == [d.design.id])
        await #expect(throws: SessionServerError.self) { try await d.h.server.designSnapshot(d.design.id) }
        let again = await #expect(throws: SessionServerError.self) { try await d.h.server.deleteDesign(d.design.id) }
        #expect(again?.description == SessionServerError.noSuchDesign(d.design.id).description)
    }

    /// Undo within the window brings everything back where it was: the record, its agent and
    /// layout (a fresh pane with no session, so the app starts a new pi on the agent's own
    /// session), and its files.
    @Test func undoWithinTheWindowRestoresTheDesignItsAgentAndItsPlace() async throws {
        let d = try await drawnDesign()
        defer { d.h.stop() }
        let before = d.h.server.state
        let board = try await d.h.server.designSnapshot(d.design.id).boards
        _ = try await d.h.server.deleteDesign(d.design.id)
        _ = try await committed(d.h)

        try await d.h.server.undoDesignDeletion(d.design.id)

        let state = try await committed(d.h)
        #expect(d.callbacks.exited(d.session), "the old process ended before the agent came back")
        #expect(state.designs == before.designs, "the design, its agent and its place in the list")
        #expect(state.agents.map(\.id) == before.agents.map(\.id))
        let agent = try #require(state.agents.first { $0.id == d.drawer.id })
        #expect(agent.designID == d.design.id && agent.tabID == d.tab.id)
        let tab = try #require(state.tabs.first { $0.id == d.tab.id })
        #expect(state.tabs.map(\.id) == before.tabs.map(\.id))
        #expect(agent.paneID == tab.layout.firstLeaf.id && agent.paneID != d.drawer.paneID, "a fresh pane")
        #expect(tab.layout.firstLeaf.sessionID == nil && tab.layout.firstLeaf.agentID == d.drawer.id)
        #expect(try await d.h.server.designSnapshot(d.design.id).boards == board, "its boards are back")
        #expect(!exists(d.h.server.designs.stagedFolder(for: d.design.id)))
        #expect(await d.h.server.pendingDesignDeletionIDs().isEmpty)
    }

    /// After the window the files are gone, and Undo is refused, leaving nothing behind.
    @Test func afterTheWindowTheFilesAreRemovedAndUndoIsRefused() async throws {
        let d = try await drawnDesign(window: 0.2)
        defer { d.h.stop() }
        _ = try await d.h.server.deleteDesign(d.design.id)
        _ = try await committed(d.h)

        try await eventually("the undo window to close") { await d.h.server.pendingDesignDeletionIDs().isEmpty }
        try await eventually("the set-aside folder to go") { !exists(d.h.server.designs.stagedFolder(for: d.design.id)) }
        let state = d.h.server.state

        await #expect(throws: SessionServerError.self) { try await d.h.server.undoDesignDeletion(d.design.id) }
        #expect(d.h.server.state == state)
        #expect(!exists(d.h.server.designs.folder(for: d.design.id)))
    }

    /// Quitting within the window completes the deletion: state.json has no design, and the next
    /// launch has neither the design nor its files.
    @Test func quittingWithinTheWindowCompletesTheDeletion() async throws {
        let d = try await drawnDesign()
        _ = try await d.h.server.deleteDesign(d.design.id)
        d.h.stop(keepFiles: true)
        #expect(!exists(d.h.server.designs.stagedFolder(for: d.design.id)), "quitting removes what was set aside")

        let h = try ScratchServer(dir: d.h.dir)
        defer { h.stop() }
        #expect(h.server.state.designs.isEmpty)
        #expect(!h.server.state.agents.contains { $0.id == d.drawer.id })
        #expect(!exists(h.server.designs.folder(for: d.design.id)))
        await #expect(throws: SessionServerError.self) { try await h.server.undoDesignDeletion(d.design.id) }
    }

    /// After a crash in the window, launch removes the folder the deletion set aside.
    @Test func launchRemovesFoldersADeletionSetAside() async throws {
        let first = try ScratchServer.fresh()
        let design = Design(name: "Lost", createdAt: 1)
        _ = try await first.server.createDesign(design)
        first.stop(keepFiles: true)
        // As a crash leaves it: the folder set aside, the record already gone from state.json.
        let folder = try #require(first.server.designs.folder(for: design.id))
        let staged = try #require(first.server.designs.stagedFolder(for: design.id))
        try FileManager.default.moveItem(at: folder, to: staged)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        #expect(!exists(staged))
    }

    // MARK: Duplicate and Remove from Recents

    @Test func duplicatingADesignCopiesItsBoardsUnderANewIDAndName() async throws {
        let d = try await drawnDesign()
        defer { d.h.stop() }
        _ = try await d.h.server.updateDesignIndex(d.design.id, patch: .object(["boards": .object(["A.dc.html": .object([
            "x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))
        _ = try await d.h.server.addDesignComment(d.design.id, draft: DesignCommentDraft(board: DesignPath("A.dc.html")!, tid: 2, path: [1],
                                                                                          label: "Hi", target: "Hi", rect: nil, text: "Bigger"))
        _ = try await d.h.server.writeDesignBoard(d.design.id, path: DesignPath("A.dc.html")!, source: DesignTests.board(extra: "<p>2</p>"))
        await drainMainQueue()
        d.h.broadcasts.withValue { $0.removeAll() }

        let copy = try await d.h.server.duplicateDesign(d.design.id)

        let state = try await committed(d.h)
        #expect(copy.id != d.design.id && copy.name == "Checkout funnel dashboard copy")
        #expect(copy.agentID == nil, "its agent starts when it opens")
        #expect(state.designs.map(\.id) == [d.design.id, copy.id])
        let original = try await d.h.server.designSnapshot(d.design.id)
        let snapshot = try await d.h.server.designSnapshot(copy.id)
        #expect(snapshot.boards == original.boards && snapshot.revision == 0)
        #expect(snapshot.index.title == copy.name && snapshot.index.boards.keys == original.index.boards.keys)
        #expect(try await d.h.server.designComments(copy.id).comments.isEmpty, "comments stay with the original")
        #expect(try await d.h.server.designVersions(copy.id, path: DesignPath("A.dc.html")!).isEmpty, "so do its versions")
        #expect(try await d.h.server.duplicateDesign(d.design.id).name == "Checkout funnel dashboard copy 2")
    }

    @Test func removingADesignFromRecentsLastsUntilItChanges() async throws {
        let d = try await drawnDesign()
        defer { d.h.stop() }
        #expect(d.design.inRecents)

        try await d.h.server.removeDesignFromRecents(d.design.id)

        let state = try await committed(d.h)
        let hidden = try #require(state.designs.first)
        #expect(!hidden.inRecents && hidden.recentsHiddenAt != nil)
        #expect(try d.h.persisted().designs.first?.recentsHiddenAt == hidden.recentsHiddenAt)
        try await Task.sleep(for: .milliseconds(5))
        _ = try await d.h.server.writeDesignBoard(d.design.id, path: DesignPath("A.dc.html")!, source: DesignTests.board(extra: "<p>3</p>"))
        #expect(d.h.server.state.designs.first?.inRecents == true, "a change brings it back")
    }

    // MARK: Design systems

    private static let tokens: JSONValue = .object([
        "format": .string("shepherd-tokens/1"), "name": .string("acme-web"), "namespace": .string("acme-web"),
        "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5")])]),
    ])

    /// Deleting a system removes its files from Shepherd; a design drawn in it keeps its copy.
    @Test func deletingASystemKeepsTheCopyEveryDesignInstalled() async throws {
        let d = try await drawnDesign()
        defer { d.h.stop() }
        _ = try await d.h.server.writeDesignSystem(DesignSystemWrite(namespace: "acme-web", tokens: Self.tokens, install: true),
                                                   for: d.design.id)
        let copy = try #require(d.h.server.designs.projectFolder(for: d.design.id)).appendingPathComponent("ds/acme-web/tokens.json")
        let installed = try Data(contentsOf: copy)

        try await d.h.server.deleteDesignSystem("acme-web")

        #expect(!(await d.h.server.designSystemSummaries()).contains { $0.info.namespace == "acme-web" })
        #expect(!exists(d.h.server.designSystems.folder(for: "acme-web")))
        #expect(try Data(contentsOf: copy) == installed, "the design keeps its copy")
        #expect(d.h.server.state.designs.first?.systemNamespace == "acme-web")
        await #expect(throws: DesignSystemError.noSuchSystem("acme-web")) { try await d.h.server.deleteDesignSystem("acme-web") }
    }

    @Test func aBuiltInSystemIsNeverDeleted() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.designSystems.register(DesignSystemStore.BuiltIn(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch",
                                                                                         createdAt: 0),
                                                                  files: ["tokens.json": Data("{}".utf8)]))
        await #expect(throws: DesignSystemError.readOnly("night-watch")) { try await h.server.deleteDesignSystem("night-watch") }
        #expect(await h.server.designSystemSummaries().map(\.info.namespace) == ["night-watch"])
    }

    /// A system still being built: deleting it stops the build (its design and agent go at
    /// once, with nothing to undo) and keeps nothing from it. The project is only read.
    @Test func deletingASystemStopsItsBuildAndKeepsNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let repo = try makeScratchDirectory("repo")
        let space = Space(name: "mobile-app", path: repo.path)
        try await h.seed(ShepherdState(spaces: [space]))
        let build = Design(name: "acme-mobile", createdAt: 1, buildsSystem: true, sourceSpaceID: space.id)
        _ = try await h.server.createDesign(build)
        _ = try await h.server.writeDesignSystem(DesignSystemWrite(namespace: "acme-mobile", tokens: .object([
            "format": .string("shepherd-tokens/1"), "namespace": .string("acme-mobile"), "colors": .array([])])), for: build.id)
        let unbuilt = Design(name: "acme-web", createdAt: 2, buildsSystem: true, sourceSpaceID: space.id)
        _ = try await h.server.createDesign(unbuilt)

        try await h.server.deleteDesignSystem("acme-mobile")
        try await h.server.deleteSystemBuild(unbuilt.id)

        #expect(h.server.state.designs.isEmpty, "both builds are gone")
        #expect(await h.server.pendingDesignDeletionIDs().isEmpty, "with nothing held for Undo")
        #expect(!exists(h.server.designs.folder(for: build.id)) && !exists(h.server.designs.stagedFolder(for: build.id)))
        #expect(!exists(h.server.designSystems.folder(for: "acme-mobile")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.path).isEmpty, "the repository is untouched")
    }
}
