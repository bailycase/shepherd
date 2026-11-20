import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

extension PreviewTests {
    @Test func sidebarThreadFilterStates() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "acme-web", path: workspace.dir.path)
        func agent(_ title: String, _ status: AgentStatus, _ order: Int, branch: String? = nil, changed: Int = 0) async throws -> Agent {
            var (agent, _) = try await workspace.agent(title, in: space, order: order, status: status, branch: branch)
            agent.checkout = AgentCheckout(branch: branch ?? "main", changedFiles: changed)
            agent.lastActiveAt = Double(order)
            return agent
        }
        let local = try await [agent("Refresh checkout", .working, 4, branch: "feat/checkout", changed: 2),
                               agent("Review sign-in copy", .blocked, 3), agent("Index the changelog", .done, 2),
                               agent("Tidy test fixtures", .idle, 1)]
        let remote = try await [agent("Update search index", .working, 3), agent("Polish error states", .idle, 2,
                                                                                 branch: "feat/errors", changed: 1)]
        let host = UUID()
        vm.sidebarSourceAdjust = { source in
            var source = source
            source.local = ShepherdState(spaces: [space], agents: local)
            source.hosts = [.init(id: host, name: "acme-build", state: ShepherdState(spaces: [space], agents: remote))]
            return source
        }
        let states: [(String, SidebarThreadFilters)] = [
            ("off", .init()), ("on", .init(chips: [.hasChanges, .worktree], host: host)),
            ("empty", .init(chips: [.needsYou, .worktree], host: host)),
        ]
        for (sample, filters) in states {
            vm.sidebarThreadFilters = filters
            try await Preview.render("sidebar-filters-\(sample)-mac", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 660)) {
                SidebarView(vm: vm)
            }
        }
    }

    /// Running with a sent thread (grouped by its own status, not its sender's), a remote watcher still starting (idle, its run
    /// not yet read) and a disconnected host (its thread never counts, and the picker offers only connected hosts).
    @Test func sidebarThreadFilterRunningStates() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "acme-web", path: workspace.dir.path)
        func agent(_ title: String, _ status: AgentStatus, _ order: Int) async throws -> Agent {
            var (agent, _) = try await workspace.agent(title, in: space, order: order, status: status)
            agent.lastActiveAt = Double(order)
            return agent
        }
        let thisMac = UUID(), build = UUID(), spare = UUID()
        let sender = try await agent("Ship the release notes", .done, 1)
        var child = try await agent("Update search index", .working, 5)
        child.dispatchedFrom = DispatchedFrom(hostID: thisMac, hostName: "acme-laptop", agentID: sender.id,
                                              agentTitle: sender.name, dispatchID: UUID(), at: 5)
        let local = try await [sender, child, agent("Refresh checkout", .working, 4), agent("Tidy test fixtures", .idle, 2)]
        let watcher = try await agent("Dependency sweep", .idle, 3)
        let manual = Automation(name: "Dependency sweep", prompt: "p", cwd: "/srv", agentID: watcher.id)
        let stale = try await agent("Rebuild the docs", .working, 1)
        vm.sidebarSourceAdjust = { source in
            var source = source
            source.localFleetID = thisMac
            source.local = ShepherdState(spaces: [space], agents: local)
            source.hosts = [
                .init(id: build, name: "acme-build", state: ShepherdState(spaces: [space], agents: [watcher], automations: [manual])),
                .init(id: spare, name: "acme-spare", state: ShepherdState(spaces: [space], agents: [stale]), offline: true),
            ]
            return source
        }
        vm.sidebarThreadFilters = .init(chips: [.running])
        try await Preview.render("sidebar-filters-running-mac", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 660)) {
            SidebarView(vm: vm)
        }
    }
}
