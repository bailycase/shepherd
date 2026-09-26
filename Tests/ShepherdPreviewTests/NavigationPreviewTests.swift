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

        try await Preview.render("sidebar-automations", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 360)) {
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

    /// The terminal panel (TerminalSplit, TerminalStates boards): two tabs under the thread, the
    /// first split right, then the same panel maximized over the folded thread.
    @Test(arguments: [false, true])
    func appWindowTerminalPanel(maximized: Bool) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Add refund events", in: space, order: 0, live: true)
        let thread = try #require(agent.paneID)
        let shell = LeafPane(cwd: space.path), beside = LeafPane(cwd: space.path), second = LeafPane(cwd: space.path)
        var panel = tab
        // + twice from the thread, then Split right in the first tab.
        panel.layout = tab.layout.splitting(pane: thread, axis: .horizontal, newPane: shell)!
            .splitting(pane: thread, axis: .horizontal, newPane: second)!
            .splitting(pane: shell.id, axis: .vertical, newPane: beside)!
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [panel], agents: [agent]))
        vm.selectAgent(agent.id)
        let key = TerminalPanelKey(host: nil, tab: panel.id)
        vm.terminalPanels.update(key) {
            $0.shown = true
            $0.chosenTab = shell.id
            $0.chosenPanes = [shell.id, beside.id]
            $0.maximized = maximized
        }
        let store = vm.threadStores.store(for: agent.id)
        let shells = [shell, beside].map { vm.sessions.session(for: $0, in: panel) }
        try await Preview.render(maximized ? "app-window-terminal-maximized" : "app-window-terminal-panel",
                                 size: CGSize(width: 1440, height: 900), ready: {
            (maximized || store.ready) && shells.allSatisfy { $0.phase == .live } && vm.terminalPanels.activity[key]?.count == 3
        }) {
            RootView(vm: vm)
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
