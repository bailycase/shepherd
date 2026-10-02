import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Window, sidebar, toolbar, palette, and right pane (Navigation board). An extension of the
/// serialized preview suite, so these renders never interleave with the others.
extension PreviewTests {
    // MARK: Sidebar

    /// Agents in every status, most recently active first: a working one whose subagent waits on
    /// you and one blocked on a question (both in Needs you, with their reasons), one with
    /// finished subagents (no mark), one whose turn failed, a worktree agent, an agent in a second
    /// project, an automation's settled run, and an unreachable host (More ▸ Hosts says so). The
    /// palette lists the subagents.
    private func populatedWorkspace() async throws -> (PreviewWorkspace, [Agent]) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let other = Space(name: "billing-service", path: workspace.dir.appendingPathComponent("billing").path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let rows: [(String, AgentStatus, String?)] = [
            ("Plan shepherd extensions", .working, nil), ("Dock review pane", .blocked, "worktree/dock-review"),
            ("Fix remote subagent deletion", .idle, nil), ("Investigate SwiftUI live preview", .working, nil),
            ("Fix remote nightly", .done, nil), ("Fix agent deletion workflow", .idle, nil),
            ("Bump the Sparkle feed", .done, nil),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let now = Date().timeIntervalSince1970 * 1000
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1, branch: row.2)
            agent.lastActiveAt = now - Double(index) * 60_000
            agents.append(agent); tabs.append(tab)
        }
        agents[1].waitingOn = "Approve the plan?"
        agents[1].waitingReason = "approve plan"
        agents[3].checkout = AgentCheckout(branch: "agent/swiftui-previews", changedFiles: 4)
        var (billing, billingTab) = try await workspace.agent("Migrate invoices to v2", in: other, order: 0, status: .idle)
        billing.lastActiveAt = now - 30 * 60_000
        agents.append(billing); tabs.append(billingTab)
        var (run, runTab) = try await workspace.agent("Merge PR #24 after CI", in: runs, order: 0, status: .done)
        run.lastActiveAt = now - 3.5 * 60_000
        agents.append(run); tabs.append(runTab)
        let automation = Automation(name: "Merge PR #24 after CI", prompt: "watch", cwd: workspace.dir.path, enabled: false,
                                    agentID: run.id)
        try await workspace.seed(ShepherdState(spaces: [space, other, runs], tabs: tabs, agents: agents, automations: [automation]))
        let vm = workspace.vm
        vm.selectAgent(agents[3].id)
        vm.statusSince[agents[0].id] = Date().addingTimeInterval(-8 * 60)
        vm.statusSince[agents[3].id] = Date().addingTimeInterval(-31)
        vm.failedTurns.insert(agents[6].id)
        vm.applyAgentChildren(agents[3].id, Array(Threads.liveRuns.prefix(3)))
        vm.applyAgentChildren(agents[4].id, Threads.doneRuns)
        vm.remoteHosts.addHost(name: "Horizon", host: "127.0.0.1", port: 1, token: "x")
        return (workspace, agents)
    }

    /// The sidebar at each row density (NWNavigation's Standard and Compact samples).
    @Test(arguments: NWDensity.allCases)
    func sidebar(density: NWDensity) async throws {
        let (workspace, _) = try await populatedWorkspace()
        defer { workspace.stop() }
        try await Preview.render("sidebar-\(density.rawValue)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 760)) {
            SidebarView(vm: workspace.vm).nwDensity(density)
        }
    }

    /// NWNavigation revision 420: all groups, independently folded groups, no Done, reading
    /// Done, empty and long titles, through the same state, pin and completion paths as the app.
    @Test(arguments: ["full", "collapsed", "allCollapsed", "doneCollapsed", "nodone", "selectedDone", "afterReadingDone", "empty", "long"])
    func sidebarActivity(state sample: String) async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.settings.designToolEnabled = true
        var state = vm.state
        state.designs = [Design(name: "Checkout funnel dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4),
                         Design(name: "Onboarding flow", createdAt: 1, lastActiveAt: 1, boardCount: 2)]
        if sample == "long" {
            state.agents[0].name = "Investigate SwiftUI live preview with a title that extends well beyond the sidebar width"
            state.designs[0].name = "Checkout funnel dashboard with unusually long board and project names"
        }
        if sample == "empty" { state = ShepherdState() }
        try await workspace.seed(state)
        if sample != "empty" {
            vm.pinThread(.local(agents[2].id))
            var time = Date().addingTimeInterval(-40)
            vm.sidebarActivityLast[agents[3].id] = time
            for gap in [5.0, 2, 7, 3, 6, 1, 4, 2, 3, 1] {
                time = time.addingTimeInterval(gap)
                vm.recordSidebarActivity(agents[3].id, at: time)
            }
            if sample == "collapsed" { vm.collapsedActivitySections = [.working, .recents, .designs] }
            if sample == "allCollapsed" { vm.collapsedActivitySections = Set(SidebarActivitySection.allCases) }
            if sample == "doneCollapsed" { vm.collapsedActivitySections = [.done] }
            if sample == "nodone" { vm.markAllSidebarDoneSeen() }
            if sample == "selectedDone" || sample == "afterReadingDone" { vm.selectAgent(agents[4].id) }
            if sample == "afterReadingDone" {
                vm.selectAgent(agents[3].id)
                #expect(!vm.sidebarLists.done.contains { $0.id == .local(agents[4].id) })
                #expect(vm.sidebarLists.recents.contains { $0.id == .local(agents[4].id) })
            }
        }
        try await Preview.renderMatrix("sidebar-activity-\(sample)", size: CGSize(width: 232, height: 820)) {
            SidebarView(vm: vm).nwDensity(.standard)
        }
    }

    @Test(arguments: [NativeGoalState.working, .checking])
    func sidebarActiveGoal(state: NativeGoalState) async throws {
        let w = try PreviewWorkspace()
        defer { w.stop() }
        let file = w.dir.appendingPathComponent("goal.json")
        let goal = NativeGoal(id: "00000000-0000-0000-0000-000000000001", text: "Sidebar checks pass", state: state)
        try Data("null".utf8).write(to: file)
        let info = try await w.server.createSession(params: CreateSessionParams(cwd: w.dir.path, command: StubPi.command,
            env: ["STUB_PI_GOAL_FILE": file.path, "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "0"], runtime: .rpc))
        let space = Space(name: "Shepherd", path: w.dir.path)
        let id = AgentID()
        let pane = LeafPane(sessionID: info.id, cwd: space.path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "Fix sidebar grouping", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await w.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = w.vm, server = w.server
        try await eventuallyAsync("the disabled goal controller to be ready") {
            guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return !snapshot.piSessionID.isEmpty && snapshot.goal == nil
        }
        w.settings.goalsEnabled = true
        server.setGoalsEnabled(true)
        try await eventuallyAsync("the enabled goal controller") {
            guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.supportedActions.contains("goal") && snapshot.goal == nil
        }
        try JSONEncoder().encode(goal).write(to: file, options: .atomic)
        try await eventuallyAsync("the live goal widget") {
            guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.goal?.state == state && !snapshot.running
        }
        try await eventuallyOnMain("the active goal in Working") { vm.sidebarLists.working.map(\.id) == [.local(id)] }
        try await Preview.renderMatrix("sidebar-goal-\(state.rawValue)", size: CGSize(width: 232, height: 820)) {
            SidebarView(vm: vm).nwDensity(.standard)
        }
    }

    @Test func sidebarOpeningThread() async throws {
        try StubPi.installAsEngine()
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try Data(#"{"gate":"release-pi"}"#.utf8)
            .write(to: workspace.dir.appendingPathComponent("stub-pi-startup.json"))
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        try await workspace.seed(ShepherdState(spaces: [space]))
        let config = NewAgentConfig(spaceID: space.id, workingDirectory: space.path,
                                    thinking: .medium, initialPrompt: "Fix the sidebar startup jump")
        let id = try await workspace.vm.startAgent(config, focusWindow: false)
        #expect(workspace.vm.sidebarLists.working.map(\.id) == [.local(id)])
        #expect(workspace.vm.sidebarLists.recents.isEmpty)
        try await Preview.renderMatrix("sidebar-opening-thread", size: CGSize(width: 232, height: 820)) {
            SidebarView(vm: workspace.vm).nwDensity(.standard)
        }
    }

    /// Needs you's reasons (NWNavigation, Main): the agent's own word or two when its asking tool
    /// gave one ("retention?", "approve plan"), the question cut short when it gave none, and an
    /// asking subagent's own reason ("token names?") beside one that gave none (its name).
    @Test func sidebarNeedsYouReasons() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let rows: [(String, AgentStatus, String?, String?)] = [
            ("Checkout funnel events", .blocked, "Retention: 30 days or 13 months?", "retention?"),
            ("Deploy media stack", .blocked, "How should I handle Horizon’s uncommitted edits?", nil),
            ("Restyle native UI", .working, nil, nil),
            ("Dock review pane", .blocked, "Approve the plan as written?", "approve plan"),
            ("Triage new Sentry issues", .working, nil, nil),
            ("Fix pay button jump", .done, nil, nil),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let now = Date().timeIntervalSince1970 * 1000
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1)
            agent.lastActiveAt = now - Double(index) * 60_000
            agent.waitingOn = row.2
            agent.waitingReason = row.3
            agents.append(agent); tabs.append(tab)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = workspace.vm
        var labelled = Threads.liveRuns[1]
        labelled.question?.short = "token names?"
        vm.applyAgentChildren(agents[2].id, [labelled])
        vm.applyAgentChildren(agents[4].id, [Threads.liveRuns[1]])
        try await Preview.render("sidebar-needs-you-reasons", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 620)) {
            SidebarView(vm: vm)
        }
    }

    /// An agent whose pi stopped before it served, among healthy ones: "can't start" in red,
    /// with the red dot (Sidebar, Thread › Can't start).
    @Test func sidebarCannotStart() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let rows: [(String, AgentStatus)] = [
            ("Restyle native UI", .working), ("Triage Linear issues", .idle), ("Fix pay button jump", .done),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let now = Date().timeIntervalSince1970 * 1000
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1)
            agent.lastActiveAt = now - Double(index) * 60_000
            agents.append(agent); tabs.append(tab)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = workspace.vm
        vm.cannotStart = [agents[1].id]
        try await Preview.render("sidebar-cannot-start", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 440)) {
            SidebarView(vm: vm)
        }
    }

    /// PiAuthStates' agents: one the first launch's copy holds ("waiting", a clock), one not signed
    /// in (in Needs you, "sign in"), among healthy ones (PiImportProgress, AgentNotSignedIn).
    @Test func sidebarWaitingAndNotSignedIn() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let rows: [(String, AgentStatus)] = [
            ("Investigate SwiftUI live preview", .idle), ("Plan shepherd extensions", .idle), ("Fix terminal output buffer", .idle),
            ("Merge PR #24 after CI", .done),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let now = Date().timeIntervalSince1970 * 1000
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1)
            agent.lastActiveAt = now - Double(index) * 60_000
            agents.append(agent); tabs.append(tab)
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = workspace.vm
        vm.notSignedIn = [agents[0].id: NotSignedIn(provider: "anthropic", at: Date())]
        vm.cannotStart = [agents[0].id]
        vm.waitingForImport = [agents[1].id]
        try await Preview.render("sidebar-waiting-and-sign-in", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 460)) {
            SidebarView(vm: vm)
        }
    }

    /// More open with Hosts selected (NavHosts): Hosts says how many hosts are offline, and
    /// Extensions follows.
    @Test func sidebarMoreHosts() async throws {
        let (workspace, _) = try await populatedWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openDestination(.hosts)
        try await Preview.render("sidebar-more-hosts", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 520),
                                 ready: { vm.offlineHostCount == 1 }) {
            SidebarView(vm: vm)
        }
    }

    /// Pinned comes first, in pin order, including the thread waiting on the user.
    @Test func sidebarPinned() async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        for index in [4, 2, 1] { vm.pinThread(.local(agents[index].id)) }
        #expect(vm.sidebarLists.pinned.map(\.title) == ["Fix remote nightly", "Fix remote subagent deletion", "Dock review pane"])
        #expect(vm.sidebarLists.needsYou.isEmpty)
        try await Preview.render("sidebar-pinned", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 760)) {
            SidebarView(vm: vm)
        }
    }

    /// The same pinned thread in every status: its row never moves into a status group.
    @Test(arguments: AgentStatus.allCases)
    func sidebarPinnedStatus(status: AgentStatus) async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        var state = workspace.vm.state
        state.agents[2].status = status
        if status == .blocked {
            state.agents[2].waitingOn = "Approve the plan?"
            state.agents[2].waitingReason = "approve plan"
        }
        try await workspace.seed(state)
        let vm = workspace.vm, row = SidebarRowID.local(agents[2].id)
        vm.pinThread(row)
        #expect(vm.sidebarLists.pinned.map(\.id) == [row])
        #expect((vm.sidebarLists.needsYou + vm.sidebarLists.working + vm.sidebarLists.done + vm.sidebarLists.recents)
            .allSatisfy { $0.id != row })
        try await Preview.render("sidebar-pinned-\(status.rawValue)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 760)) {
            SidebarView(vm: vm)
        }
    }

    /// The same sidebar with ⌘ held: Pinned's rows wear the first digits, and Recents' follow.
    @Test func sidebarPinnedDigits() async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        for index in [4, 2] { vm.pinThread(.local(agents[index].id)) }
        vm.showAgentShortcutBadges = true
        try await Preview.render("sidebar-pinned-digits", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 760)) {
            SidebarView(vm: vm)
        }
    }

    /// This Mac's automation runs in Recents: a run whose pi is still starting (it reads running,
    /// never done), a settled run, and one asking (in Needs you, its bolt in lantern).
    @Test func sidebarAutomations() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let (work, workTab) = try await workspace.agent("Plan shepherd extensions", in: space, order: 0, status: .done)
        var agents = [work], tabs = [workTab], automations: [Automation] = []
        for (index, (name, status)) in [("Merge PR #24 after CI", AgentStatus?.some(.idle)), ("Nightly migrations dry run", .done),
                                        ("Triage new issues", .blocked), ("Stale branch cleanup", nil)].enumerated() {
            // Off, so the first adoption starts no run for the stopped one.
            var automation = Automation(name: name, prompt: "watch", cwd: workspace.dir.path, enabled: false)
            if let status {
                let (agent, tab) = try await workspace.agent(name, in: runs, order: index, status: status)
                agents.append(agent); tabs.append(tab)
                automation.agentID = agent.id
            }
            automations.append(automation)
        }
        try await workspace.seed(ShepherdState(spaces: [space, runs], tabs: tabs, agents: agents, automations: automations))
        let vm = workspace.vm
        let starting = try #require(vm.automationRun(automations[0], agent: vm.automationAgent(automations[0])))
        #expect(AutomationRow.isLive(vm.automationAgent(automations[0]), run: starting))

        try await Preview.render("sidebar-automations", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 480)) {
            SidebarView(vm: vm)
        }
    }

    // MARK: Window

    /// A live (stub) agent after one turn, beside a working one.
    private func liveWindow() async throws -> (PreviewWorkspace, NativeThreadStore) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        var (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, status: .done, live: true,
                                                     branch: "pi/swiftui-previews")
        // The header's branch chip, as the host would read it.
        agent.checkout = AgentCheckout(branch: "pi/swiftui-previews", changedFiles: 3)
        let (other, otherTab) = try await workspace.agent("Dock review pane", in: space, order: 1, status: .working, live: true)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab, otherTab], agents: [agent, other]))
        let server = workspace.server
        try await eventuallyAsync("pi to be ready") {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return !snapshot.piSessionID.isEmpty
        }
        let snapshot = try await server.nativeThread(agentID: agent.id, request: .snapshot())
        if case .snapshot(let ready) = snapshot {
            _ = try await server.nativeThread(agentID: agent.id, request: .send(
                expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(),
                text: "List the files in this checkout.", delivery: .followUp))
        }
        workspace.vm.selectAgent(agent.id)
        return (workspace, workspace.vm.threadStores.store(for: agent.id))
    }

    /// The full window at its default size, and at the minimum, where the sidebar hides (the
    /// toolbar leads with the sidebar button) and the thread takes the whole column.
    @Test(arguments: [("app-window", CGSize(width: 1440, height: 900)), ("app-window-minimum", CGSize(width: 720, height: 600))])
    func appWindow(surface: String, size: CGSize) async throws {
        let (workspace, store) = try await liveWindow()
        defer { workspace.stop() }
        try await Preview.render(surface, size: size, ready: { store.ready && store.messages.contains { $0.toolName == "bash" } }) {
            RootView(vm: workspace.vm)
        }
    }

    /// pi opened a review with the side pane closed (PaneStates · SidePaneButton · pane closed):
    /// nothing opens, the header's button takes the dot, and its tip says what pi opened.
    @Test func appWindowSidePaneNews() async throws {
        let (workspace, store) = try await liveWindow()
        defer { workspace.stop() }
        let vm = workspace.vm
        let agentID = try #require(vm.selectedAgentID)
        vm.subagentInspector.addNews(.local(agentID), .changes)
        try await Preview.render("app-window-side-pane-news", size: CGSize(width: 1440, height: 900),
                                 ready: { store.ready && store.messages.contains { $0.toolName == "bash" } }) {
            RootView(vm: vm)
        }
    }

    /// The one-time note under the toolbar after an update moved Shepherd off the retired
    /// nightly channel, in the default window's column and the minimum window's.
    @Test(arguments: [("notice-nightly-moved", 1208.0), ("notice-nightly-moved-minimum", AppLayout.mainColumnMinWidth)])
    func nightlyMovedNotice(surface: String, width: CGFloat) async throws {
        try await Preview.render(surface, size: CGSize(width: width, height: 120)) {
            // A fixed width, as the window's minimum width gives the column: proposed no width,
            // the wrapping message would grow without bound.
            NightlyMovedNotice(download: {}, dismiss: {})
                .frame(width: width, height: 120, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    /// The minimum window with the sidebar called up: it overlays the thread. Captured once its
    /// slide has settled to the last fraction of a point (about 1.7× the pane's anchor).
    @Test func appWindowMinimumWithSidebarOverlay() async throws {
        let (workspace, store) = try await liveWindow()
        defer { workspace.stop() }
        var shownAt: ContinuousClock.Instant?
        try await Preview.render("app-window-minimum-sidebar", size: CGSize(width: 720, height: 600), ready: {
            guard store.ready, workspace.vm.sidebarAutoHidden else { return false }
            if !workspace.vm.sidebarOverlayShown { workspace.vm.toggleSidebar() }
            let shown = shownAt ?? .now
            shownAt = shown
            return ContinuousClock.now - shown > .seconds(NW.Motion.pane.duration * 2)
        }) {
            RootView(vm: workspace.vm)
        }
    }

    /// A terminal beside the thread with the review open: the terminal panel sits under the
    /// thread, and the review docks at the window's trailing edge beside the whole layout at its
    /// full height (the main column decides, not the thread's share).
    @Test func appWindowReviewBesideASplitLayout() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        var (agent, tab) = try await workspace.agent("Dock review pane", in: space, order: 0, live: true)
        agent.checkout = AgentCheckout(branch: "chore/dock-review", changedFiles: 2)
        let terminal = LeafPane(cwd: space.path)
        var split = tab
        split.layout = .split(axis: .vertical, ratio: 0.5, first: tab.layout, second: .leaf(terminal))
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [split], agents: [agent]))
        let files = Reviews.session().files
        vm.changesEngineOverride = { _, _ in
            ChangesBoard.engine(files, list: ChangesBoard.listed(files, scope: .uncommitted,
                                                                  comparison: ChangesComparison(head: "Working tree", base: "HEAD")))
        }
        vm.selectAgent(agent.id)
        vm.toggleRightPane()
        let store = vm.threadStores.store(for: agent.id)
        let shell = vm.sessions.session(for: terminal, in: split)
        try await Preview.render("app-window-review-split", size: CGSize(width: 1440, height: 900), ready: {
            store.ready && shell.phase == .live && vm.reviewSessions.values.first?.isLoading == false
        }) {
            RootView(vm: vm)
        }
    }

    /// The side pane maximized over the window (ChangesWide): its 52pt rail with the window
    /// controls and Back to the thread in place of the sidebar and the toolbar, the file list
    /// beside the diff.
    @Test func appWindowChangesWide() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        var (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
        agent.checkout = AgentCheckout(branch: "agent/refund-events", changedFiles: 5)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let files = Reviews.session().files
        vm.changesEngineOverride = { _, _ in
            ChangesBoard.engine(files, list: ChangesBoard.listed(files, scope: .uncommitted,
                                                                  comparison: ChangesComparison(head: "Working tree", base: "HEAD")))
        }
        vm.selectAgent(agent.id)
        vm.toggleRightPane()
        vm.toggleSidePaneMaximized(.local(agent.id))
        #expect(vm.isSidePaneWide)
        try await Preview.render("app-window-changes-wide", size: CGSize(width: 1440, height: 900), ready: {
            vm.reviewSessions.values.first?.isLoading == false
        }) {
            RootView(vm: vm)
        }
    }

    /// The terminal panel (TerminalSplit, TerminalStates boards): two tabs under the thread, then
    /// the same panel maximized over the folded thread.
    @Test(arguments: [false, true])
    func appWindowTerminalPanel(maximized: Bool) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
        let thread = try #require(agent.paneID)
        let shell = LeafPane(cwd: space.path), second = LeafPane(cwd: space.path)
        var panel = tab
        // + twice from the thread: each new terminal is a tab, the newer nearer the thread.
        panel.layout = tab.layout.splitting(pane: thread, axis: .horizontal, newPane: shell)!
            .splitting(pane: thread, axis: .horizontal, newPane: second)!
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [panel], agents: [agent]))
        vm.selectAgent(agent.id)
        let key = TerminalPanelKey(host: nil, tab: panel.id)
        vm.terminalPanels.update(key) {
            $0.shown = true
            $0.chosenTab = shell.id
            $0.maximized = maximized
        }
        let store = vm.threadStores.store(for: agent.id)
        let shells = [shell, second].map { vm.sessions.session(for: $0, in: panel) }
        try await Preview.render(maximized ? "app-window-terminal-maximized" : "app-window-terminal-panel",
                                 size: CGSize(width: 1440, height: 900), ready: {
            (maximized || store.ready) && shells.allSatisfy { $0.phase == .live } && vm.terminalPanels.activity[key]?.count == 2
        }) {
            RootView(vm: vm)
        }
    }

    /// A tab that runs a command (Tab states): its spinner and the command's name in the strip,
    /// beside the tab on screen.
    @Test func appWindowTerminalRunningTab() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
        let thread = try #require(agent.paneID)
        let shell = LeafPane(cwd: space.path), dev = LeafPane(cwd: space.path)
        var panel = tab
        panel.layout = tab.layout.splitting(pane: thread, axis: .horizontal, newPane: shell)!
            .splitting(pane: thread, axis: .horizontal, newPane: dev)!
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [panel], agents: [agent]))
        vm.selectAgent(agent.id)
        let key = TerminalPanelKey(host: nil, tab: panel.id)
        vm.terminalPanels.update(key) {
            $0.shown = true
            $0.chosenTab = shell.id
        }
        let store = vm.threadStores.store(for: agent.id)
        let shells = [shell, dev].map { vm.sessions.session(for: $0, in: panel) }
        let session = try #require(await vm.sessions.awaitSession(forPane: dev.id, timeout: .seconds(10)))
        vm.server.typeCommand("sleep 600", sessionID: session)
        try await Preview.render("app-window-terminal-running", size: CGSize(width: 1440, height: 900), ready: {
            store.ready && shells.allSatisfy { $0.phase == .live } && vm.terminalPanels.activity[key]?[dev.id]?.isRunning == true
        }) {
            RootView(vm: vm)
        }
    }

    /// The menu on a tab (TerminalStates › NewTerminalMenu), opened from + over the panel.
    @Test func appWindowTerminalMenu() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "payments", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
        let thread = try #require(agent.paneID)
        let shell = LeafPane(cwd: space.path, title: "go test"), logs = LeafPane(cwd: space.path)
        var panel = tab
        panel.layout = tab.layout.splitting(pane: thread, axis: .horizontal, newPane: shell)!
            .splitting(pane: thread, axis: .horizontal, newPane: logs)!
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [panel], agents: [agent]))
        vm.selectAgent(agent.id)
        let key = TerminalPanelKey(host: nil, tab: panel.id)
        vm.terminalPanels.update(key) {
            $0.shown = true
            $0.chosenTab = shell.id
        }
        vm.terminalPanels.menu = TerminalMenuRequest(key: key, tab: shell.id, anchor: 150)
        let store = vm.threadStores.store(for: agent.id)
        let shells = [shell, logs].map { vm.sessions.session(for: $0, in: panel) }
        try await Preview.render("app-window-terminal-menu", size: CGSize(width: 1440, height: 900), ready: {
            store.ready && shells.allSatisfy { $0.phase == .live }
        }) {
            RootView(vm: vm)
        }
    }

    /// The terminal boards' parts (TerminalPane, TerminalStates): the thread folded over a
    /// maximized panel, the bar beside a selection, the menu on a tab, and the panel's edge while
    /// it is dragged.
    @Test func terminalParts() async throws {
        let size = CGSize(width: 760, height: 360)
        try await Preview.render("terminal-parts", size: size) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                NWTerminalFoldedThread(title: "Add refund events", state: .idle, restoreShortcut: "⇧⌘↩") {}
                NWTerminalSelectionBar(add: {}, copy: {})
                NWTerminalMenu {
                    NWChangesMenuRow("New terminal in the worktree", subtitle: "payments on build-01", systemImage: "terminal",
                                     trailing: .chord("⌘D"), tallHeight: NWTerminalMetrics.menuTallRowHeight) {}
                    NWChangesMenuRow("Rename tab", systemImage: "pencil") {}
                    NWChangesMenuRow("Kill process", systemImage: "xmark", enabled: false) {}
                }
                ZStack(alignment: .top) {
                    NWTerminalTabBar([NWTerminalTab(id: "zsh", title: "zsh", host: "build-01")], selection: "zsh", select: { _ in },
                                     close: { _ in }, newTab: {}) {}
                    Color.nw.lantern.frame(height: AppLayout.terminalDividerDragLine).offset(y: -1)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    /// The window with the sidebar hidden: the toolbar runs under the window controls.
    @Test func sidebarHiddenHeader() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, live: true)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        workspace.vm.sidebarHidden = true
        workspace.vm.selectAgent(agent.id)
        let store = workspace.vm.threadStores.store(for: agent.id)
        try await Preview.render("sidebar-hidden-header", size: CGSize(width: 1280, height: 800), ready: { store.ready }) {
            RootView(vm: workspace.vm)
        }
    }

    // MARK: New thread

    /// The New thread page (NavNewThread): with a project and a running thread (its Continue
    /// card), with no project at all, and at the minimum window.
    @Test(arguments: [("new-thread", 1280.0), ("new-thread-empty", 1280.0), ("new-thread-minimum", 720.0)])
    func newThread(surface: String, width: CGFloat) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        if surface != "new-thread-empty" {
            let space = Space(name: "shepherd", path: workspace.dir.path)
            var (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, status: .working)
            agent.lastActiveAt = Date().timeIntervalSince1970 * 1000
            try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
            vm.statusSince[agent.id] = Date().addingTimeInterval(-42 * 60)
        }
        vm.openNewThread()
        try await Preview.render(surface, size: CGSize(width: width, height: 760)) {
            RootView(vm: vm)
        }
    }

    @Test(arguments: [720.0, 1280.0])
    func newThreadWithFullModelControls(width: CGFloat) async throws {
        let listing = ModelListing(models: ["openai/gpt-5.4"], defaultModel: "openai/gpt-5.4",
                                   thinkingLevels: ["openai/gpt-5.4": ["off", "low", "medium", "high", "xhigh"]],
                                   serviceTiers: ["openai/gpt-5.4": ["standard", "fast"]])
        let workspace = try PreviewWorkspace(modelCatalog: { listing })
        defer { workspace.stop() }
        let vm = workspace.vm
        try await workspace.seed(ShepherdState(spaces: [Space(name: "shepherd", path: workspace.dir.path)]))
        vm.openNewThread()
        try await eventuallyOnMain("creation model controls to load") { !vm.newThread.loadingDefaults }
        vm.newThread.setModel("openai/gpt-5.4")
        vm.newThread.setThinking(.xhigh)
        vm.newThread.setServiceTier(.fast)
        vm.newThread.prompt = "Fix the new thread controls"
        try await Preview.render("new-thread-model-controls-\(Int(width))", size: CGSize(width: width, height: 760)) {
            RootView(vm: vm)
        }
        // The popover under the card, with Fast chosen and then Standard.
        for tier in [ServiceTier.fast, .standard] {
            vm.newThread.setServiceTier(tier)
            try await Preview.render("new-thread-model-settings-\(tier.rawValue)-\(Int(width))", size: CGSize(width: width, height: 760)) {
                NewThreadPage(vm: vm, chrome: PageHeaderChrome(), settingsOpen: true)
            }
        }
    }

    /// The New thread composer with two images attached (drop, paste or the paperclip), and with
    /// a fifth refused ("At most 4 images per message.") under the card.
    @Test(arguments: ["new-thread-attachments", "new-thread-attachments-full"])
    func newThreadWithAttachments(surface: String) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        try await workspace.seed(ShepherdState(spaces: [Space(name: "shepherd", path: workspace.dir.path)]))
        vm.openNewThread()
        vm.newThread.prompt = "Match the sidebar to these screenshots"
        let names = surface == "new-thread-attachments" ? ["sidebar-light.png", "sidebar-dark.png"]
            : ["sidebar-light.png", "sidebar-dark.png", "needs-you.png", "recents.png", "hosts.png"]
        vm.newThread.attachments.add(names.map { name in
            (name, ImageAttachment(name: name, image: NativeImage(mimeType: "image/png", data: Data(count: 8)),
                                   thumbnail: Image(systemName: "photo")))
        })
        try await Preview.render(surface, size: CGSize(width: 1280, height: 760)) {
            RootView(vm: vm)
        }
    }

    /// The workplace chip's menu: This Mac's projects (nested ones flat), a host's, Add folder…
    /// on each, and the worktree option.
    @Test func newThreadPlaceMenu() async throws {
        let mac = NWPlaceSection(id: "local", title: "This Mac", options: [
            NWPlaceOption(id: "local/a", section: "local", title: "shepherd", detail: "~/Developer/Shepherd", isCurrent: true),
            NWPlaceOption(id: "local/b", section: "local", title: "sub-project", detail: "~/Developer/Shepherd/sub"),
            NWPlaceOption(id: "local/c", section: "local", title: "dashboard-web", detail: "~/code/dashboard-web"),
        ])
        let host = NWPlaceSection(id: "host", title: "build-01", options: [
            NWPlaceOption(id: "host/d", section: "host", title: "orders-svc", detail: "~/src/orders-svc"),
        ])
        try await Preview.render("new-thread-place-menu", size: CGSize(width: 360, height: 300)) {
            NWPlaceMenu(sections: [mac, host], worktree: NWPlaceWorktree(isOn: false, caption: NewThreadRules.worktreeCaption(base: "")),
                        onChoose: { _ in }, onAdd: { _ in }, onWorktree: { _ in }, onClose: {}) { _ in EmptyView() }
                .padding(NW.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    // MARK: Palette

    /// The palette over a full window, and in a short one where its list is capped.
    @Test(arguments: [("command-palette", CGSize(width: 1000, height: 720)), ("command-palette-short", CGSize(width: 720, height: 600))])
    func commandPalette(surface: String, size: CGSize) async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        workspace.vm.selectAgent(agents[3].id)
        try await Preview.render(surface, size: size) {
            Color.nw.bgWindow
                .nwCommandPalette(isPresented: .constant(true)) {
                    PaletteCard(items: workspace.vm.paletteItems, run: { _ in }, close: {}, initialQuery: "e")
                }
        }
    }

    /// "an" reaches the agents: a working one with its time ("Shepherd · running · 8m").
    @Test func commandPaletteAgents() async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        workspace.vm.selectAgent(agents[3].id)
        try await Preview.render("command-palette-agents", size: CGSize(width: 1000, height: 620)) {
            Color.nw.bgWindow
                .nwCommandPalette(isPresented: .constant(true)) {
                    PaletteCard(items: workspace.vm.paletteItems, run: { _ in }, close: {}, initialQuery: "an")
                }
        }
    }

    /// "term" finds the Pane menu's terminal commands under This thread, with their keycaps.
    @Test func commandPaletteTerminalCommands() async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        workspace.vm.selectAgent(agents[3].id)
        try await Preview.render("command-palette-terminal", size: CGSize(width: 1000, height: 520)) {
            Color.nw.bgWindow
                .nwCommandPalette(isPresented: .constant(true)) {
                    PaletteCard(items: workspace.vm.paletteItems, run: { _ in }, close: {}, initialQuery: "term")
                }
        }
    }

    // MARK: Toolbar and right pane

    /// The thread toolbar in its states (Main, Review, QuestionAsk, PaneStates boards): a worktree
    /// with changed files and the pane closed; your checkout on another host with the pane open;
    /// a worktree with nothing changed and pi's news on the closed pane's button (its tip under
    /// it); no repository, with the sidebar hidden; and a narrow toolbar.
    @Test func threadToolbar() async throws {
        let running = ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true))
        let idle = ThreadFixture(Threads.idle)
        defer { running.store.stop(); idle.store.stop() }
        let worktree = AgentBranchLabel(kind: .worktree, branch: "pi/swiftui-previews", changedFiles: 3)
        try await Preview.render("thread-toolbar", size: CGSize(width: 960, height: 6 * AppLayout.headerHeight + 96),
                                 ready: { running.store.ready && idle.store.ready }) {
            VStack(alignment: .leading, spacing: 16) {
                ThreadHeader(store: running.store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities",
                             branch: worktree, directory: "~/code/shepherd-previews",
                             paneShortcut: "⇧⌘B", togglePane: {}, showChanges: {}, rename: {})
                ThreadHeader(store: running.store, project: "homelab", title: "Deploy media stack",
                             branch: AgentBranchLabel(kind: .checkout, branch: "chore/remove-homarr", changedFiles: 11, host: "horizon"),
                             paneOpen: true, paneShortcut: "⇧⌘B", togglePane: {}, showChanges: {})
                ThreadHeader(store: idle.store, project: "payments", title: "Add refund events",
                             branch: AgentBranchLabel(kind: .worktree, branch: "pi/refund-events"),
                             paneNews: SidePaneTab.changes.newsText, paneShortcut: "⇧⌘B", togglePane: {}, rename: {})
                Color.clear.frame(height: 36)
                ThreadHeader(store: idle.store, project: "Shepherd", title: "Fix remote nightly", leadingInset: AppLayout.trafficLightInset,
                             showSidebar: {}, paneShortcut: "⇧⌘B", togglePane: {})
                ThreadHeader(store: running.store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities",
                             branch: worktree, paneShortcut: "⇧⌘B", togglePane: {})
                    .frame(width: 440)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgBase)
            // No thread view drives these stores here; feed them their fixtures directly.
            .task { await running.store.run(request: running.request) }
            .task { await idle.store.run(request: idle.request) }
        }
    }

    /// The side pane on its Changes tab in a column too narrow to dock it (it overlays the
    /// thread), and docked at its 380pt minimum beside a 400pt thread, where the tab strip drops
    /// its labels (PaneStates · narrow). The docked one carries pi's dot on Changes.
    @Test(arguments: [("side-pane-overlay", CGFloat(760), false), ("side-pane-docked-narrow", CGFloat(ShellLayout.paneDockThreshold), true)])
    func sidePane(surface: String, width: CGFloat, news: Bool) async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let session = Reviews.session()
        let panes = RightPaneState()
        try await Preview.render(surface, size: CGSize(width: width, height: 760), ready: { fixture.store.ready }) {
            RightPaneSplit(state: panes, showPane: true) {
                fixture.thread()
            } pane: {
                VStack(spacing: 0) {
                    NWSidePaneTabs(SidePaneTabs.items(news: news ? [.changes] : [], changedFiles: session.files.count),
                                   selection: SidePaneTab.changes.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                        Button("Reset Width") {}
                    }
                    ReviewPane(session: session, actions: Reviews.actions)
                }
                .background(Color.nw.bgWindow)
            }
        }
    }
}
