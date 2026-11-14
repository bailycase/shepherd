import AppKit
import ShepherdRemote
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import TerminalSurfaceKit

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
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<2).map { Fixture.agent("a\($0)", in: space, order: $0) }
        // Every page, the Design tool's and Fleet's included.
        app.settings.designToolEnabled = true
        app.settings.fleetEnabled = true
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        let mounted = vm.mountedTabs.map(\.id)

        // A project's pages need a project to show: a real one, made through the owner.
        let made = try await app.server.logicalProjects(.create(projectID: ProjectID(), name: "Sample App", goal: "", linkedSpaceIDs: []))
        guard case .project(let project) = made else { Issue.record("Expected a project"); return }
        try await eventuallyOnMain("the project arrives") { vm.state.projects.count == 1 }
        vm.selectedLogicalProject = LogicalProjectRef(home: .local, id: project.id)
        for page in MainDestination.allCases {
            vm.openDestination(page)
            #expect(vm.shownDestination == page)
            #expect(vm.activeTabID == nil && vm.selectedSidebarRow == nil)
            #expect(vm.mountedTabs.map(\.id) == mounted, "nothing unmounts behind a page")
        }
        // Fleet and Extensions have no sidebar row (the boards draw three destinations); the palette opens them. There is no Open Hosts: a
        // Mac is added to the fleet in Settings ▸ Fleet.
        vm.openDestination(.newThread)
        #expect(!vm.paletteItems.contains { $0.title == "Open Hosts" })
        let fleet = try #require(vm.paletteItems.first { $0.title == "Open Fleet" })
        vm.runPaletteItem(fleet)
        #expect(vm.shownDestination == .fleet)
        let extensions = try #require(vm.paletteItems.first { $0.title == "Open Extensions" })
        vm.runPaletteItem(extensions)
        #expect(vm.showSettings && vm.settingsSection == .extensions)
        vm.showSettings = false
        vm.openDestination(.newThread)
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

    @Test func returningToAnAgentRestoresTheTerminalLastFocusedInItsLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = Fixture.agent("first", in: space, order: 0, auxiliary: 1)
        let second = Fixture.agent("second", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second]))

        vm.selectAgent(first.agent.id)
        #expect(vm.focusedPaneID == first.piPane.id)
        vm.focusedPaneID = first.auxiliary[0].id
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
    /// at once.
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
        #expect(vm.mountedTabs.count == 6)

        vm.sweepColdPanes()
        #expect(vm.parkedTabIDs.isEmpty, "nothing parks inside the delay")

        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        #expect(vm.parkedTabIDs == [agents[0].tab.id])
        #expect(!vm.mountedTabs.contains { $0.id == agents[0].tab.id })

        vm.selectAgent(agents[0].agent.id)
        vm.noteActiveTabVisited()
        #expect(vm.parkedTabIDs.isEmpty)
        #expect(vm.mountedTabs.contains { $0.id == agents[0].tab.id })
    }

    @Test func foregroundSettingsAndPaletteRemoveWorkspaceKeyboardOwnership() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("ask", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.piPane.id
        func focus() -> PaneID? {
            AgentLayoutModel.Resolver(vm: vm, visibleTabID: agent.tab.id).model(for: agent.tab).focusedPaneID
        }
        #expect(focus() == agent.piPane.id)
        vm.showSettings = true
        #expect(focus() == nil)
        vm.showSettings = false
        vm.showCommandPalette = true
        #expect(focus() == nil)
        vm.showCommandPalette = false
        vm.showComponentGallery = true
        #expect(focus() == nil)
        vm.showComponentGallery = false
        #expect(focus() == agent.piPane.id)
    }

    /// A layout's parking clock starts when it is shown and then hidden. One nobody has opened is
    /// not mounted: it has no clock and never parks.
    @Test func aShownTerminalLayoutStartsItsParkingClockOnlyOnceHidden() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<8).map { Fixture.agent("a\($0)", in: space, order: $0, auxiliary: 1) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        vm.noteActiveTabVisited()
        #expect(vm.mountedTabs.map(\.id) == [agents[0].tab.id], "nobody else has been shown")
        #expect(vm.tabHiddenSince.isEmpty)
        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        #expect(vm.parkedTabIDs.isEmpty, "the layout on screen never parks")

        for agent in agents[1...5] {
            vm.selectAgent(agent.agent.id)
            vm.noteActiveTabVisited()
        }
        #expect(Set(vm.tabHiddenSince.keys) == Set(agents[0...4].map(\.tab.id)),
                "a clock for each layout shown and hidden since, none for the two nobody opened")
        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        #expect(vm.parkedTabIDs == [agents[0].tab.id], "past the delay and outside the four most recently shown")
        #expect(vm.mountedTabs.count == 5)
        #expect(!vm.mountedTabs.contains { $0.id == agents[6].tab.id || $0.id == agents[7].tab.id })
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

    /// At launch only the visible layout mounts. An agent nobody has opened mounts when it is
    /// shown, once, and switching to it later is a flip.
    @Test func switchingToAnAgentNotYetMountedMountsItOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(6, in: app, mounting: .launch)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) {
            ListPerf.settle(window)
            return vm.threadStores.store(for: agents[0].agent.id).ready
        }
        func scrollViews() -> Set<ObjectIdentifier> {
            func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return Set(all(window.host).map(ObjectIdentifier.init))
        }
        let late = agents[5]
        #expect(vm.mountedTabs.map(\.id) == [agents[0].tab.id], "nobody has shown the others")
        let before = scrollViews()

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        vm.selectAgent(late.agent.id)
        ListPerf.settle(window)
        let mounted = scrollViews().subtracting(before)
        #expect(mounted.count == 1, "its thread mounted")
        #expect(SHRenderProbe.count("deck.mount") == 1)
        #expect(vm.mountedTabs.map(\.id) == [agents[0].tab.id, late.tab.id])
        for agent in [agents[0], late, agents[0], late] {
            vm.selectAgent(agent.agent.id)
            ListPerf.settle(window)
        }

        #expect(scrollViews().isSuperset(of: mounted), "it was never mounted again")
        #expect(SHRenderProbe.count("deck.mount") == 1 && SHRenderProbe.count("deck.unmount") == 0)
    }

    /// The workspace can draw before the restored agents reach it (its first adoption was still
    /// empty): the agents that arrive after the first frame mount when they are shown, and not
    /// before.
    @Test func layoutsThatArriveAfterTheFirstFrameMountWhenShown() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<3 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }

        try await app.server.putState(Fixture.state(spaces: [space], agents: agents))
        try await eventuallyOnMain("the workspace to adopt its agents") { vm.state.agents.count == agents.count }
        ListPerf.settle(window)
        // The adoption landed on one of them; the others have never been shown.
        let landed = try #require(vm.activeTabID)
        let rest = agents.filter { $0.tab.id != landed }
        let landedAgent = try #require(agents.first { $0.tab.id == landed })
        try await eventuallyOnMain("the thread on screen to load", timeout: .seconds(60)) {
            ListPerf.settle(window)
            return vm.threadStores.store(for: landedAgent.agent.id).ready
        }
        func mounted(_ expected: Set<TabID>) -> [TabID] { agents.map(\.tab.id).filter(expected.contains) }
        #expect(vm.mountedTabs.map(\.id) == [landed], "only the one on screen")

        try await MountedWorkspace.show(rest[1], in: vm, window: window)
        #expect(vm.mountedTabs.map(\.id) == mounted([landed, rest[1].tab.id]), "in the stable order")
        let deck = try Self.deck(in: window)
        #expect(deck.pages.count == 2 && deck.pages[rest[0].tab.id] == nil)
        try await MountedWorkspace.show(rest[0], in: vm, window: window)
        #expect(vm.mountedTabs.map(\.id) == agents.map(\.tab.id))
        #expect(deck.pages.count == 3)
    }

    /// The first show mounts a layout, once: every later switch, to it or back, flips hosting views
    /// that were already there, in the order they were added.
    @Test func aFirstShowMountsTheLayoutOnceAndLaterSwitchesFlipIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(4, in: app, mounting: .launch)
        defer { window.close() }
        let deck = try Self.deck(in: window)
        let first = try #require(deck.pages[agents[0].tab.id]?.host)
        func scrollViews(in host: NSView) -> Set<ObjectIdentifier> {
            func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return Set(all(host).map(ObjectIdentifier.init))
        }
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }

        try await MountedWorkspace.show(agents[2], in: vm, window: window)
        #expect(SHRenderProbe.count("deck.mount") == 1)
        let third = try #require(deck.pages[agents[2].tab.id]?.host)
        let thirdScrolls = scrollViews(in: third)
        var order = deck.subviews.map(ObjectIdentifier.init)
        #expect(order == [first, third].map(ObjectIdentifier.init))

        var mounts = 1
        for (step, index) in [0, 2, 3, 2, 0].enumerated() {
            try await MountedWorkspace.show(agents[index], in: vm, window: window)
            if index == 3 { mounts += 1 }
            #expect(SHRenderProbe.count("deck.mount") == mounts, "step \(step) to agent \(index)")
            #expect(SHRenderProbe.count("deck.unmount") == 0, "step \(step) to agent \(index)")
            #expect(deck.pages[agents[0].tab.id]?.host === first)
            #expect(deck.pages[agents[2].tab.id]?.host === third)
            #expect(scrollViews(in: third).isSuperset(of: thirdScrolls), "agent 2's views were never rebuilt")
            let now = deck.subviews.map(ObjectIdentifier.init)
            #expect(now.starts(with: order), "hosts are only ever appended")
            order = now
        }
        #expect(order.count == 3)
    }

    /// The agent the launch picks is shown without anyone selecting it (the fallback writes the
    /// selection directly), and the window records it: switching away from it keeps its layout.
    @Test func theLaunchsOwnSelectionStaysMountedAfterTheFirstSwitch() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<2 {
            var agent = try await app.liveAgent("agent \(index)", in: space, order: index)
            agent.agent.lastActiveAt = Double(2 - index)
            agents.append(agent)
        }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        #expect(vm.selectedAgentID == agents[0].agent.id, "the launch picked the most recently active agent")
        #expect(vm.shownTabIDs.isEmpty, "nothing recorded it yet: only the window does")
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the launch's thread to load", timeout: .seconds(60)) {
            ListPerf.settle(window)
            return vm.threadStores.store(for: agents[0].agent.id).ready
        }
        let deck = try Self.deck(in: window)
        let launch = try #require(deck.pages[agents[0].tab.id]?.host)
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }

        try await MountedWorkspace.show(agents[1], in: vm, window: window)
        try await MountedWorkspace.show(agents[0], in: vm, window: window)

        #expect(deck.pages[agents[0].tab.id]?.host === launch)
        #expect(SHRenderProbe.count("deck.unmount") == 0)
        #expect(SHRenderProbe.count("deck.mount") == 1, "only agent 1's first show")
    }

    /// Typing after switching to an agent for the first time: the layout it just mounted takes
    /// the keyboard, the text lands in its draft alone, and the keyboard is never in a hidden
    /// layout.
    @Test func typingAfterAFirstShowLandsInTheShownAgentsDraftAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(4, in: app, mounting: .launch)
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
        let deck = try Self.deck(in: window)

        for (from, to) in [(0, 1), (1, 2), (2, 3)] {
            vm.selectAgent(agents[from].agent.id)
            vm.focusedPaneID = agents[from].piPane.id
            _ = try await fieldEditor()
            #expect(deck.pages[agents[to].tab.id] == nil, "agent \(to) has not been shown")
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

    /// A terminal a tool opens for an agent nobody has opened runs at once with no layout to draw
    /// it, at the grid this Mac's terminals last reported. The layout mounts when the agent is
    /// shown, and its terminal's surface takes the shell that was already running.
    @Test func aTerminalAToolOpensForAnAgentNobodyOpenedRunsAndShowsWhenOpened() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let shown = try await app.liveAgent("shown", in: space, order: 0, auxiliary: 1)
        let unopened = Fixture.agent("nobody opened", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [shown, unopened]))
        vm.selectAgent(shown.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        let deck = try Self.deck(in: window)

        // The shown agent's terminal draws in its panel and reports the grid it measured.
        vm.terminalPanels.update(.init(host: nil, tab: shown.tab.id)) { $0.shown = true }
        let measuring = try await vm.startHostTerminal(shown.auxiliary[0].id, of: shown.agent.id)
        let server = app.server
        try await eventuallyAsync("the host to take the grid the shown terminal measured", timeout: .seconds(30)) {
            ListPerf.settle(window)
            let grid = "\(measuring.lastRows) \(measuring.lastCols)"
            guard grid != "24 80", TerminalFirstResponder.view(ownedBy: measuring.terminal.model.viewState, in: window.window) != nil else { return false }
            return await server.listSessions().first { $0.id == measuring.sessionID }.map { "\($0.rows) \($0.cols)" } == grid
        }
        let measured = "\(measuring.lastRows) \(measuring.lastCols)"
        #expect(deck.pages[unopened.tab.id] == nil, "nobody has opened the other agent")

        // Its pi opens a terminal beside its thread, running a command that prints this shell's grid.
        let opened = try await app.extensionRequest(.openPane(
            id: 30, agentID: unopened.agent.id, axis: .vertical, cwd: nil, relativeTo: nil,
            command: "printf 'terminal-%s\\n' ready; stty size"))
        guard case .paneOpened(30, let info) = opened else { Issue.record("unexpected reply \(opened)"); return }
        #expect(info.isAlive && !info.isAgentPane)
        let tab = try #require(vm.state.tabs.first { $0.id == unopened.tab.id })
        let terminal = try #require(tab.layout.leaf(withID: info.id))
        let marker = try await readTerminal(terminal.id, for: unopened, in: app, until: { lines in
            lines.contains { $0.contains("terminal-ready") } && !Self.grids(in: lines).isEmpty
        })
        #expect(Self.grids(in: marker) == [measured], "the shell started at the grid already measured")
        #expect(deck.pages[unopened.tab.id] == nil && !vm.mountedTabs.contains { $0.id == unopened.tab.id }, "still no layout")

        // Showing the agent mounts its layout, its panel on that terminal, drawing the same shell.
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        try await MountedWorkspace.show(unopened, in: vm, window: window)
        #expect(SHRenderProbe.count("deck.mount") == 1)
        let key = TerminalPanelKey(host: nil, tab: unopened.tab.id)
        let target = try #require(vm.terminalTarget)
        let panel = vm.terminalPanels.panel(key)
        #expect(target.tabs.map(\.id) == [terminal.id])
        #expect(panel.shown && TerminalPanel.selected(target.tabs, chosen: panel.chosenTab, focused: target.focused)?.id == terminal.id,
                "the panel is up, on the terminal the tool opened")
        let session = try #require(vm.hostPaneSession(terminal.id))
        let sessionID = session.sessionID
        #expect(sessionID == vm.hostTerminalSession(terminal.id), "the pane attaches to the shell that was already running")
        try await eventuallyOnMain("the terminal's surface to draw and attach", timeout: .seconds(30)) {
            ListPerf.settle(window)
            return session.phase == .live && TerminalFirstResponder.view(ownedBy: session.terminal.model.viewState, in: window.window) != nil
        }
        let drawn = "\(session.lastRows) \(session.lastCols)"
        try await eventuallyAsync("the shell to take the grid its surface measured", timeout: .seconds(20)) {
            await server.listSessions().first { $0.id == sessionID }.map { "\($0.rows) \($0.cols)" } == drawn
        }

        // The shell's size follows the surface's report a moment later, so a command typed meanwhile can still see the old one.
        var attempt = 0, printed = ""
        try await eventuallyAsync("a command typed in the shell to print the grid its surface measured", timeout: .seconds(20)) {
            attempt += 1
            let key = "grid\(attempt)"
            let typed = try await app.extensionRequest(.sendPaneInput(id: 31, agentID: unopened.agent.id, paneID: terminal.id, text: "echo \(key)=$(stty size)", submit: true))
            guard case .ok = typed else { return false }
            let screen = try await self.readTerminal(terminal.id, for: unopened, in: app, until: { $0.contains { $0.hasPrefix("\(key)=") } })
            printed = screen.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
            return printed == drawn
        }
        #expect(printed == drawn, "the shell prints the grid its surface measured")
    }

    /// An agent nobody has opened has no layout and needs none: a status report reaches its
    /// sidebar row and redraws no layout, and a request for its thread starts its pi and is served.
    @Test func anAgentNobodyOpenedWorksWithoutItsLayout() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents = (0..<2).map { Fixture.agent("worker \($0)", in: space, order: $0, piSession: SessionID()) }
        for index in agents.indices { agents[index].agent.lastActiveAt = Double(2 - index) }
        let (shown, unopened) = (agents[0], agents[1])
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents), restoringAgents: true)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the shown thread to serve", timeout: .seconds(60)) {
            ListPerf.settle(window)
            return vm.threadStores.store(for: shown.agent.id).ready
        }
        let deck = try Self.deck(in: window)
        func row() -> SidebarListRow? { vm.sidebarLists.all.first { $0.id.agentID == unopened.agent.id } }
        let rowBefore = try #require(row())
        #expect(deck.pages[unopened.tab.id] == nil)

        var next = vm.state
        let index = try #require(next.agents.firstIndex { $0.id == unopened.agent.id })
        next.agents[index].status = .working
        let counts = ListPerf.counting { ListPerf.time(window) { vm.adopt(next) } }

        #expect(row() != rowBefore, "the report reached its sidebar row")
        #expect(counts["sidebar.row", default: 0] > 0, "\(counts)")
        for key in ["layout.agentLayout", "layout.paneTreeGeo", "thread.view", "composer.body", "deck.update", "deck.mount"] {
            #expect(counts[key, default: 0] == 0, "\(key): \(counts)")
        }
        let server = app.server
        _ = try? await server.nativeThread(agentID: unopened.agent.id, request: .snapshot())
        try await eventuallyAsync("its thread to be served", timeout: .seconds(30)) {
            if case .snapshot? = try? await server.nativeThread(agentID: unopened.agent.id, request: .snapshot()) { return true }
            return false
        }
        #expect(await startedAgents(on: server).contains(unopened.agent.id), "asking for the thread started its pi")
        ListPerf.settle(window)
        #expect(deck.pages[unopened.tab.id] == nil && !vm.mountedTabs.contains { $0.id == unopened.tab.id })
    }

    /// The screen a tool's terminal printed, once `done` holds of it.
    private func readTerminal(_ pane: PaneID, for agent: AgentFixture, in app: AppHarness,
                              until done: @escaping ([String]) -> Bool) async throws -> [String] {
        var lines: [String] = []
        try await eventuallyAsync("the terminal to print what the test waits for", timeout: .seconds(20)) {
            let reply = try await app.extensionRequest(.readPane(id: 32, agentID: agent.agent.id, paneID: pane))
            guard case .paneContent(_, _, let content) = reply else { return false }
            lines = content
            return done(content)
        }
        return lines
    }

    /// The "rows cols" lines `stty size` printed.
    private static func grids(in lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            let words = line.split(separator: " ")
            return words.count == 2 && words.allSatisfy { $0.allSatisfy(\.isNumber) }
        }
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

    @Test func hiddenContentCatchesUpAfterResizingBackToTheSameSize() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(2, in: app)
        defer { window.close() }
        let deck = try Self.deck(in: window)
        let first = try #require(deck.pages[agents[0].tab.id]?.host)
        let initialSize = window.host.bounds.size
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        func containsDraft(_ view: NSView, text: String) -> Bool {
            (view as? NSTextView)?.string == text || view.subviews.contains { containsDraft($0, text: text) }
        }
        let existing = Set(scrolls(first).map(ObjectIdentifier.init))
        #expect(!existing.isEmpty)
        vm.selectAgent(agents[1].agent.id)
        let store = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the outgoing real thread to suspend") {
            ListPerf.settle(window)
            return first.isHidden && !store.isLive
        }
        let draft = "Updated while hidden, including e\u{301} and 🐑"
        store.draft = draft
        window.window.setContentSize(CGSize(width: initialSize.width - 160, height: initialSize.height - 80))
        ListPerf.settle(window)
        window.window.setContentSize(initialSize)
        ListPerf.settle(window)
        vm.selectAgent(agents[0].agent.id)
        try await eventuallyOnMain("the same host to catch up without a new frame size") {
            ListPerf.settle(window)
            return !first.isHidden && store.isLive && containsDraft(first, text: draft)
        }
        #expect(deck.pages[agents[0].tab.id]?.host === first)
        #expect(Set(scrolls(first).map(ObjectIdentifier.init)) == existing,
                "the real composer/thread must catch up without replacing scroll views")
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
    @Test(arguments: [3, 112])
    func anEnvironmentChangeReachesLayoutsHiddenWhenItChanged(agentCount: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(agentCount, in: app)
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
        #expect(frames() == [narrow, narrow, start], "the revealed layout catches up; the outgoing layout keeps its last size")

        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window.window)
        ListPerf.settle(window)
        #expect(frames() == [narrow, narrow, start], "ending resize must not reflow layouts that stayed hidden")
        vm.selectAgent(agents[2].agent.id)
        ListPerf.settle(window)
        #expect(frames() == Array(repeating: narrow, count: agents.count), "a hidden layout catches up synchronously when revealed")
    }

    /// A hidden layout is built when it mounts, its terminal surface included, and still takes
    /// its values while hidden: its thread stops polling and its terminal stops drawing, and the
    /// agent shown instead starts both. The hosts stay in mount order.
    @Test func hiddenLayoutsSuspendTheirThreadAndStopTheirTerminalsDrawing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<3 {
            var agent = try await app.liveAgent("agent \(index)", in: space, order: index, auxiliary: 1)
            agent.agent.lastActiveAt = Double(3 - index)
            agents.append(agent)
        }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        MountedWorkspace.markEveryLayoutShown(vm)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        let deck = try Self.deck(in: window)
        // The host runs every layout's shell, hidden or not.
        var terminals: [AppTerminalModel] = []
        for agent in agents { terminals.append(try await vm.startHostTerminal(agent.auxiliary[0].id, of: agent.agent.id).terminal) }

        for shown in [0, 2, 1, 0] {
            vm.selectAgent(agents[shown].agent.id)
            try await eventuallyOnMain("only agent \(shown)'s thread and terminal to be live") {
                ListPerf.settle(window)
                return agents.indices.allSatisfy { index in
                    let agent = agents[index]
                    let terminal = terminals[index].model
                    guard let surface = TerminalFirstResponder.view(ownedBy: terminal.viewState, in: window.window) else { return false }
                    let visible = index == shown
                    return vm.threadStores.store(for: agent.agent.id).isLive == visible
                        && terminal.renderingActive == visible
                        && surface.isHiddenOrHasHiddenAncestor == !visible
                }
            }
            #expect(deck.subviews.map(ObjectIdentifier.init) == vm.mountedTabs.compactMap { deck.pages[$0.id].map { ObjectIdentifier($0.host) } })
        }
    }

    /// The outer graph's overlays (the overlaid sidebar, the palette) sit over the deck: a click
    /// there reaches them, never the layout under them.
    @Test func overlaysOverTheWorkspaceTakeTheirClicksFromTheDeck() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(2, in: app)
        let size = CGSize(width: AppLayout.windowMinWidth, height: 700)
        let window = OffscreenWindow(size: size, dark: true, RootView(vm: vm).environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        try await eventuallyOnMain("every layout to mount and the narrow window to hide the sidebar") {
            ListPerf.settle(window)
            return vm.mountedTabs.count == agents.count && vm.sidebarAutoHidden
        }
        let deck = try Self.deck(in: window)
        let root = try #require(window.window.contentView)
        func inDeck(_ point: CGPoint) throws -> Bool {
            let hit = try #require(root.hitTest(root.isFlipped ? point : CGPoint(x: point.x, y: root.bounds.height - point.y)))
            return hit.isDescendant(of: deck)
        }
        let overSidebar = CGPoint(x: 120, y: 300)
        let overPalette = CGPoint(x: size.width / 2, y: size.height * 0.18 + 30)
        #expect(try inDeck(overSidebar) && inDeck(overPalette), "the layout takes clicks with nothing over it")

        vm.toggleSidebar()
        try await eventuallyOnMain("the sidebar to overlay the workspace") { ListPerf.settle(window); return vm.sidebarOverlayShown }
        ListPerf.settle(window)
        #expect(try !inDeck(overSidebar))
        vm.dismissSidebarOverlay()
        vm.showCommandPalette = true
        try await eventuallyOnMain("the palette to cover the workspace") { ListPerf.settle(window); return try !inDeck(overPalette) }
    }

    /// The workspace's deck of layouts.
    static func deck(in window: OffscreenWindow) throws -> AgentLayoutDeck.Container {
        func find(_ view: NSView) -> AgentLayoutDeck.Container? {
            (view as? AgentLayoutDeck.Container) ?? view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(window.window.contentView!))
    }
}
