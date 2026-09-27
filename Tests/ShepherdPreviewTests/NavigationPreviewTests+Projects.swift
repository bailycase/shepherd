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

/// The sidebar organized by project (Sidebar — Projects: SidebarTree, SidebarProjects,
/// SidebarProjectsHosts), in light and dark.
extension PreviewTests {
    /// The SidebarTree board's projects: shepherd open on its threads (one asking, two running, an
    /// automation's settled run, a failed turn), dashboard-web closed with a question in it,
    /// shepherd-daemon closed while it runs, and dotfiles closed and quiet.
    private func projectsWorkspace() async throws -> PreviewWorkspace {
        let workspace = try PreviewWorkspace()
        let shepherd = Space(name: "shepherd", path: workspace.dir.path)
        let dashboard = Space(name: "dashboard-web", path: workspace.dir.appendingPathComponent("dashboard-web").path)
        let daemon = Space(name: "shepherd-daemon", path: workspace.dir.appendingPathComponent("daemon").path)
        let dotfiles = Space(name: "dotfiles", path: workspace.dir.appendingPathComponent("dotfiles").path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let rows: [(String, Space, AgentStatus)] = [
            ("Dock review pane", shepherd, .blocked), ("Investigate SwiftUI live preview", shepherd, .working),
            ("Plan shepherd extensions", shepherd, .working), ("Fix remote subagent deletion", shepherd, .idle),
            ("Fix terminal output buffer", shepherd, .idle), ("Fix remote nightly", shepherd, .done),
            ("Checkout funnel events", dashboard, .blocked),
            ("Restart the watcher", daemon, .working), ("Trim the log rotation", daemon, .done), ("Pin the Go toolchain", daemon, .idle),
            ("Move zsh plugins to nix", dotfiles, .done),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let now = Date().timeIntervalSince1970 * 1000
        for (index, row) in rows.enumerated() {
            var (agent, tab) = try await workspace.agent(row.0, in: row.1, order: index, status: row.2)
            agent.lastActiveAt = now - Double(index) * 60_000
            agents.append(agent); tabs.append(tab)
        }
        agents[0].waitingOn = "Approve the plan?"
        agents[0].waitingReason = "approve plan"
        agents[6].waitingOn = "Retention: 30 days or 13 months?"
        agents[6].waitingReason = "retention?"
        var (run, runTab) = try await workspace.agent("Merge PR #24 after CI", in: runs, order: 0, status: .done)
        run.lastActiveAt = now - 3.5 * 60_000
        agents.append(run); tabs.append(runTab)
        let automation = Automation(name: "Merge PR #24 after CI", prompt: "watch", cwd: shepherd.path, enabled: false, agentID: run.id)
        try await workspace.seed(ShepherdState(spaces: [shepherd, dashboard, daemon, dotfiles, runs], tabs: tabs, agents: agents,
                                               automations: [automation]))
        let vm = workspace.vm
        vm.settings.sidebarStyle = .projects
        vm.selectAgent(agents[1].id)
        vm.statusSince[agents[1].id] = Date().addingTimeInterval(-31)
        vm.statusSince[agents[2].id] = Date().addingTimeInterval(-8 * 60)
        vm.failedTurns.insert(agents[5].id)
        vm.collapsedProjects = Set([dashboard, daemon, dotfiles].map { SidebarProjectID.local($0.id).key })
        return workspace
    }

    /// Organized by project at each row density: shepherd open, the others closed and rolled up
    /// (amber while something waits, a running dot while something runs, quiet).
    @Test(arguments: [NWDensity.standard, .compact])
    func sidebarProjects(density: NWDensity) async throws {
        let workspace = try await projectsWorkspace()
        defer { workspace.stop() }
        try await Preview.render("sidebar-projects-\(density.rawValue)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 640)) {
            SidebarView(vm: workspace.vm).nwDensity(density)
        }
    }

    /// Every project open, and one hidden from the sidebar (the + beside Projects lists it).
    @Test func sidebarProjectsOpen() async throws {
        let workspace = try await projectsWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.collapsedProjects = []
        let dotfiles = try #require(vm.state.spaces.first { $0.name == "dotfiles" })
        vm.setProjectHiddenFromSidebar(dotfiles.id, true)
        #expect(vm.sidebarTree.hiddenProjects.map(\.id) == [dotfiles.id])
        try await Preview.render("sidebar-projects-open", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 640)) {
            SidebarView(vm: vm)
        }
    }

    /// A connected host's threads: not grouped, in their project with the host as a tag; grouped
    /// by host, a section per host (This Mac first), an unreachable one saying so in red.
    @Test(arguments: [false, true])
    func sidebarProjectsWithHosts(grouped: Bool) async throws {
        let workspace = try await projectsWorkspace()
        let host = try await AutomationHostFixture()
        defer { workspace.stop(); host.server.stop() }
        let vm = workspace.vm
        _ = try await host.connect(workspace)
        vm.remoteHosts.addHost(name: "horizon", host: "127.0.0.1", port: 1, token: "x")
        vm.settings.sidebarGroupByHost = grouped
        vm.collapsedProjects.insert(SidebarProjectID.local(try #require(vm.state.spaces.first?.id)).key)
        try await Preview.render(grouped ? "sidebar-projects-by-host" : "sidebar-projects-remote",
                                 size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 640),
                                 ready: { vm.offlineHostCount == 1 }) {
            SidebarView(vm: vm)
        }
    }

    /// The Tree rows board: a project open (its threads' dots under its folder), the collapsed
    /// roll-ups, hover with + and ···, a drag's line with the dragged project dimmed, and a host
    /// section that can't be reached.
    @Test func sidebarProjectRows() async throws {
        let started = Date().addingTimeInterval(-31)
        try await Preview.render("sidebar-project-rows", size: CGSize(width: 3 * (AppLayout.sidebarDefaultWidth + 24) + 24, height: 260)) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                    NWProjectRow("shepherd", count: 3, expanded: true, toggle: {}, newThread: {}) { EmptyView() }
                    NWSidebarRow("Dock review pane", state: .attention, accessory: .reason("approve plan"), nested: true)
                    NWSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true,
                                 accessory: .elapsed(since: started), nested: true)
                    NWSidebarRow("Plan shepherd extensions", state: .running, nested: true)
                    NWProjectRow("dashboard-web", count: 2, expanded: false, rollup: .waiting, toggle: {}, newThread: {}) { EmptyView() }
                    NWProjectRow("shepherd-daemon", count: 3, expanded: false, rollup: .running, toggle: {}, newThread: {}) { EmptyView() }
                    NWProjectRow("dotfiles", count: 1, expanded: false, toggle: {}, newThread: {}) { EmptyView() }
                }
                .frame(width: AppLayout.sidebarDefaultWidth)
                VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                    NWProjectRow("shepherd", count: 1, expanded: true, hovered: true, toggle: {}, newThread: {}) { EmptyView() }
                    NWSidebarRow("Investigate SwiftUI live preview", state: .running, selected: true, nested: true)
                    Color.clear.frame(height: NW.Space.l)
                    NWProjectRow("dashboard-web", count: 2, expanded: false, rollup: .waiting, toggle: {}, newThread: {}) { EmptyView() }
                    NWProjectRow("shepherd", count: 9, expanded: false, rollup: .waiting, toggle: {}, newThread: {}) { EmptyView() }
                        .overlay(alignment: .top) {
                            NWDropIndicator().padding(.horizontal, NW.Space.xs)
                                .offset(y: -(NWDropIndicator.thickness + AppLayout.sidebarRowSpacing) / 2)
                        }
                    NWProjectRow("dotfiles", count: 1, expanded: false, toggle: {}, newThread: {}) { EmptyView() }
                        .opacity(NWProjectMetrics.draggedOpacity)
                }
                .frame(width: AppLayout.sidebarDefaultWidth)
                VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                    NWSidebarSection(.host("This Mac", unreachable: false))
                    NWProjectRow("shepherd", count: 5, expanded: false, rollup: .waiting, toggle: {}, newThread: {}) { EmptyView() }
                    NWSidebarSection(.host("horizon", unreachable: true))
                    NWProjectRow("shepherd", count: 2, expanded: false, dimmed: true, toggle: {}, newThread: nil) { EmptyView() }
                }
                .frame(width: AppLayout.sidebarDefaultWidth)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgBase)
        }
    }
}
