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

    @Test func aNewPiSessionCountsWholeAndALowerTotalInTheSameSessionAddsNothing() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        let id = pi.agent.id
        let monday = Date(timeIntervalSince1970: 1_778_500_000)
        func spend() -> AgentSpend? { host.server.queue.sync { host.server.store.state.agents.first { $0.id == id }?.spend } }
        host.server.queue.sync {
            func report(_ tokens: Int, _ cost: Double?, session: String) {
                host.server.recordSpend(agentID: id, stats: NativeThreadStats(totalTokens: tokens, cost: cost), model: "acme/small", sessionID: session, now: monday)
            }
            report(1_000, 4, session: "s1")
        }
        // The first report of a session the stub did not launch with counts whole; what follows is measured from it.
        let before = try #require(spend()?.today.first)
        host.server.queue.sync {
            func report(_ tokens: Int, _ cost: Double?, session: String) {
                host.server.recordSpend(agentID: id, stats: NativeThreadStats(totalTokens: tokens, cost: cost), model: "acme/small", sessionID: session, now: monday)
            }
            report(1_300, nil, session: "s1")
            report(900, 4.5, session: "s1")
            report(100, 0.1, session: "s2")
        }
        let recorded = try #require(spend())
        #expect(recorded.sessionID == "s2")
        // 300 and $0.5 in s1, then s2's 100 and $0.1 whole; the dip to 900 added nothing.
        #expect(recorded.today.first?.tokens == before.tokens + 400)
        #expect(abs((recorded.today.first?.cost ?? 0) - ((before.cost ?? 0) + 0.6)) < 1e-9)
        #expect(recorded.zone == TimeZone.current.identifier)
    }

    @Test func aBackgroundSubagentsUsageJoinsTheThreadsSpendOnce() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.ready()
        let id = pi.agent.id
        let monday = Date(timeIntervalSince1970: 1_778_500_000)
        func spend() -> AgentSpend? { host.server.queue.sync { host.server.store.state.agents.first { $0.id == id }?.spend } }
        func run(_ tokens: Int, _ cost: Double?, state: String = "running") -> ChildRun {
            ChildRun(runID: "native-1", label: "worker: restyle", state: state, model: "acme/helper", tokens: tokens, cost: cost)
        }
        host.server.queue.sync {
            host.server.recordSpend(agentID: id, stats: NativeThreadStats(totalTokens: 1_000, cost: 1), model: "acme/small", sessionID: "s1", now: monday)
            // The same published rows again and again are one run's usage once.
            host.server.recordChildSpend(agentID: id, runs: [run(300, 0.3)], now: monday)
            host.server.recordChildSpend(agentID: id, runs: [run(300, 0.3)], now: monday)
            host.server.recordChildSpend(agentID: id, runs: [run(700, 0.7, state: "complete")], now: monday)
            host.server.recordChildSpend(agentID: id, runs: [run(700, 0.7, state: "complete")], now: monday)
        }
        let recorded = try #require(spend())
        #expect(recorded.today.first { $0.model == "acme/helper" }?.tokens == 700)
        #expect(recorded.totalTokens == 1_700)
        #expect(abs((recorded.totalCost ?? 0) - 1.7) < 1e-9)
    }
}
