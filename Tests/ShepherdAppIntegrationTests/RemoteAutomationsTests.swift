import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A client view model managing a host's automations over the remote protocol, against a host
/// whose own view model answers them exactly as the app does: the run is an ordinary agent in
/// the host's hidden space, Stop deletes it, and the host keeps the run.
@Suite("Remote automations from a client Mac", .mainActorExclusive)
@MainActor
struct RemoteAutomationsTests {
    @Test func aClientSwitchesRunsStopsAndDeletesAHostsAutomation() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        // Off, so the host does not start a run when its app launches.
        let automation = Automation(name: "watch CI", prompt: "watch the build", cwd: remote.host.dir.path, enabled: false)
        let vm = try await local.start()
        try await remote.host.start(with: ShepherdState(spaces: [space], automations: [automation]))
        let connection = try await remote.connect(local.remoteHosts)
        let key = AutomationKey(host: connection.id, automation: automation.id)
        let host = remote.host.server

        let row = try #require(Self.row(key, in: vm))
        #expect(row.word == "off" && row.run == nil && row.abilities.run && !row.abilities.stop)

        vm.performRemoteAutomation(key, .setEnabled(enabled: true))
        try await eventuallyOnMain("the host to switch it on") {
            host.state.automations.first?.enabled == true && Self.row(key, in: vm)?.word == "stopped"
                && !vm.remoteAutomationsPending.contains(key)
        }
        #expect(host.state.agents.isEmpty, "switching on starts nothing until the host launches")

        vm.performRemoteAutomation(key, .run)
        // The host's state can arrive before its answer, and a change waits while one is on its way.
        try await eventuallyOnMain("the run to start on the host and reach the sidebar", timeout: .seconds(30)) {
            Self.row(key, in: vm)?.run != nil && !vm.remoteAutomationsPending.contains(key)
        }
        let runAgent = try #require(host.state.automations.first?.agentID)
        let hidden = try #require(host.state.spaces.first { $0.hidden })
        #expect(host.state.agents.first { $0.id == runAgent }?.spaceID == hidden.id, "a run lives in the hidden space")
        // The run is in Recents with its bolt; the hidden space is never a project to start in.
        let ref = RemoteAgentRef(hostID: connection.id, agentID: runAgent)
        try await eventuallyOnMain("the run to reach Recents") {
            vm.sidebarLists.recents.contains { $0.id == .remote(ref) && $0.leading == .glyph("bolt", attention: false) }
        }
        #expect(!NewThreadState.hosts(vm).contains { $0.id == connection.id && $0.spaces.contains { $0.id == hidden.id } })

        vm.openDestination(.automations)
        vm.openThread(FleetRef(host: connection.id, agent: runAgent))
        #expect(vm.selectedRemoteAgent == ref && vm.shownDestination == nil, "the page's run opens its thread")
        vm.selectSidebarRow(.remote(ref))
        #expect(vm.selectedRemoteAgent == ref)
        #expect(vm.presentedSidebarLists.recents.first { $0.id == .remote(ref) }?.selected == true)

        vm.performRemoteAutomation(key, .stop)
        try await eventuallyOnMain("the run's agent to go") {
            host.state.agents.isEmpty && Self.row(key, in: vm)?.run == nil && !vm.remoteAutomationsPending.contains(key)
        }

        await vm.loadRemoteAutomationRuns(key)
        #expect(vm.remoteAutomationRuns[key]?.count == 1)
        vm.automationsPageSelection = key
        let detail = try #require(vm.automationsPageModel().detail)
        #expect(detail.key == key && detail.runs.map(\.word) == ["stopped"] && detail.runs.first?.thread == nil)

