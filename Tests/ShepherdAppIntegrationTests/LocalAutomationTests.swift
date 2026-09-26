import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// This Mac's automations in the sidebar, over a real server whose run agent's status arrives
/// from its extension: a run reads live from the moment it starts, Run Now never fails
/// silently, stopping a selected run leaves the hidden space, and Run Now on the run on screen
/// shows the new run.
@Suite("Local automations", .mainActorExclusive)
@MainActor
struct LocalAutomationTests {
    @Test func aStartingRunReadsLiveARefusedRunNowSaysSoAndStopLeavesTheHiddenSpace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let run = Fixture.agent("watch CI", in: runs, cwd: app.dir.path)
        // Off, so the first adoption starts nothing of its own.
        var automation = Automation(name: "watch CI", prompt: "watch", cwd: app.dir.path, enabled: false)
        automation.agentID = run.agent.id
        var state = Fixture.state(spaces: [space, runs], agents: [run])
        state.automations = [automation]
        let vm = try await app.start(with: state)

        // pi still starting: idle, no turn settled. The row reads running and offers Stop.
        func row() -> (live: Bool, word: String) {
            let agent = vm.automationAgent(automation)
            let open = vm.automationRun(automation, agent: agent)
            return (AutomationRow.isLive(agent, run: open), AutomationRow.stateWord(agent, run: open, turnFailed: false))
        }
        #expect(row().live && row().word == "running")

        // Run Now anyway (a menu opened before the state moved): the host's refusal is shown.
        vm.runAutomationNow(automation.id)
        try await eventuallyOnMain("the refusal to show") { vm.remoteActionError?.contains("already running") == true }
        #expect(app.server.state.agents.map(\.id) == [run.agent.id], "a live run is never replaced")
        vm.remoteActionError = nil

        // Its turn settles: done, and Run Now is offered.
        let ext = try ExtensionClient(path: app.scratch.socketPath)
        for status in [AgentStatus.working, .done] {
            try ext.send(.setAgentStatus(agentID: run.agent.id, status: status))
            try await eventuallyOnMain("the run to read \(status)") { vm.automationAgent(automation)?.status == status }
        }
        #expect(!row().live && row().word == "done")

        // Stopping the run on screen moves the workspace to a visible space.
        vm.selectAgent(run.agent.id)
        #expect(vm.selectedSpaceID == runs.id)
        vm.stopAutomation(automation.id)
        try await eventuallyOnMain("the run to stop") { vm.state.agents.isEmpty }
        await app.settle()
        #expect(vm.selectedAgentID == nil)
        #expect(vm.selectedSpaceID == space.id)
    }

    /// Run Now on the settled run on screen: the workspace goes straight to the new run's
    /// thread, never through the agent selected before it (or an empty space) on the way.
    @Test func runNowOnTheRunOnScreenShowsTheNewRun() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let fixture = try await Self.settledRun(app)
        let vm = fixture.vm, old = fixture.run.agent.id
        vm.selectAgent(fixture.other.agent.id)
        vm.selectAgent(old)

        let shown = SelectionRecorder(vm)
        defer { shown.stop() }
        vm.runAutomationNow(fixture.automation.id)
        let new = try await Self.replacement(of: old, in: vm, app: app)

        #expect(vm.remoteActionError == nil)
        #expect(vm.selectedAgentID == new && vm.selectedSpaceID == fixture.runs.id)
        try await eventuallyOnMain("the recorder to catch up") { shown.values.last == vm.selectedAgentID }
        #expect(shown.values == [old, new], "the selection went straight to the new run: \(shown.values)")
    }

    /// Run Now on a settled run you are not looking at leaves the selection where it is.
    @Test func runNowOnARunOffScreenLeavesTheSelectionAlone() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let fixture = try await Self.settledRun(app)
        let vm = fixture.vm
        vm.selectAgent(fixture.run.agent.id)
        vm.selectAgent(fixture.other.agent.id)

        vm.runAutomationNow(fixture.automation.id)
        _ = try await Self.replacement(of: fixture.run.agent.id, in: vm, app: app)

        #expect(vm.remoteActionError == nil)
        #expect(vm.selectedAgentID == fixture.other.agent.id && vm.selectedSpaceID == fixture.space.id)
    }

    /// A second Run Now while the first is still starting its run refuses, rather than starting
    /// a run no automation points at.
    @Test func runNowWhileARunIsStartingRefuses() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let fixture = try await Self.settledRun(app)
        let vm = fixture.vm

        vm.runAutomationNow(fixture.automation.id)
        vm.runAutomationNow(fixture.automation.id)
        try await eventuallyOnMain("the second Run Now to refuse") { vm.remoteActionError?.contains("already running") == true }
        vm.remoteActionError = nil
        let new = try await Self.replacement(of: fixture.run.agent.id, in: vm, app: app)

        #expect(vm.remoteActionError == nil)
        #expect(Set(app.server.state.agents.map(\.id)) == [fixture.other.agent.id, new])
    }

    /// A visible space's agent beside an automation whose run has settled (done).
    private static func settledRun(_ app: AppHarness) async throws
        -> (vm: ShepherdViewModel, space: Space, runs: Space, other: AgentFixture, run: AgentFixture, automation: Automation) {
        let space = Fixture.space(path: app.dir.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let other = Fixture.agent("other", in: space)
        let run = Fixture.agent("watch CI", in: runs, cwd: app.dir.path)
        var automation = Automation(name: "watch CI", prompt: "watch", cwd: app.dir.path, enabled: false)
        automation.agentID = run.agent.id
        var state = Fixture.state(spaces: [space, runs], agents: [other, run])
        state.automations = [automation]
        let vm = try await app.start(with: state)
        let ext = try ExtensionClient(path: app.scratch.socketPath)
        for status in [AgentStatus.working, .done] {
            try ext.send(.setAgentStatus(agentID: run.agent.id, status: status))
            try await eventuallyOnMain("the run to read \(status)") { vm.automationAgent(automation)?.status == status }
        }
        return (vm, space, runs, other, run, automation)
    }

    /// Waits until the automation's run is a new agent and `old` is gone; returns the new run.
    private static func replacement(of old: AgentID, in vm: ShepherdViewModel, app: AppHarness) async throws -> AgentID {
        try await eventuallyOnMain("the new run to replace the settled one", timeout: .seconds(20)) {
            vm.remoteActionError != nil || (vm.state.automations.first?.agentID.map { $0 != old } == true
                && !vm.state.agents.contains { $0.id == old })
        }
        await app.settle()
        return try #require(vm.state.automations.first?.agentID)
    }
}

/// Every agent the view model selects, in order, from the one selected when it starts.
@MainActor
private final class SelectionRecorder {
    private(set) var values: [AgentID?] = []
    private var watching: Task<Void, Never>?

    init(_ vm: ShepherdViewModel) {
        values = [vm.selectedAgentID]
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = vm.selectedAgentID } onChange: { Task { @MainActor in changed.resume() } }
                }
                guard let self else { return }
                if self.values.last != vm.selectedAgentID { self.values.append(vm.selectedAgentID) }
            }
        }
    }

    func stop() { watching?.cancel() }
}
