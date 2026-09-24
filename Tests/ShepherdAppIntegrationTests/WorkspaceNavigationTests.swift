import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The view model over a real server: restoring a persisted workspace, moving between
/// agents and spaces, pane focus, cold parking, and sidebar drag-reordering.
@Suite("Workspace navigation", .mainActorExclusive)
@MainActor
struct WorkspaceNavigationTests {
    @Test func restoringAPersistedWorkspaceSelectsItsSpaceWithNoLayoutOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))

        let vm = try await app.start(with: ShepherdState(spaces: [space], tabs: [tab]))

        #expect(vm.state.spaces == [space] && vm.state.tabs == [tab])
        #expect(vm.selectedSpaceID == space.id)
        #expect(vm.activeTabID == nil)
    }

    @Test func adjacentAgentSelectionFollowsSidebarOrderAndWraps() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = ["one", "two", "three"].enumerated().map { Fixture.agent($1, in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let ids = agents.map(\.agent.id)

        vm.selectAgent(ids[0])
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == ids[1])
        vm.selectAdjacentAgent(1)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == ids[0])
        vm.selectAdjacentAgent(-1)
        #expect(vm.selectedAgentID == ids[2])
    }

    @Test func collapsingASpaceDropsItsAndItsNestedSpacesAgentsFromTheOrder() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let root = Fixture.space("root", path: app.dir.path)
        let child = Fixture.space("child", path: app.dir.appendingPathComponent("child").path)
        let other = Fixture.space("other", path: "/tmp/elsewhere-\(UUID().uuidString)")
        let agents = [Fixture.agent("root-agent", in: root), Fixture.agent("child-agent", in: child), Fixture.agent("other-agent", in: other)]
        let vm = try await app.start(with: Fixture.state(spaces: [root, child, other], agents: agents))
        #expect(vm.orderedAgents.map(\.name) == ["root-agent", "child-agent", "other-agent"])

        vm.toggleSpaceCollapsed(root.id)

        #expect(vm.orderedAgents.map(\.name) == ["other-agent"])
    }

    @Test func selectingANestedAgentOpensItsCollapsedAncestorsAndTheLocalMachine() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let root = Fixture.space("root", path: app.dir.path)
        let child = Fixture.space("child", path: app.dir.appendingPathComponent("child").path)
        let nested = Fixture.agent("nested", in: child)
        let vm = try await app.start(with: Fixture.state(spaces: [root, child], agents: [nested]))
        vm.collapsedSpaces = [root.id]
        vm.localMachineCollapsed = true
        let before = vm.sidebarRevealRequest

        vm.selectAgent(nested.agent.id)

        #expect(vm.collapsedSpaces.isEmpty)
        #expect(!vm.localMachineCollapsed)
        #expect(vm.sidebarRevealTarget == AnyHashable(nested.agent.id))
        #expect(vm.sidebarRevealRequest > before)
    }

    @Test func returningToAnAgentRestoresThePaneLastFocusedInItsLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = Fixture.agent("first", in: space, order: 0, auxiliary: 1)
        let second = Fixture.agent("second", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second]))

        vm.selectAgent(first.agent.id)
        #expect(vm.focusedPaneID == first.piPane.id)
        vm.focusAdjacentPane(1)
        #expect(vm.focusedPaneID == first.auxiliary[0].id)
        vm.selectAgent(second.agent.id)
        #expect(vm.focusedPaneID == second.piPane.id)
        vm.selectAgent(first.agent.id)

        #expect(vm.focusedPaneID == first.auxiliary[0].id)
    }

    @Test func settingsReopenOnTheLastVisitedSection() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        #expect(vm.settingsSection == .appearance)

        vm.showSettings = true
        vm.settingsSection = .pi
        vm.showSettings = false
        vm.showSettings = true

        #expect(vm.settingsSection == .pi)
    }

    /// Cold parking at the view-model seam: a layout hidden past the delay and outside the
    /// four most recently shown unmounts; selecting it again remounts it at once. An agent's
    /// pane is its RPC thread, so its pane session survives parking.
    @Test func hiddenLayoutsParkPastTheDelayAndUnparkWhenSelected() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        // The first agent's pi is running, so mounting its pane binds to it rather than spawning.
        let agents = [try await app.liveAgent("a0", in: space)] + (1..<6).map { Fixture.agent("a\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        for agent in agents {
            vm.selectAgent(agent.agent.id)
            vm.noteActiveTabVisited()
        }
        let firstSession = vm.sessions.session(for: agents[0].piPane, in: agents[0].tab)
        try await eventuallyOnMain("the first agent's pane to bind its running pi") { firstSession.phase == .live }
        #expect(vm.mountedTabs.count == 6)

        vm.sweepColdPanes()
        #expect(vm.parkedTabIDs.isEmpty, "nothing parks inside the delay")

        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        #expect(vm.parkedTabIDs == [agents[0].tab.id])
        #expect(!vm.mountedTabs.contains { $0.id == agents[0].tab.id })
        #expect(vm.sessions.session(for: agents[0].piPane, in: agents[0].tab) === firstSession)

        vm.selectAgent(agents[0].agent.id)
        vm.noteActiveTabVisited()
        #expect(vm.parkedTabIDs.isEmpty)
        #expect(vm.mountedTabs.contains { $0.id == agents[0].tab.id })
    }

    /// Switching away from an agent and back is a flip: the older pages read in its thread and
    /// where it was scrolled to are still there (the hidden thread keeps its store and its view;
    /// the first pull after it comes back merges onto the history).
    @Test func switchingAwayAndBackKeepsLoadedHistoryAndScrollPosition() async throws {
        let history = ThreadFixture.history(300)
        let thread = FakeThread(ThreadFixture.snapshot([]), history: history)
        defer { thread.close() }
        try await thread.waitUntilReady()
        for _ in 0..<4 {
            await thread.store.loadOlder()
            ListPerf.settle(thread.window)
        }
        #expect(thread.store.messages.count == 250)
        // Up into the older pages, reading: ⌥⌘↑ from there detaches the thread from its tail.
        let scroll = try #require(thread.scrollView)
        _ = ListPerf.scroll(thread.window, scroll, step: -600, steps: 20)
        thread.commands.send(.previousTurn, to: "fake")
        let clip = scroll.contentView
        var last = clip.bounds.origin.y, still = 0
        try await eventuallyOnMain("the turn jump to come to rest", poll: .milliseconds(30)) {
            ListPerf.settle(thread.window)
            still = clip.bounds.origin.y == last ? still + 1 : 0
            last = clip.bounds.origin.y
            return still >= 5
        }
        let offset = clip.bounds.origin.y

        try await thread.show(false)
        try await thread.show(true)

        #expect(thread.store.messages.count == 250)
        #expect(abs(clip.bounds.origin.y - offset) < 1, "scrolled to \(offset), now \(clip.bounds.origin.y)")
    }

    @Test func draggingAnAgentOntoASiblingReordersItsSpaceAndPersists() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (spaces, agents) = reorderFixture(in: app.dir)
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: agents))

        let accepted = vm.dropAgent(payload: ShepherdViewModel.dragPayload(agent: agents[2].agent.id), on: agents[0].agent.id)

        #expect(accepted)
        #expect(vm.state.agents.map(\.name) == ["c", "a", "b", "d"])
        let server = app.server
        try await eventuallyOnMain("the new order to persist") { server.state.agents.map(\.name) == ["c", "a", "b", "d"] }
    }

    @Test func draggingASpaceOntoAnotherReordersSpacesAndPersists() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (spaces, agents) = reorderFixture(in: app.dir)
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: agents))

        #expect(vm.dropSpace(payload: ShepherdViewModel.dragPayload(space: spaces[1].id), on: spaces[0].id))

        #expect(vm.state.spaces.map(\.name) == ["two", "one"])
        let server = app.server
        try await eventuallyOnMain("the new space order to persist") { server.state.spaces.map(\.name) == ["two", "one"] }
    }

    @Test(arguments: ["cross-space", "self", "space-on-agent", "garbage", "agent-on-space"])
    func invalidDropsLeaveTheOrderAlone(drop: String) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (spaces, agents) = reorderFixture(in: app.dir)
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: agents))
        let a = agents[0].agent.id

        let accepted = switch drop {
        case "cross-space": vm.dropAgent(payload: ShepherdViewModel.dragPayload(agent: agents[3].agent.id), on: a)
        case "self": vm.dropAgent(payload: ShepherdViewModel.dragPayload(agent: a), on: a)
        case "space-on-agent": vm.dropAgent(payload: ShepherdViewModel.dragPayload(space: spaces[0].id), on: a)
        case "agent-on-space": vm.dropSpace(payload: ShepherdViewModel.dragPayload(agent: a), on: spaces[0].id)
        default: vm.dropAgent(payload: "garbage", on: a)
        }

        #expect(!accepted)
        #expect(vm.state.agents.map(\.name) == ["a", "b", "c", "d"])
        #expect(vm.state.spaces.map(\.name) == ["one", "two"])
    }

    /// Two spaces: a, b, c in the first, d in the second.
    private func reorderFixture(in dir: URL) -> ([Space], [AgentFixture]) {
        let one = Fixture.space("one", path: dir.appendingPathComponent("one").path)
        let two = Fixture.space("two", path: dir.appendingPathComponent("two").path)
        let agents = [Fixture.agent("a", in: one, order: 0), Fixture.agent("b", in: one, order: 1),
                      Fixture.agent("c", in: one, order: 2), Fixture.agent("d", in: two, order: 0)]
        return ([one, two], agents)
    }
}
