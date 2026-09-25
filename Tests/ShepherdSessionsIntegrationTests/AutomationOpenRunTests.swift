import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport

/// The local GUI decides whether an automation's run is live (Stop, or Run Now) from the run the
/// server's log keeps open, read synchronously while it adopts a broadcast state. That run must
/// never lag the state it adopts: a pi still starting reads live, and a settled run never does.
@Suite("Automation open runs", .integrationTimeLimit)
struct AutomationOpenRunTests {
    @Test func everyBroadcastStateFindsItsRunAlreadyOpenAndCurrent() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        let runSpace = Space(name: "Automations", path: "~", hidden: true)
        let run = Fixture.agent(in: runSpace, name: "watch CI", status: .idle)
        var automation = Automation(name: "watch CI", prompt: "watch", cwd: h.dir.path, enabled: true)
        automation.agentID = run.agent.id

        // What a GUI adopting each broadcast sees: the agent's status beside the open run.
        let seen = Locked<[(AgentStatus, AutomationRun?)]>([])
        let server = h.server
        server.onStateChanged = { state in
            guard let status = state.agents.first(where: { $0.id == run.agent.id })?.status else { return }
            seen.withValue { $0.append((status, server.openAutomationRuns[automation.id])) }
        }

        try await server.putState(ShepherdState(spaces: [runSpace], tabs: [run.tab], agents: [run.agent],
                                                automations: [automation]))
        let starting = try #require(server.openAutomationRuns[automation.id])
        #expect(starting.agentID == run.agent.id)
        #expect(AutomationRun.isLive(agentStatus: .idle, run: starting))

        let ext = try ExtensionClient(path: h.socketPath)
        for status in [AgentStatus.working, .done, .idle] {
            try ext.send(.setAgentStatus(agentID: run.agent.id, status: status))
            try await eventually("the GUI to adopt \(status)") { seen.current.last?.0 == status }
        }

        let adopted = seen.current
        #expect(adopted.map(\.0) == [.idle, .working, .done, .idle])
        #expect(adopted.allSatisfy { $0.1?.agentID == run.agent.id })
        let live = adopted.map { status, run in AutomationRun.isLive(agentStatus: status, run: run) }
        #expect(live == [true, true, false, false])
    }
}
