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

    /// A space with agents in every status, a working one whose subagent waits on you (its row
    /// asks), one with finished subagents (no mark), a worktree agent, a second space, an
    /// automation, and an unreachable second machine. The palette lists the subagents.
    private func populatedWorkspace() async throws -> (PreviewWorkspace, [Agent]) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let other = Space(name: "billing-service", path: workspace.dir.appendingPathComponent("billing").path)
        let rows: [(String, AgentStatus, String?)] = [
            ("Plan shepherd extensions", .working, nil), ("Dock review pane", .blocked, "worktree/dock-review"),
            ("Fix remote subagent deletion", .idle, nil), ("Investigate SwiftUI live preview", .working, nil),
            ("Fix remote nightly", .done, nil), ("Fix agent deletion workflow", .idle, nil),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        for (index, row) in rows.enumerated() {
            let (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1, branch: row.2)
            agents.append(agent); tabs.append(tab)
        }
        let (billing, billingTab) = try await workspace.agent("Migrate invoices to v2", in: other, order: 0, status: .idle)
        agents.append(billing); tabs.append(billingTab)
        let automation = Automation(name: "Merge PR #24 after CI", prompt: "watch", cwd: workspace.dir.path, enabled: false)
        try await workspace.seed(ShepherdState(spaces: [space, other], tabs: tabs, agents: agents, automations: [automation]))
        let vm = workspace.vm
        vm.selectedSpaceID = space.id
        vm.selectedAgentID = agents[3].id
        vm.statusSince[agents[0].id] = Date().addingTimeInterval(-8 * 60)
        vm.statusSince[agents[3].id] = Date().addingTimeInterval(-31)
        vm.applyAgentChildren(agents[3].id, Array(Threads.liveRuns.prefix(3)))
        vm.applyAgentChildren(agents[4].id, Threads.doneRuns)
        vm.automationsExpanded = true
        vm.remoteHosts.addHost(name: "Horizon", host: "127.0.0.1", port: 1, token: "x")
        return (workspace, agents)
    }

    @Test(arguments: NWDensity.allCases)
    func sidebar(density: NWDensity) async throws {
        let (workspace, _) = try await populatedWorkspace()
        defer { workspace.stop() }
        try await Preview.render("sidebar-\(density.rawValue)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 760)) {
            SidebarView(vm: workspace.vm).nwDensity(density)
        }
    }

    // MARK: Window

    /// A live (stub) agent after one turn, beside a working one.
    private func liveWindow() async throws -> (PreviewWorkspace, NativeThreadStore) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, status: .done, live: true)
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

    // MARK: Empty workspace states

    @Test(arguments: ["no-spaces", "space-without-agents", "no-agent-selected"])
    func emptyWorkspace(state: String) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        switch state {
        case "space-without-agents":
            try await workspace.seed(ShepherdState(spaces: [space]))
            workspace.vm.selectSpace(space.id)
        case "no-agent-selected":
            let (agent, tab) = try await workspace.agent("Background agent", in: space, order: 0, live: true)
            try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
            workspace.vm.selectedAgentID = nil
            workspace.vm.selectedSpaceID = nil
        default: break
        }
        try await Preview.render("empty-\(state)", size: CGSize(width: 1280, height: 760)) {
            RootView(vm: workspace.vm)
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

    // MARK: Toolbar and right pane

    /// The thread toolbar in its states: running with subagents, needs you with the review
    /// open, idle, and with the sidebar hidden.
    @Test func threadToolbar() async throws {
        let running = ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true))
        let idle = ThreadFixture(Threads.idle)
        defer { running.store.stop(); idle.store.stop() }
        try await Preview.render("thread-toolbar", size: CGSize(width: 960, height: 4 * AppLayout.headerHeight + 48),
                                 ready: { running.store.ready && idle.store.ready }) {
            VStack(spacing: 16) {
                ThreadHeader(store: running.store, project: "Shepherd", title: "Investigate SwiftUI live preview",
                             reviewShortcut: "⇧⌘B", inspectShortcut: "⌘I", toggleReview: {}, toggleSubagents: {}, rename: {})
                ThreadHeader(store: running.store, project: "Shepherd", title: "Dock review pane", inspectorOpen: true,
                             toggleReview: {}, toggleSubagents: {})
                ThreadHeader(store: idle.store, project: "Shepherd", title: "Fix remote subagent deletion", reviewOpen: true,
                             toggleReview: {}, rename: {})
                ThreadHeader(store: idle.store, project: "Shepherd", title: "Fix remote nightly", leadingInset: AppLayout.trafficLightInset,
                             showSidebar: {}, toggleReview: {})
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgBase)
            // No thread view drives these stores here; feed them their fixtures directly.
            .task { await running.store.run(request: running.request) }
            .task { await idle.store.run(request: idle.request) }
        }
    }

    /// The right pane in a column too narrow to dock it (it overlays the thread), and docked
    /// at its minimum beside a 400pt thread.
    @Test(arguments: [("right-pane-narrow", CGFloat(820)), ("right-pane-docked", CGFloat(ShellLayout.paneDockThreshold))])
    func rightPane(surface: String, width: CGFloat) async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let session = Reviews.session()
        let panes = RightPaneState()
        try await Preview.render(surface, size: CGSize(width: width, height: 760), ready: { fixture.store.ready }) {
            RightPaneSplit(state: panes, showPane: true) {
                fixture.thread()
            } pane: {
                ReviewPane(session: session, actions: Reviews.actions).background(Color.nw.bgWindow)
            }
        }
    }
}
