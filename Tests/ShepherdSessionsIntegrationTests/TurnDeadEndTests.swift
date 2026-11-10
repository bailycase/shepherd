import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A turn never sits at "Waiting for response" with nothing to do: a run pi stops answering fails
/// visibly with Retry, and a turn whose account switched after a limit goes on by itself.
@Suite("Turns with no dead end", .integrationTimeLimit)
struct TurnDeadEndTests {
    @Test func aRunThatHearsNothingFromPiFailsVisiblyAndRetryContinuesIt() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        host.server.threadStallBound = .seconds(1)
        let h = try await PiAgent.launch(on: host)
        let sent = try await h.send("stall", from: try await h.ready())
        #expect(sent.wasAccepted, "\(sent)")
        let failed = try await h.snapshot("the stalled turn to fail", timeout: .seconds(10)) {
            !$0.running && $0.messages.last?.status == "error" && $0.checkpointRecovery?.checkpoint != nil
        }
        #expect(h.stdin("abort").count == 1, "Shepherd stops the run itself")
        let words = failed.messages.last?.blocks.map(\.text).joined() ?? ""
        #expect(words.contains("No response from the model in 1 second"), "\(words)")

        try await eventually("the failed turn's capture to finish") {
            try await h.server.enqueue { h.server.rpcThread(forAgent: h.agent.id)?.canRecoverCheckpoint(operationID: UUID()) == true }
        }
        let retry = try #require(AgentBanners.recovery(in: try await h.snapshot()))
        #expect(try await h.request(retry).wasAccepted)
        _ = try await h.snapshot("Retry to continue it") { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: stall" }
    }

    @Test func aQuietToolCallIsNotAStall() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        host.server.threadStallBound = .seconds(1)
        let h = try await PiAgent.launch(on: host)
        #expect(try await h.send("tools:1", from: try await h.ready()).wasAccepted)
        _ = try await h.snapshot("the tool call to run") { s in s.messages.contains { $0.role == "toolResult" || $0.status == "running" } || s.running }
        try await Task.sleep(for: .seconds(2))
        h.finishTool(1)
        _ = try await h.snapshot("the run to finish") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to tools:1" }
        #expect(h.stdin("abort").isEmpty)
    }

    /// pi doesn't retry this limit: the turn fails, and once the account switched it continues
    /// from its checkpoint, whether the switch lands before or after the turn settles.
    @Test(arguments: [false, true])
    func aTurnWhoseAccountSwitchedContinuesOnTheNewAccount(afterSettle: Bool) async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        #expect(try await h.send("limit now", from: try await h.ready()).wasAccepted)
        if afterSettle {
            _ = try await h.snapshot("the limited turn to fail") { !$0.running && $0.messages.last?.status == "error" }
            try await eventually("the failed turn's capture to finish") {
                try await h.server.enqueue { h.server.rpcThread(forAgent: h.agent.id)?.canRecoverCheckpoint(operationID: UUID()) == true }
            }
        }
        host.server.continueAfterAccountSwitch(h.agent.id)
        _ = try await h.snapshot("the turn to go on") { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: limit now" }
        #expect(h.stdin("recover_checkpoint").count == 1 && h.stdin("prompt").count == 1, "continued, never resent")
    }

    @Test func aTurnThatSucceededAfterTheSwitchIsLeftAlone() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        #expect(try await h.send("hello", from: try await h.ready()).wasAccepted)
        host.server.continueAfterAccountSwitch(h.agent.id)
        _ = try await h.snapshot("the turn to finish", timeout: .seconds(30)) { !$0.running && $0.messages.last?.role == "assistant" }
        try await h.server.enqueue {}
        #expect(h.stdin("recover_checkpoint").isEmpty)
    }
}

private extension NativeThreadResult {
    var wasAccepted: Bool { if case .accepted = self { true } else { false } }
}
