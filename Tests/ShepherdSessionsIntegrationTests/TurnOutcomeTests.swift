import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The `done` that ends a turn says whether pi's turn failed, so the app never announces a
/// failed turn as finished. The status extension's report can reach the server before pi's own
/// settle on stdout, so the server waits for the settle to know.
@Suite("Turn outcome", .integrationTimeLimit)
struct TurnOutcomeTests {
    private struct Watched {
        let pi: PiAgent
        let callbacks: Callbacks
        let status: ExtensionClient

        var id: AgentID { pi.agent.id }
        var current: AgentStatus? { pi.server.state.agents.first { $0.id == id }?.status }
        func reports() -> [AgentStatus] { callbacks.statuses.current.filter { $0.0 == id }.map(\.1) }
        func dones() -> [TurnFailure?] { callbacks.dones.current.filter { $0.0 == id }.map(\.1) }

        func report(_ status: AgentStatus) throws {
            try self.status.send(.setAgentStatus(agentID: id, status: status))
        }
    }

    private func launch(_ h: ScratchServer) async throws -> Watched {
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let agent = Watched(pi: pi, callbacks: callbacks, status: try ExtensionClient(path: h.socketPath))
        _ = try await pi.ready()
        try agent.report(.working)
        try await eventually("working") { agent.current == .working }
        return agent
    }

    @Test func aTurnThatFailsIsReportedDoneWithItsError() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await launch(h)
        defer { agent.status.closeConnection() }
        let pi = agent.pi
        _ = try await pi.send("provider-error", from: try await pi.snapshot())
        _ = try await pi.snapshot("the failing turn to start") { $0.running }

        // The extension reports done before pi's settle reaches the server.
        let seen = agent.reports().count
        try agent.report(.done)
        // Behind it on the same connection: once this one is reported, the one above was read.
        try agent.report(.working)
        try await eventually("the reports to be read") { agent.reports().count > seen }
        #expect(Array(agent.reports()[seen...]) == [.working], "done waits for pi to settle")
        #expect(agent.dones().isEmpty)

        FileManager.default.createFile(atPath: h.dir.appendingPathComponent("fail-turn").path, contents: nil)
        try await eventually("the held done once pi settles") { !agent.dones().isEmpty }
        #expect(agent.dones() == [TurnFailure(message: "529 overloaded")])
        #expect(agent.current == .done)
    }

    @Test func aTurnThatFinishesIsReportedDoneWithoutAFailure() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await launch(h)
        defer { agent.status.closeConnection() }
        let pi = agent.pi
        let before = try await pi.snapshot()
        _ = try await pi.send("stream", from: before)
        _ = try await pi.snapshot("the turn to settle") { !$0.running && $0.messages.count > before.messages.count }

        try agent.report(.done)
        try await eventually("done") { !agent.dones().isEmpty }
        #expect(agent.dones() == [nil])
    }

    /// pi ends a run the user stopped with an error reply; that turn was stopped, not failed.
    @Test func aStoppedTurnIsNotAFailure() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await launch(h)
        defer { agent.status.closeConnection() }
        let pi = agent.pi
        _ = try await pi.send("tools:1 build", from: try await pi.snapshot())
        let running = try await pi.snapshot("the tool call to run") { s in
            s.running && s.provisional.contains { $0.toolCallID != nil && $0.status == "running" }
        }
        _ = try await pi.request(.abort(expectedSessionID: running.piSessionID, generation: running.generation, operationID: UUID()))
        _ = try await pi.snapshot("the run to end in an error reply") { s in
            !s.running && s.messages.last { $0.role == "assistant" }?.status == "error"
        }

        try agent.report(.done)
        try await eventually("done") { !agent.dones().isEmpty }
        #expect(agent.dones() == [nil])
    }
}
