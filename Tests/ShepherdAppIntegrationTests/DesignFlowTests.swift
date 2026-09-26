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
/// design whose agent is gone starts a fresh one; and switching away and back is a visibility
/// flip.
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
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, space) = try await start(app)

        vm.openNewDesign()
        #expect(vm.shownDestination == .newDesign)
        let draft = vm.newDesign
        #expect(draft.space == space.id, "the project picked is the only one")
        #expect(draft.blocker(vm) == "Describe the design first.")
        draft.brief = "A checkout funnel dashboard for the product team"
        #expect(draft.blocker(vm) == nil)
        draft.send(vm)

        try await eventuallyOnMain("the design's agent to be on screen") { vm.shownDesign != nil && !draft.starting }
        let design = try #require(vm.state.designs.first)
        let agent = try #require(vm.selectedAgent)
        #expect(design.name == "A checkout funnel dashboard for the product team")
        #expect(design.spaceID == space.id)
        #expect(design.agentID == agent.id)
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
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, space) = try await start(app)
        let design = Design(name: "Onboarding", spaceID: space.id, createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        try await eventuallyOnMain("the design to arrive") { vm.state.designs.count == 1 }

        vm.selectSidebarRow(.design(design.id))
        try await eventuallyOnMain("a fresh agent on screen") { vm.shownDesign?.id == design.id }
        let agent = try #require(vm.selectedAgent)
        #expect(agent.designID == design.id)
        #expect(vm.state.designs.first?.agentID == agent.id)
        #expect(vm.state.agents.count == 1)

        // Opening it again selects that agent; no second one starts.
        vm.openDestination(.designs)
        vm.openDesign(design.id)
        #expect(vm.selectedAgentID == agent.id && vm.shownDestination == nil)
        #expect(vm.state.agents.count == 1)
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
        let design = Design(name: "Checkout", spaceID: space.id, agentID: drawer.agent.id, createdAt: 1_000)
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
}
