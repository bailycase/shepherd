import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// The Design tool end to end on a real server with the stub pi: New design makes a design and
/// its agent and opens the canvas; a design is its Recents row and its agent has none; opening a
/// design whose agent is gone starts a fresh one; switching away and back is a visibility flip;
/// and a board the agent writes reloads in place on the canvas, alone.
@Suite("Design tool", .mainActorExclusive)
@MainActor
struct DesignFlowTests {
    /// A workspace with the Design tool on and one project.
    private func start(_ app: AppHarness, agents: [AgentFixture] = [], designs: [Design] = []) async throws -> (ShepherdViewModel, Space) {
        app.settings.designToolEnabled = true
        let space = agents.first?.space ?? Fixture.space(path: app.dir.path)
        var state = Fixture.state(spaces: [space], agents: agents)
        state.designs = designs
        let vm = try await app.start(with: state)
        vm.designNetwork = .none
        return (vm, space)
    }

    // MARK: Creating and opening

    @Test func newDesignMakesTheDesignStartsItsAgentWithTheBriefAndOpensTheCanvas() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, space) = try await start(app)

        vm.openNewDesign()
        #expect(vm.shownDestination == .newDesign)
        let draft = vm.newDesign
        #expect(draft.blocker(vm) == "Describe the design first.")
        draft.brief = "A checkout funnel dashboard for the product team"
        #expect(draft.blocker(vm) == nil)
        draft.send(vm)

        try await eventuallyOnMain("the design's agent to be on screen") { vm.shownDesign != nil && !draft.starting }
        let design = try #require(vm.state.designs.first)
        let agent = try #require(vm.selectedAgent)
        #expect(design.name == "A checkout funnel dashboard for the product team")
        #expect(design.agentID == agent.id)
        // A design stands alone: its agent lives in the reserved designs space, in the design's
        // own folder, and the projects are as they were.
        let designs = try #require(vm.state.designsSpace)
        #expect(agent.spaceID == designs.id && designs.hidden)
        #expect(vm.visibleSpaces == [space])
        let folder = try #require(app.server.designs.folder(for: design.id))
        #expect(vm.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == folder.path)
        #expect(!vm.paletteItems.contains { $0.id == "space.\(designs.id.rawValue)" || $0.id == "agent.\(agent.id.rawValue)" },
                "never a project, and its agent no destination, in the palette")
        #expect(agent.designID == design.id)
        #expect(agent.nameIsFinal, "a design's agent keeps the design's name: no namer")
        #expect(agent.model == app.settings.agentDefaults.model, "the default model")
        #expect(vm.shownDestination == nil)
        #expect(vm.selectedSidebarRow == .design(design.id))
        #expect(vm.sidebarLists.recents.map(\.id) == [.design(design.id)], "the design is the row; its agent has none")
        #expect(draft.brief.isEmpty)

        // The brief is the agent's first message.
        let server = app.server
        try await eventuallyAsync("pi to answer the brief", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.first?.text == design.name }
        }
    }

    @Test func openingADesignWhoseAgentIsGoneStartsAFreshOne() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, _) = try await start(app)
        let design = Design(name: "Onboarding", createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        try await eventuallyOnMain("the design to arrive") { vm.state.designs.count == 1 }

        vm.selectSidebarRow(.design(design.id))
        try await eventuallyOnMain("a fresh agent on screen") { vm.shownDesign?.id == design.id }
        let agent = try #require(vm.selectedAgent)
        #expect(agent.designID == design.id)
        #expect(vm.state.agents.count == 1)

        // Opening it again selects that agent, even before the design records it; no second one
        // starts.
        vm.openDestination(.designs)
        vm.openDesign(design.id)
        #expect(vm.selectedAgentID == agent.id && vm.shownDestination == nil)
        try await eventuallyOnMain("the design to record its agent") { vm.state.designs.first?.agentID == agent.id }
        #expect(vm.state.agents.count == 1)
        #expect(vm.startingDesignAgents.isEmpty)
    }

    /// Import Claude Design Folder… makes a standalone design, with or without a project.
    @Test func importingAFolderMakesAStandaloneDesign() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start(with: ShepherdState())
        vm.designNetwork = .none
        let folder = try makeScratchDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"v":3,"title":"Imported","boards":{}}"#.utf8).write(to: folder.appendingPathComponent("canvas.json"))

        vm.importDesignFolder(folder)

        try await eventuallyOnMain("the imported design on screen") { vm.shownDesign?.name == "Imported" }
        #expect(vm.remoteActionError == nil)
        #expect(vm.visibleSpaces.isEmpty, "no project was needed or made")
        let agent = try #require(vm.selectedAgent)
        #expect(agent.spaceID == vm.state.designsSpace?.id)
    }

    @Test func theDesignPagesExistOnlyWhileTheToolIsOn() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.openDestination(.designs)
        #expect(vm.shownDestination == .newThread, "off: the page does not open")
        app.settings.designToolEnabled = true
        vm.openDestination(.designs)
        #expect(vm.shownDestination == .designs)
        vm.openNewDesign()
        #expect(vm.shownDestination == .newDesign)
    }

    // MARK: The canvas

    /// A design drawn by a live stub agent, beside a plain thread, in a window.
    private func openCanvas(_ app: AppHarness, boards: [DesignFixtures.Board] = DesignFixtures.checkout, perRow: Int = 3,
                            size: CGSize = CGSize(width: 1400, height: 900)) async throws
        -> (vm: ShepherdViewModel, window: OffscreenWindow, design: Design, drawer: AgentFixture, other: AgentFixture) {
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Checkout", in: space, order: 0)
        let other = try await app.liveAgent("thread", in: space, order: 1)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let (vm, _) = try await start(app, agents: [drawer, other])
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(boards, in: design.id, on: app.server, perRow: perRow)
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: size, dark: true, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        try await eventuallyOnMain("the canvas to draw every board on screen", timeout: .seconds(60)) {
            window.layout()
            return screen.isDrawn && !screen.visibleBoards.isEmpty
        }
        return (vm, window, design, drawer, other)
    }

    /// Switching to another agent and back keeps the design's layout mounted: its hosting view is
    /// hidden and shown, never rebuilt, and hidden it gives up its live views.
    @Test func switchingAwayFromADesignAndBackIsAVisibilityFlip() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, design, drawer, other) = try await openCanvas(app)
        defer { window.close() }
        let screen = vm.designScreen(design.id)
        screen.select("A.dc.html")
        let host = try #require(screen.host)
        try await eventuallyOnMain("the selected board to go live") { host.liveBoards.contains(DesignPath("A.dc.html")!) }
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let page = try #require(deck.pages[drawer.tab.id]?.host)
        let order = vm.mountedTabs.map(\.id)

        vm.selectAgent(other.agent.id)
        ListPerf.settle(window)
        #expect(page.isHidden)
        try await eventuallyOnMain("the hidden design to give up its live views") { host.liveCount == 0 }

        vm.selectAgent(drawer.agent.id)
        ListPerf.settle(window)
        #expect(!page.isHidden)
        #expect(deck.pages[drawer.tab.id]?.host === page, "the same hosting view")
        #expect(vm.mountedTabs.map(\.id) == order)
        #expect(vm.designScreen(design.id) === screen, "the same canvas, where it was left")
        try await eventuallyOnMain("the selected board to go live again") { host.liveBoards.contains(DesignPath("A.dc.html")!) }
    }

    /// Select: a click names the element under it (the board's own hit test), the pointer rings
    /// what it is over, a rewrite finds the selection again, and the chat's messages carry what the
    /// canvas shows.
    @Test func aClickSelectsTheElementUnderItAndTheChatCarriesWhatTheCanvasShows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, design, drawer, _) = try await openCanvas(app)
        defer { window.close() }
        let screen = vm.designScreen(design.id)
        let host = try #require(screen.host)
        let a = DesignPath("A.dc.html")!

        // The fixture's first card on A is 396 wide from x 32, under the heading; this is its padding.
        screen.pick(NWCanvasPick(board: a.rawValue, point: CGPoint(x: 420, y: 150)))
        try await eventuallyOnMain("the card to be selected") { screen.selectedElements.count == 1 }
        let card = try #require(screen.selectedElements.first)
        #expect(card.id.description == "A.dc.html#7:1/1/0")
        #expect(card.kind == .shape && card.tag == "card · Step 1 90%")
        #expect(abs(card.rect.minX - 32) < 1 && abs(card.rect.width - 396) < 1 && card.rect.contains(CGPoint(x: 420, y: 150)), "\(card.rect)")
        #expect(host.liveBoards.contains(a), "the board holding the selection stays live")
        #expect(screen.selectionRings.map(\.tag) == ["card · Step 1 90%"])

        // Shift adds the heading; a plain click on the empty canvas clears.
        screen.pick(NWCanvasPick(board: a.rawValue, point: CGPoint(x: 100, y: 45), extending: true))
        try await eventuallyOnMain("the heading to join") { screen.selectedElements.count == 2 }
        #expect(screen.selectedElements.last?.id.description == "A.dc.html#5:1/0/1")
        #expect(screen.selectedElements.last?.label == "Checkout funnel")

        let record = try #require(screen.viewRecord)
        #expect(record.isValid)
        #expect(record.selected.map(\.description) == ["A.dc.html#7:1/1/0", "A.dc.html#5:1/0/1"])
        #expect(record.selectedBoards == ["A.dc.html"])
        #expect(record.visibleBoards.contains("A.dc.html"))
        let store = vm.threadStores.store(for: drawer.agent.id)
        #expect(store.designContext?() == record, "the chat sends what the canvas shows")

        // The pointer over B's heading rings it.
        screen.pointer(NWCanvasPick(board: "B.dc.html", point: CGPoint(x: 100, y: 45)))
        try await eventuallyOnMain("B's heading to be ringed", timeout: .seconds(30)) { screen.hover?.id.description == "B.dc.html#5:1/0/1" }
        screen.pointer(nil)
        #expect(screen.hover == nil)

        // A rewrite that moves the heading down finds it again where it is drawn now.
        let written = try await app.server.writeDesignBoard(design.id, path: a, source: DesignFixtures.source(DesignFixtures.checkout[0])
            .replacingOccurrences(of: "gap: 18px\">", with: "gap: 18px; padding-top: 132px\">"))
        try await eventuallyOnMain("the heading to be found where it moved", timeout: .seconds(30)) {
            screen.snapshot?.boards[a] == written.sha256 && screen.selectedElements.last.map { $0.rect.minY > 100 } == true
        }

        // Clicks land in order: one whose board is still being asked never overtakes a later one.
        screen.pick(NWCanvasPick(board: "B.dc.html", point: CGPoint(x: 100, y: 45)))
        screen.pick(NWCanvasPick())
        try await eventuallyOnMain("the clicks to settle", timeout: .seconds(30)) { !screen.isPicking }
        #expect(screen.picks.isEmpty, "the click on the empty canvas came last")

        screen.pick(NWCanvasPick(board: a.rawValue, point: CGPoint(x: 100, y: 45)))
        try await eventuallyOnMain("the heading to be selected again", timeout: .seconds(30)) { !screen.isPicking }
        screen.pick(NWCanvasPick())
        #expect(screen.picks.isEmpty && screen.viewRecord?.selected.isEmpty == true)
    }

    /// One write to a board is one revision pushed and one board reloaded in place (the live one,
    /// with no new view); the others are untouched. New boards appear and removed ones leave.
    @Test func aBoardTheAgentRewritesReloadsInPlaceAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, design, _, _) = try await openCanvas(app)
        defer { window.close() }
        let screen = vm.designScreen(design.id)
        let host = try #require(screen.host)
        let a = DesignPath("A.dc.html")!, b = DesignPath("B.dc.html")!
        screen.select(a.rawValue)
        try await eventuallyOnMain("A to go live") { host.liveView(a) != nil }
        let view = host.liveView(a)
        let server = app.server
        var pushes = 0
        let forward = server.onDesignRevision
        server.onDesignRevision = { id in
            pushes += 1
            forward?(id)
        }
        let before = (reloads: host.reloads, snapshots: host.snapshotsTaken, pulls: screen.pulls, tokenB: host.tokens[b])

        let board = DesignFixtures.checkout[0]
        let written = try await server.writeDesignBoard(design.id, path: a, source: DesignFixtures.source(board, note: "revised"))
        try await eventuallyOnMain("A to show the rewrite", timeout: .seconds(30)) {
            screen.snapshot?.boards[a] == written.sha256 && host.isDrawn([a]) && host.snapshotsTaken > before.snapshots
        }
        #expect(pushes == 1, "one revision pushed")
        #expect(host.reloads == before.reloads + 1, "the live board reloaded in place")
        #expect(host.liveView(a) === view, "no new view: no navigation")
        #expect(host.snapshotsTaken == before.snapshots + 1, "one snapshot redrawn")
        #expect(host.tokens[b] == before.tokenB, "B is untouched")

        // A board the agent adds appears; one it removes leaves.
        let added = DesignFixtures.Board(path: "D.dc.html", title: "D · Minimal", width: 1280, height: 800, accent: "#be123c")
        _ = try await server.writeDesignBoard(design.id, path: DesignPath("D.dc.html")!, source: DesignFixtures.source(added))
        _ = try await server.updateDesignIndex(design.id, patch: .object([
            "boards": .object(["D.dc.html": .object(["x": .number(0), "y": .number(2000), "w": .number(1280), "h": .number(800),
                                                     "title": .string("D · Minimal")]),
                               "C.dc.html": .null]),
        ]))
        try await eventuallyOnMain("D to arrive and C to leave") {
            let ids = screen.boards.map(\.id)
            return ids.contains("D.dc.html") && !ids.contains("C.dc.html")
        }
        #expect(host.image(DesignPath("C.dc.html")!) == nil)
        #expect(screen.boards.first { $0.id == "D.dc.html" }?.title == "D · Minimal")
    }

    /// The design agent's own tools, over the extension socket as `shepherd-design.ts` sends them:
    /// boards it writes onto an empty canvas on screen draw there, and its rewrite of one board
    /// reloads that board in place and leaves the other alone.
    @Test func boardsTheAgentWritesOverItsSocketDrawOnTheCanvasAndARewriteReloadsOnlyThatBoard() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Checkout", in: space)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let (vm, _) = try await start(app, agents: [drawer])
        _ = try await app.server.createDesign(design)
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        let screen = vm.designScreen(design.id)
        let host = try #require(screen.host)
        try await eventuallyOnMain("the empty canvas on screen") {
            window.layout()
            return host.isActive && screen.snapshot != nil
        }
        #expect(screen.boards.isEmpty)

        let boards = Array(DesignFixtures.checkout.prefix(2))
        let agentID = drawer.agent.id
        for (index, board) in boards.enumerated() {
            let reply = try await app.extensionRequest(.designWriteBoard(id: index + 1, agentID: agentID, designID: design.id,
                                                                         path: board.path, source: DesignFixtures.source(board),
                                                                         baseRevision: nil))
            guard case .designWritten(_, let result) = reply, result.changed else { Issue.record("no write: \(reply)"); return }
        }
        let placed = try await app.extensionRequest(.designUpdateIndex(id: 3, agentID: agentID, designID: design.id,
                                                                       changes: DesignFixtures.layout(boards), baseRevision: nil))
        guard case .designWritten = placed else { Issue.record("no layout: \(placed)"); return }

        let a = DesignPath("A.dc.html")!, b = DesignPath("B.dc.html")!
        try await eventuallyOnMain("both boards drawn on the canvas", timeout: .seconds(60)) {
            window.layout()
            return screen.boards.map(\.id) == [a.rawValue, b.rawValue] && screen.isDrawn
        }
        screen.select(a.rawValue)
        try await eventuallyOnMain("A to go live") { host.liveView(a) != nil }
        let view = host.liveView(a)
        let before = (reloads: host.reloads, tokenB: host.tokens[b], shaB: screen.snapshot?.boards[b])

        let rewrite = try await app.extensionRequest(.designWriteBoard(id: 4, agentID: agentID, designID: design.id, path: a.rawValue,
                                                                       source: DesignFixtures.source(boards[0], note: "revised"),
                                                                       baseRevision: nil))
        guard case .designWritten(_, let written) = rewrite, written.changed else { Issue.record("no rewrite: \(rewrite)"); return }
        try await eventuallyOnMain("A to show the rewrite", timeout: .seconds(30)) {
            screen.snapshot?.boards[a] == written.sha256 && host.isDrawn([a]) && host.reloads > before.reloads
        }
        #expect(host.reloads == before.reloads + 1, "A reloaded in place, once")
        #expect(host.liveView(a) === view, "no new view: no navigation")
        #expect(host.tokens[b] == before.tokenB && screen.snapshot?.boards[b] == before.shaB, "B is untouched")
    }
}
