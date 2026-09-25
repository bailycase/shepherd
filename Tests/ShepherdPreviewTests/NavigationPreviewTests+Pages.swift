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

/// The sidebar destinations' pages in the main column (NavAutomations, NavHosts), from a view
/// model with automations on this Mac and on a real in-process host.
extension PreviewTests {
    /// The main column beside a docked sidebar in the boards' 1440×900 window.
    private static let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)

    /// This Mac: one automation whose run works, one whose run asks, one off. The host: its
    /// four (one running, two weeks of nightly runs, one finished, one off).
    private func automationsWorkspace() async throws -> (PreviewWorkspace, AutomationHostFixture, RemoteHostStore.Connection) {
        let workspace = try PreviewWorkspace()
        let host = try await AutomationHostFixture()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let (work, workTab) = try await workspace.agent("Plan shepherd extensions", in: space, order: 0, status: .idle)
        var agents = [work], tabs = [workTab], automations: [Automation] = []
        for (index, (name, status)) in [("Triage new issues", AgentStatus?.some(.blocked)), ("Weekly dependency bumps", .working),
                                        ("Stale branch cleanup", nil)].enumerated() {
            // Off, so the first adoption starts no run of its own.
            var automation = Automation(name: name, prompt: "Look at what came in overnight and say what needs a person.",
                                        cwd: workspace.dir.path, enabled: false)
            if let status {
                let (agent, tab) = try await workspace.agent(name, in: runs, order: index, status: status)
                agents.append(agent); tabs.append(tab)
                automation.agentID = agent.id
            }
            automations.append(automation)
        }
        try await workspace.seed(ShepherdState(spaces: [space, runs], tabs: tabs, agents: agents, automations: automations))
        let connection = try await host.connect(workspace)
        return (workspace, host, connection)
    }

    @Test func automationsPage() async throws {
        let (workspace, host, connection) = try await automationsWorkspace()
        defer { workspace.stop(); host.server.stop() }
        let vm = workspace.vm
        await vm.loadAutomationPageRuns()
        vm.automationsPageSelection = AutomationKey(host: connection.id, automation: host.nightly.id)
        try await Preview.render("page-automations", size: Self.pageSize) {
            AutomationsDestination(vm: vm)
        }
    }

    @Test func automationsPageFiltered() async throws {
        let (workspace, host, _) = try await automationsWorkspace()
        defer { workspace.stop(); host.server.stop() }
        let vm = workspace.vm
        await vm.loadAutomationPageRuns()
        vm.automationsPageFilter = "nothing like this"
        try await Preview.render("page-automations-no-match", size: Self.pageSize) {
            AutomationsDestination(vm: vm)
        }
    }

    @Test func automationsPageEmpty() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await Preview.render("page-automations-empty", size: Self.pageSize) {
            AutomationsDestination(vm: workspace.vm)
        }
    }

    /// New automation, with a connected host to pick.
    @Test func automationEditor() async throws {
        let (workspace, host, _) = try await automationsWorkspace()
        defer { workspace.stop(); host.server.stop() }
        try await Preview.render("sheet-automation-editor", size: CGSize(width: AppLayout.automationSheetWidth + 80, height: 560)) {
            AutomationEditorSheet(vm: workspace.vm, target: .new) {}
        }
    }

    /// This Mac, a connected host, and one that dropped: what waits on it and when it was last seen.
    @Test func hostsPage() async throws {
        let (workspace, host, _) = try await automationsWorkspace()
        let horizon = try await AutomationHostFixture()
        defer { workspace.stop(); host.server.stop(); horizon.server.stop() }
        let vm = workspace.vm
        let dropped = try await horizon.connect(workspace, name: "horizon")
        horizon.server.stop()
        try await eventuallyOnMain("horizon to drop", timeout: .seconds(30)) {
            if case .failed = dropped.phase { dropped.lastSeen != nil } else { false }
        }
        try await Preview.render("page-hosts", size: Self.pageSize) {
            HostsPage(model: vm.hostsPageModel(agentVersion: "0.8.2"),
                      actions: HostsPageActions(retry: { _ in }, remove: { _ in }, addHost: {}))
        }
    }
}
