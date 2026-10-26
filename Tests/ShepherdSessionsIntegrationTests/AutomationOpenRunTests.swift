import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The local GUI decides whether an automation's run is live (Stop, or Run Now) from the run the
/// server's log keeps open, read synchronously while it adopts a broadcast state. That run must
/// never lag the state it adopts: a pi still starting reads live, and a settled run never does.
@Suite("Automation open runs", .integrationTimeLimit)
struct AutomationOpenRunTests {
    @Test(arguments: [false, true])
    func deletesOnlyFlaggedWatchersAfterActualSettlement(deleteAfterRun: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        let automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: pi.agent.id, deleteAfterRun: deleteAfterRun)
        try await h.server.addAutomation(automation)
        #expect(h.server.state.automations == [automation], "startup idle is not finished")

        _ = try await pi.send("tools:1 hold-settle", from: idle)
        _ = try await pi.snapshot { $0.running }
        let ext = try ExtensionClient(path: h.socketPath)
        for status in [AgentStatus.blocked, .working, .done] {
            try ext.send(.setAgentStatus(agentID: pi.agent.id, status: status))
        }
        // A queue barrier, not a timing guess: neither a live tool nor a socket 'done' settles pi.
        _ = try await pi.snapshot()
        #expect(h.server.state.automations == [automation])
        pi.finishTool(1)
        pi.releaseSettle()
        _ = try await pi.snapshot("the watcher to settle") { !$0.running && $0.messages.count > 2 }
        try await h.server.enqueue {}
        if deleteAfterRun {
            try await eventually("one-shot cleanup") { h.server.state.automations.isEmpty }
            #expect(await h.server.automationRuns(automation.id).isEmpty, "normal deletion prunes the run log")
        } else {
            #expect(h.server.state.automations == [automation])
        }
        #expect(h.server.state.agents.contains { $0.id == pi.agent.id }, "cleanup must not kill the reporting agent")
        #expect(!(try await pi.snapshot()).messages.isEmpty, "the watcher transcript remains")
    }

    @Test func settledFailureDeletesButCreationAndPromptRefusalDoNot() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        let automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: pi.agent.id, deleteAfterRun: true)
        try await h.server.addAutomation(automation)
        _ = try await pi.send("refuse", from: idle)
        _ = try await pi.waitForStdin("prompt")
        try await h.server.enqueue {}
        #expect(h.server.state.automations == [automation])
        _ = try await pi.send("provider-error", from: try await pi.snapshot())
        _ = try await pi.snapshot { $0.running }
        #expect(h.server.state.automations == [automation], "a live failing request is not terminal")
        try Data().write(to: h.dir.appendingPathComponent("fail-turn"))
        try await eventually("settled failure cleanup") { h.server.state.automations.isEmpty }
        #expect(h.server.state.agents.contains { $0.id == pi.agent.id })
    }

    @Test func fastSettlementBeforeAgentLinkStillCleansUp() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("hello", from: try await pi.ready())
        _ = try await pi.snapshot { !$0.running && $0.messages.count > 2 }
        let automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: pi.agent.id, deleteAfterRun: true)
        try await h.server.addAutomation(automation)
        try await eventually("late link cleanup") { h.server.state.automations.isEmpty }
    }

    @Test func settledButBlockedWatcherIsNotDeleted() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        let automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: pi.agent.id, deleteAfterRun: true)
        try await h.server.addAutomation(automation)
        let ext = try ExtensionClient(path: h.socketPath)
        try ext.send(.setAgentStatus(agentID: pi.agent.id, status: .blocked))
        try await eventually("blocked status") { h.server.state.agents.first?.status == .blocked }
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            thread.handle(.agentStart)
            thread.handle(.agentSettled)
        }
        try await eventually("pi settlement") {
            try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.actualTurnSettled == true }
        }
        try await h.server.enqueue {}
        #expect(h.server.state.automations == [automation])
    }

    @Test func oldSettledEventCannotDeleteReplacementRun() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let old = try await PiAgent.launch(on: h)
        let idle = try await old.ready()
        var automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: old.agent.id, deleteAfterRun: true)
        try await h.server.addAutomation(automation)
        _ = try await old.send("tools:1 hold-settle", from: idle)
        _ = try await old.snapshot { $0.running }
        let replacement = try await PiAgent.launch(on: h)
        _ = try await replacement.ready()
        automation.agentID = replacement.agent.id
        try await h.server.updateAutomation(automation)
        old.finishTool(1)
        old.releaseSettle()
        _ = try await old.snapshot { !$0.running && $0.messages.count > 2 }
        try await h.server.enqueue {}
        #expect(h.server.state.automations == [automation])
    }

    @Test func explicitStopDoesNotDeleteOneShot() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        let automation = Automation(name: "watch", prompt: "watch", cwd: h.dir.path,
                                    agentID: pi.agent.id, deleteAfterRun: true)
        try await h.server.addAutomation(automation)
        _ = try await pi.send("tools:1", from: idle)
        let running = try await pi.snapshot { $0.running }
        _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        _ = try await pi.snapshot { !$0.running }
        try await h.server.enqueue {}
        #expect(h.server.state.automations == [automation])
    }

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
