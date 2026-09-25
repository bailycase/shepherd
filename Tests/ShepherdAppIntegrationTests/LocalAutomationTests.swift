import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// This Mac's automations in the sidebar, over a real server whose run agent's status arrives
/// from its extension: a run reads live from the moment it starts, Run Now never fails
/// silently, and stopping a selected run leaves the hidden space.
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
}
