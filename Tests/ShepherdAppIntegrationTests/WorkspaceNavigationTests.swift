import AppKit
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The view model over a real server: restoring a persisted workspace, moving between agents
/// and pages, pane focus, and cold parking.
@Suite("Workspace navigation", .mainActorExclusive)
@MainActor
struct WorkspaceNavigationTests {
    /// With no agent to show, the main column shows the New thread page.
    @Test func restoringAWorkspaceWithoutAgentsShowsNewThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))

        let vm = try await app.start(with: ShepherdState(spaces: [space], tabs: [tab]))

        #expect(vm.state.spaces == [space] && vm.state.tabs == [tab])
        #expect(vm.selectedSpaceID == space.id)
        #expect(vm.activeTabID == nil)
        #expect(vm.shownDestination == .newThread)
    }

    /// At launch the most recently active agent shows.
    @Test func restoringAWorkspaceShowsTheMostRecentlyActiveAgent() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents = ["old", "recent", "untimed"].enumerated().map { Fixture.agent($1, in: space, order: $0) }
        agents[0].agent.lastActiveAt = 10
        agents[1].agent.lastActiveAt = 20
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        #expect(vm.selectedAgentID == agents[1].agent.id)
        #expect(vm.shownDestination == nil)
    }

    /// ⌘↓ walks Recents (untimed agents newest first) and wraps.
    @Test func adjacentAgentSelectionFollowsRecentsAndWraps() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = ["one", "two", "three"].enumerated().map { Fixture.agent($1, in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let ids = agents.map(\.agent.id)

        vm.selectAgent(ids[2])
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == ids[1])
        vm.selectAdjacentAgent(1)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == ids[2])
        vm.selectAdjacentAgent(-1)
        #expect(vm.selectedAgentID == ids[0])
    }

    /// A page covers the thread without unmounting it; picking a row brings the thread back as
    /// a flip, and the sidebar is asked to reveal that row.
    @Test func aPageHidesTheThreadAndPickingARowReturnsToIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<2).map { Fixture.agent("a\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        let mounted = vm.mountedTabs.map(\.id)

        for page in MainDestination.allCases {
            vm.openDestination(page)
            #expect(vm.shownDestination == page)
            #expect(vm.activeTabID == nil && vm.selectedSidebarRow == nil)
            #expect(vm.mountedTabs.map(\.id) == mounted, "nothing unmounts behind a page")
        }
        #expect(vm.moreOpen, "Hosts opens More")
        #expect(vm.newThread.place == NewThreadPlace(host: nil, space: space.id), "New thread opens in the thread's project")

        let before = vm.sidebarRevealRequest
        vm.selectSidebarRow(.local(agents[1].agent.id))
        #expect(vm.destination == nil && vm.shownDestination == nil)
        #expect(vm.activeTabID == agents[1].tab.id)
        #expect(vm.selectedSidebarRow == .local(agents[1].agent.id))
        #expect(vm.sidebarRevealRequest > before)
    }

    /// A space from the palette or the Space menu opens New thread there.
    @Test func goingToASpaceOpensNewThreadInIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let one = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let two = Fixture.space("two", path: app.dir.appendingPathComponent("two").path)
        let agent = Fixture.agent("a", in: one)
        let vm = try await app.start(with: Fixture.state(spaces: [one, two], agents: [agent]))

        vm.selectSpace(two.id)

        #expect(vm.shownDestination == .newThread)
        #expect(vm.newThread.place == NewThreadPlace(host: nil, space: two.id))
        #expect(vm.state.agents.count == 1, "nothing starts until you send")
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

    /// Cold parking at the view-model seam: a layout holding a terminal pane, hidden past the
    /// delay and outside the four most recently shown, unmounts; selecting it again remounts it
    /// at once. An agent's pane is its RPC thread, so its pane session survives parking.
    @Test func hiddenLayoutsParkPastTheDelayAndUnparkWhenSelected() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        // The first agent's pi is running, so mounting its pane binds to it rather than spawning;
        // a terminal pane beside its thread is what makes its layout worth parking.
        let agents = [try await app.liveAgent("a0", in: space, auxiliary: 1)]
            + (1..<6).map { Fixture.agent("a\($0)", in: space, order: $0, auxiliary: 1) }
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

    /// A layout that is only a thread never parks: it has no surface to release and polls
    /// nothing while hidden, so returning to it after any time away is a flip.
    @Test func threadOnlyLayoutsNeverPark() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<6).map { Fixture.agent("a\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        for agent in agents {
            vm.selectAgent(agent.agent.id)
            vm.noteActiveTabVisited()
        }

        vm.sweepColdPanes(now: Date().addingTimeInterval(3_600))

        #expect(vm.parkedTabIDs.isEmpty)
        #expect(vm.mountedTabs.count == agents.count)
    }

    /// At launch the visible layout mounts first and the rest follow; an agent switched to
    /// before its turn mounts then, once, and switching to it later is a flip.
    @Test func switchingToAnAgentNotYetMountedMountsItOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(6, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        func scrollViews() -> Set<ObjectIdentifier> {
            func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return Set(all(window.host).map(ObjectIdentifier.init))
        }
        let late = agents[5]
        #expect(!vm.mountedTabs.contains { $0.id == late.tab.id }, "its turn to mount has not come")
        let before = scrollViews()

        vm.selectAgent(late.agent.id)
        ListPerf.settle(window)
        let mounted = scrollViews().subtracting(before)
        #expect(mounted.count == 1, "its thread mounted")
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        for agent in [agents[0], late, agents[2], late] {
            vm.selectAgent(agent.agent.id)
            ListPerf.settle(window)
        }

        #expect(scrollViews().isSuperset(of: mounted), "it was never mounted again")
    }

    /// The workspace can draw before the restored agents reach it (its first adoption was still
    /// empty): the layouts that wait to mount still mount after it, so every agent's pane binds
    /// its pi without being shown.
    @Test func layoutsThatArriveAfterTheFirstFrameStillMount() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        // Past the first frame's mounting pass, which found nothing to mount.
        try await Task.sleep(for: .milliseconds(50))
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<3 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }

        try await app.server.putState(Fixture.state(spaces: [space], agents: agents))
        try await eventuallyOnMain("the workspace to adopt its agents") { vm.state.agents.count == agents.count }
        ListPerf.settle(window)

        try await eventuallyOnMain("every layout to mount", timeout: .seconds(5)) { vm.mountedTabs.count == agents.count }
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

    /// Switching agents keeps every mounted layout's views (their scroll views are the same
    /// objects) and their order: visibility is opacity, never a remount.
    @Test func switchingKeepsEveryLayoutMountedInItsOrder() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(4, in: app)
        defer { window.close() }
        func scrollViews() -> Set<ObjectIdentifier> {
            func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return Set(all(window.host).map(ObjectIdentifier.init))
        }
        let order = vm.mountedTabs.map(\.id)
        let views = scrollViews()

        for agent in [agents[2], agents[3], agents[1], agents[0]] {
            vm.selectAgent(agent.agent.id)
            ListPerf.settle(window)
            #expect(vm.mountedTabs.map(\.id) == order)
        }

        #expect(scrollViews() == views, "no layout was rebuilt")
    }
}