        vm.deleteAutomation(key)
        try await eventuallyOnMain("the automation to go") {
            host.state.automations.isEmpty && Self.row(key, in: vm) == nil && vm.remoteAutomationRuns[key] == nil
        }
        #expect(vm.automationsPageSelection == nil)
        #expect(vm.remoteActionError == nil)
        #expect(local.server.state.automations.isEmpty, "nothing touched this Mac")
    }

    /// A run that settled only waits to be read: the client offers Run Now again, and the host
    /// replaces the finished run's agent with a new run, keeping the finished one in its runs. A
    /// live run is never cut short by running again.
    @Test func runningASettledAutomationAgainReplacesItsRun() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let automation = Automation(name: "watch CI", prompt: "watch the build", cwd: remote.host.dir.path, enabled: false)
        let vm = try await local.start()
        try await remote.host.start(with: ShepherdState(spaces: [Fixture.space(path: remote.host.dir.path)], automations: [automation]))
        let connection = try await remote.connect(local.remoteHosts)
        let key = AutomationKey(host: connection.id, automation: automation.id)
        let host = remote.host.server

        vm.performRemoteAutomation(key, .run)
        try await eventuallyOnMain("the first run to start", timeout: .seconds(30)) {
            Self.row(key, in: vm)?.run != nil && !vm.remoteAutomationsPending.contains(key)
        }
        let first = try #require(host.state.automations.first?.agentID)
        // pi's status extension reports the turn; the stub pi loads no extensions.
        let reporter = try ExtensionClient(path: remote.host.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: first, status: .working))
        try await eventuallyOnMain("the run to read running") { Self.row(key, in: vm)?.live == true }
        let working = try #require(Self.row(key, in: vm))
        #expect(working.abilities.stop && !working.abilities.run)

        vm.performRemoteAutomation(key, .run)
        try await eventuallyOnMain("the host to refuse a second run") { vm.remoteActionError != nil }
        #expect(vm.remoteActionError == "Couldn't start the run: watch CI is already running")
        #expect(host.state.automations.first?.agentID == first && host.state.agents.count == 1)
        vm.remoteActionError = nil

        try reporter.send(.setAgentStatus(agentID: first, status: .done))
        try await eventuallyOnMain("the run to settle") { Self.row(key, in: vm)?.word == "done" }
        let settled = try #require(Self.row(key, in: vm))
        #expect(!settled.live && settled.abilities.run && !settled.abilities.stop)
        #expect(settled.run == first, "a settled run still opens its thread")

        vm.performRemoteAutomation(key, .run)
        try await eventuallyOnMain("a new run to replace the finished one", timeout: .seconds(30)) {
            let agent = host.state.automations.first?.agentID
            return agent != nil && agent != first && !vm.remoteAutomationsPending.contains(key)
        }
        let second = try #require(host.state.automations.first?.agentID)
        #expect(host.state.agents.map(\.id) == [second], "the finished run's agent is gone")
        #expect(vm.remoteActionError == nil)
        try await eventuallyOnMain("the client to see the new run") { Self.row(key, in: vm)?.run == second }
        #expect(Self.row(key, in: vm)?.live == true, "Open Run opens the new run, which reads running")

        await vm.loadRemoteAutomationRuns(key)
        let runs = try #require(vm.remoteAutomationRuns[key])
        #expect(runs.map(\.result) == [.finished, .running])
        #expect(runs.map(\.agentID) == [nil, second])
    }

    /// A host that refuses a change says why in the failed-action dialog.
    @Test func aRefusedChangeSaysWhy() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let vm = try await local.start()
        try await remote.host.start(with: ShepherdState())
        let connection = try await remote.connect(local.remoteHosts)

        vm.performRemoteAutomation(AutomationKey(host: connection.id, automation: AutomationID()), .run)

        try await eventuallyOnMain("the refusal to show") { vm.remoteActionError != nil }
        #expect(vm.remoteActionError == "Couldn't start the run: The automation no longer exists on the host.")
    }

    /// A remote automation as the Automations page reads it, with the word its run's state reads.
    struct Row {
        let row: AutomationListRow
        var run: AgentID? { row.run?.agent }
        var live: Bool { row.live }
        var abilities: AutomationAbilities { row.abilities }
        var word: String {
            guard row.run != nil else { return row.enabled ? "stopped" : "off" }
            return switch row.tone {
            case .attention: "needs you"
            case .running: "running"
            default: "done"
            }
        }
    }

    static func row(_ key: AutomationKey, in vm: ShepherdViewModel) -> Row? {
        guard let connection = vm.remoteHosts.connections.first(where: { $0.id == key.host }) else { return nil }
        return vm.remoteAutomationsModel(connection).rows.first { $0.key == key }.map(Row.init)
    }
}
