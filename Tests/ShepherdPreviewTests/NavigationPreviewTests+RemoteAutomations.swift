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

/// A remote host's automations in the sidebar and their details sheet (NavAutomations,
/// NavHosts), against a real in-process host so the rows show what the protocol carries.
extension PreviewTests {
    /// The automations the host serves: one running, one with two weeks of nightly runs, one off.
    private struct AutomationHostFixture {
        let server: ScratchServer
        let port: UInt16
        let token: String
        let nightly: Automation

        /// The run log's file, as the host keeps it.
        private struct RunFile: Encodable {
            var version = 1
            var runs: [String: [AutomationRun]]
        }

        init() async throws {
            let dir = try makeScratchDirectory("host")
            let space = Space(name: "orders-svc", path: dir.path)
            let hidden = Space(name: "Automations", path: "~", hidden: true)
            let runPane = LeafPane(cwd: dir.path)
            let runTab = ShepherdCore.Tab(spaceID: hidden.id, order: 0, layout: .leaf(runPane))
            let run = Agent(name: "Merge PR #24 after CI", spaceID: hidden.id, tabID: runTab.id, paneID: runPane.id, status: .working,
                            nameIsFinal: true)
            let workPane = LeafPane(cwd: dir.path)
            let workTab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(workPane))
            let work = Agent(name: "Checkout funnel events", spaceID: space.id, tabID: workTab.id, paneID: workPane.id,
                             status: .done, nameIsFinal: true)
            nightly = Automation(name: "Nightly migrations dry run",
                                 prompt: "Run every pending migration against a copy of prod in a throwaway database. Report anything irreversible or slower than 30s. Don't open PRs.",
                                 cwd: dir.path, enabled: true)
            let merge = Automation(name: "Merge PR #24 after CI", prompt: "Merge PR #24 once CI is green.", cwd: dir.path,
                                   enabled: true, agentID: run.id)
            let cleanup = Automation(name: "Stale branch cleanup", prompt: "Delete merged branches.", cwd: dir.path, enabled: false)

            let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 3600).timeIntervalSince1970
            let history = (0..<14).map { day -> AutomationRun in
                let start = today - Double(13 - day) * 86_400
                switch day {
                case 4: return AutomationRun(startedAt: start, endedAt: start + 660, result: .interrupted)
                case 9: return AutomationRun(startedAt: start, endedAt: start + 190, result: .stopped)
                default:
                    let took = Double(38 + (day * 7) % 12)
                    return AutomationRun(startedAt: start, settledAt: start + took, endedAt: start + took + 5, result: .finished)
                }
            }
            let file = RunFile(runs: [nightly.id.rawValue: history])
            try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("automation-runs.json"))

            server = try ScratchServer(dir: dir)
            try await server.server.putState(ShepherdState(spaces: [space, hidden], tabs: [workTab, runTab], agents: [work, run],
                                                           automations: [merge, nightly, cleanup]))
            let tokenURL = dir.appendingPathComponent("remote-token")
            port = try server.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Connects the workspace's view model to this host and opens its Automations.
        @MainActor
        func connect(_ workspace: PreviewWorkspace) async throws -> RemoteHostStore.Connection {
            let vm = workspace.vm
            vm.remoteHosts.addHost(name: "build-01", host: "127.0.0.1", port: port, token: token)
            let connection = try #require(vm.remoteHosts.connections.last)
            let host = server.server
            try await eventuallyOnMain("the host to connect", timeout: .seconds(30)) {
                connection.phase == .connected && connection.state == host.state
            }
            vm.toggleRemoteAutomations(connection.id)
            return connection
        }
    }

    @Test func sidebarRemoteAutomations() async throws {
        let workspace = try PreviewWorkspace()
        let host = try await AutomationHostFixture()
        defer { workspace.stop(); host.server.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Plan shepherd extensions", in: space, order: 0, status: .idle)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        _ = try await host.connect(workspace)

        try await Preview.render("sidebar-remote-automations", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 420)) {
            SidebarView(vm: workspace.vm)
        }
    }

    @Test func remoteAutomationSheet() async throws {
        let workspace = try PreviewWorkspace()
        let host = try await AutomationHostFixture()
        defer { workspace.stop(); host.server.stop() }
        let connection = try await host.connect(workspace)
        let key = AutomationKey(host: connection.id, automation: host.nightly.id)
        let vm = workspace.vm
        await vm.loadRemoteAutomationRuns(key)
        #expect(vm.remoteAutomationRuns[key]?.count == 14)

        try await Preview.render("sheet-remote-automation", size: CGSize(width: AppLayout.automationSheetWidth, height: 860)) {
            RemoteAutomationSheet(vm: vm, key: key)
        }
    }
}
