import AppKit
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
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
    /// objects) and their order: visibility is a hosting view's `isHidden`, never a remount.
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

    /// Each mounted layout has a hosting view of its own, and only the visible agent's is
    /// shown: a hidden one takes no clicks and is out of VoiceOver's reach, before and after a
    /// switch.
    @Test func onlyTheVisibleLayoutsHostIsShownClickableAndAccessible() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(4, in: app)
        defer { window.close() }
        let deck = try Self.deck(in: window)
        #expect(deck.pages.count == agents.count)

        for agent in [agents[0], agents[2], agents[3]] {
            vm.selectAgent(agent.agent.id)
            ListPerf.settle(window)
            let visible = try #require(deck.pages[agent.tab.id]?.host)
            #expect(deck.pages.values.filter { !$0.host.isHidden }.map { ObjectIdentifier($0.host) } == [ObjectIdentifier(visible)])
            let center = deck.convert(CGPoint(x: deck.bounds.midX, y: deck.bounds.midY), to: deck.superview)
            let hit = try #require(deck.hitTest(center), "a click in the middle of the column")
            #expect(hit.isDescendant(of: visible))
            #expect((deck.accessibilityChildren() ?? []).map { ObjectIdentifier($0 as AnyObject) } == [ObjectIdentifier(visible)])
        }
    }

    /// A layout hidden and shown again is the same views where it was left: the Changes pane's
    /// diff is the same scroll view, scrolled to the same place.
    @Test func aHiddenLayoutKeepsItsViewsAndScrollPosition() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let workspace = try await HiddenAgentsWorkspace.open(hidden: 2, in: app)
        defer { workspace.close() }
        _ = workspace.scroll(step: 400, steps: 10)
        let offset = workspace.diff.contentView.bounds.origin.y
        #expect(offset > 1000)

        workspace.vm.selectAgent(workspace.agents[1].agent.id)
        ListPerf.settle(workspace.window)
        #expect(workspace.diff.isHiddenOrHasHiddenAncestor)
        workspace.vm.selectAgent(workspace.agents[0].agent.id)
        ListPerf.settle(workspace.window)

        #expect(HiddenAgentsWorkspace.shownScrollViews(in: workspace.window).contains { $0 === workspace.diff })
        #expect(abs(workspace.diff.contentView.bounds.origin.y - offset) < 1)
    }

    /// Switching away from an agent typing in its composer never leaves the keyboard in the
    /// hidden layout: the shown agent's composer takes it, and text typed lands in its draft
    /// alone.
    @Test func typingAfterASwitchLandsInTheShownAgentsDraftAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(3, in: app)
        defer { window.close() }
        func fieldEditor() async throws -> NSTextView {
            var editor: NSTextView?
            try await eventuallyOnMain("the composer to take the keyboard") {
                ListPerf.settle(window)
                editor = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
                return editor != nil
            }
            return try #require(editor)
        }
        func drafts() -> [String] { agents.map { vm.threadStores.store(for: $0.agent.id).draft } }

        for (from, to) in [(0, 1), (1, 2), (2, 0)] {
            vm.selectAgent(agents[from].agent.id)
            vm.focusedPaneID = agents[from].piPane.id
            _ = try await fieldEditor()
            vm.selectAgent(agents[to].agent.id)
            ListPerf.settle(window)
            let responder = window.window.firstResponder as? NSView
            #expect(responder?.isHiddenOrHasHiddenAncestor != true, "the keyboard stayed in a hidden layout")

            vm.focusedPaneID = agents[to].piPane.id
            let before = drafts()
            try await fieldEditor().insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
            ListPerf.settle(window)
            let changed = agents.indices.filter { drafts()[$0] != before[$0] }
            #expect(changed == [to])
            for agent in agents { vm.threadStores.store(for: agent.agent.id).draft = "" }
        }
    }

    @MainActor @Observable final class Scheme {
        var value: ColorScheme = .dark
    }

    private struct SchemedWorkspace: View {
        let scheme: Scheme
        let vm: ShepherdViewModel

        var body: some View { WorkspaceView(vm: vm).environment(\.colorScheme, scheme.value) }
    }

    /// A layout's hosting view takes the workspace's environment, and its changes, hidden or
    /// not: an appearance switched while an agent was hidden shows when it is selected.
    @Test func anEnvironmentChangeReachesLayoutsHiddenWhenItChanged() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(3, in: app)
        let scheme = Scheme()
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, SchemedWorkspace(scheme: scheme, vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        ListPerf.settle(window)
        func brightness() -> Double {
            let host = window.host
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var total = 0.0, count = 0.0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                    total += Double(bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
                    count += 1
                }
            }
            return total / count
        }
        #expect(brightness() < 0.4)

        scheme.value = .light
        ListPerf.settle(window)
        #expect(brightness() > 0.6)
        vm.selectAgent(agents[2].agent.id)
        ListPerf.settle(window)
        #expect(brightness() > 0.6, "the layout hidden while the appearance changed")

        scheme.value = .dark
        ListPerf.settle(window)
        vm.selectAgent(agents[1].agent.id)
        ListPerf.settle(window)
        #expect(brightness() < 0.4)
    }

    /// Through a live resize the visible layout follows the column and the hidden ones keep
    /// the size they had when it began; once it ends, they take the column's.
    @Test func hiddenLayoutsKeepTheirSizeThroughALiveResize() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(3, in: app)
        defer { window.close() }
        let deck = try Self.deck(in: window)
        let start = deck.bounds.size
        func frames() -> [CGSize] { agents.compactMap { deck.pages[$0.tab.id]?.host.frame.size } }
        #expect(frames() == Array(repeating: start, count: agents.count))

        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window.window)
        ListPerf.settle(window)
        for step in 1...4 {
            window.window.setContentSize(NSSize(width: start.width - CGFloat(step) * 20, height: start.height))
            ListPerf.settle(window)
        }
        let narrow = deck.bounds.size
        #expect(narrow.width < start.width)
        #expect(frames() == [narrow, start, start])
        vm.selectAgent(agents[1].agent.id)
        ListPerf.settle(window)
        #expect(frames() == [start, narrow, start], "the shown layout follows the column at once")

        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window.window)
        ListPerf.settle(window)
        #expect(frames() == Array(repeating: narrow, count: agents.count))
    }

    /// The workspace's deck of layouts.
    static func deck(in window: OffscreenWindow) throws -> AgentLayoutDeck.Container {
        func find(_ view: NSView) -> AgentLayoutDeck.Container? {
            (view as? AgentLayoutDeck.Container) ?? view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(window.window.contentView!))
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
