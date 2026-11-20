import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Spend recording", .integrationTimeLimit)
struct SpendRecordingTests {
    @Test func pisTotalsBecomeTheAgentsSpendAndTodaysGrowthIsKeptByModel() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        let id = pi.agent.id
        let monday = Date(timeIntervalSince1970: 1_778_500_000)
        func spend() -> AgentSpend? { host.server.queue.sync { host.server.store.state.agents.first { $0.id == id }?.spend } }
        // The stub reports 105000 tokens and $0.45 while launching: the baseline, so later growth is the day's.
        host.server.queue.sync {
            host.server.recordSpend(agentID: id, stats: NativeThreadStats(totalTokens: 105_000, cost: 0.45), model: "acme/small", now: monday)
            host.server.recordSpend(agentID: id, stats: NativeThreadStats(totalTokens: 105_400, cost: 0.85), model: "acme/small", now: monday)
            // No totals: nothing to record.
            host.server.recordSpend(agentID: id, stats: NativeThreadStats(), model: "acme/small", now: monday)
        }
        let recorded = try #require(spend())
        #expect(recorded.tokens == 105_400)
        #expect(recorded.cost == 0.85)
        #expect(recorded.day == SpendDay.key(monday))
        #expect(recorded.today.map(\.model) == ["acme/small"])
        #expect(recorded.today.first?.tokens == 400)
        #expect(abs((recorded.today.first?.cost ?? 0) - 0.4) < 1e-9)
    }
}
