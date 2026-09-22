import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// Child-run rows are ephemeral display state mirrored from the subagents extension. The
/// lifecycle rules exist so nothing stale can stick in the sidebar.
@Suite("Child runs")
struct ChildRunsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func runs(ttl: TimeInterval = 60, staleAfter: TimeInterval = 120) -> ChildRuns {
        var runs = ChildRuns()
        runs.terminalTTL = ttl
        runs.staleAfter = staleAfter
        return runs
    }

    /// The extension always sends its full projection.
    @Test func aPublishReplacesTheAgentsRowsWholesale() {
        var runs = runs()
        let agent = AgentID()
        runs.apply(agentID: agent, children: [Fixture.child("a"), Fixture.child("b")], now: t0)
        runs.apply(agentID: agent, children: [Fixture.child("b")], now: at(1))
        #expect(runs.children(of: agent).map(\.runID) == ["b"])
    }

    @Test func anEmptyPublishClearsTheAgent() {
        var runs = runs()
        let agent = AgentID()
        runs.apply(agentID: agent, children: [Fixture.child("a")], now: t0)
        runs.apply(agentID: agent, children: [], now: at(1))
        #expect(runs.rows[agent] == nil)
    }

    /// A finished lane stays readable, keeps its first terminal time across republishes, and
    /// expires TTL after it first went terminal.
    @Test func finishedRowsLingerForTheirTTLFromWhenTheyFinished() {
        var runs = runs(ttl: 60)
        let agent = AgentID()
        let batch = [Fixture.child("a", state: "complete"), Fixture.child("b")]
        runs.apply(agentID: agent, children: batch, now: t0)
        runs.apply(agentID: agent, children: batch, now: at(30))
        #expect(runs.children(of: agent).count == 2)

        runs.apply(agentID: agent, children: batch, now: at(61))
        #expect(runs.children(of: agent).map(\.runID) == ["b"])
    }

    @Test func aSweepExpiresFinishedRowsAndReportsTheChange() {
        var runs = runs(ttl: 60)
        let agent = AgentID()
        runs.apply(agentID: agent, children: [Fixture.child("a", state: "failed"), Fixture.child("b")], now: t0)

        let changed = runs.sweep(now: at(61))

        #expect(changed)
        #expect(runs.children(of: agent).map(\.runID) == ["b"])
    }

    @Test func aQuietSweepReportsNoChange() {
        var runs = runs()
        runs.apply(agentID: AgentID(), children: [Fixture.child("a")], now: t0)
        let changed = runs.sweep(now: at(1))
        #expect(!changed)
    }

    /// Each agent's terminal clock is its own, even for the same run id.
    @Test func terminalTimestampsArePerAgent() {
        var runs = runs(ttl: 60)
        let first = AgentID()
        let second = AgentID()
        runs.apply(agentID: first, children: [Fixture.child("same", state: "complete")], now: t0)
        runs.apply(agentID: second, children: [Fixture.child("same", state: "complete")], now: at(30))

        _ = runs.sweep(now: at(61))

        #expect(runs.children(of: first).isEmpty)
        #expect(runs.children(of: second).map(\.runID) == ["same"])
    }

    /// A question waiting on the user is never swept by the terminal TTL.
    @Test func rowsNeedingAttentionOutliveTheTTLUntilAnswered() {
        var runs = runs(ttl: 60, staleAfter: 1_000)
        let agent = AgentID()
        let question = Fixture.child("question", state: "complete", attention: true)
        runs.apply(agentID: agent, children: [question, Fixture.child("history", state: "complete")], now: t0)

        _ = runs.sweep(now: at(61))
        #expect(runs.children(of: agent).map(\.runID) == ["question"])
        #expect(runs.attentionCount == 1)

        // Answered: the TTL starts now, not from when it first finished.
        runs.apply(agentID: agent, children: [Fixture.child("question", state: "complete")], now: at(100))
        _ = runs.sweep(now: at(159))
        #expect(runs.children(of: agent).count == 1)
        _ = runs.sweep(now: at(161))
        #expect(runs.children(of: agent).isEmpty)
    }

    /// A killed pi can't strand "running" rows: no publish for `staleAfter` drops them.
    @Test func aStalePublisherLosesItsLiveRows() {
        var runs = runs(staleAfter: 120)
        let agent = AgentID()
        runs.apply(agentID: agent, children: [Fixture.child("a"), Fixture.child("q", attention: true)], now: t0)

        let changed = runs.sweep(now: at(121))

        #expect(changed)
        #expect(runs.children(of: agent).isEmpty)
        #expect(runs.attentionCount == 0)
    }

    /// Finished native runs keep an inspectable transcript until the publisher removes them or
    /// the parent exits — the completed-run ledger stays reachable from the sidebar.
    @Test func finishedNativeTranscriptsOutliveTheTTLAndAStalePublisher() {
        var runs = runs(ttl: 300, staleAfter: 120)
        let agent = AgentID()
        let native = Fixture.child("native", state: "complete", sessionFile: "/tmp/child.jsonl")
        let failed = Fixture.child("failed", state: "failed", sessionFile: "/tmp/failed.jsonl")
        let batch = [native, failed, Fixture.child("legacy", state: "complete"), Fixture.child("live")]
        runs.apply(agentID: agent, children: batch, now: t0)
        runs.apply(agentID: agent, children: batch, now: at(301))
        #expect(runs.children(of: agent).map(\.runID) == ["native", "failed", "live"])

        let staleChanged = runs.sweep(now: at(500))
        #expect(staleChanged)
        #expect(runs.children(of: agent).map(\.runID) == ["native", "failed"])
        let laterChanged = runs.sweep(now: at(1_000))
        #expect(!laterChanged)

        runs.apply(agentID: agent, children: [native], now: at(1_001))
        #expect(runs.children(of: agent).map(\.runID) == ["native"])
    }

    @Test func clearingAnAgentForgetsItsRowsAndClocksWithoutTouchingOthers() {
        var runs = runs(ttl: 60)
        let first = AgentID()
        let second = AgentID()
        runs.apply(agentID: first, children: [Fixture.child("same", state: "complete")], now: t0)
        runs.apply(agentID: second, children: [Fixture.child("other")], now: t0)

        runs.clear(agent: first)
        // Republished after the clear: its TTL restarts rather than inheriting the old clock.
        runs.apply(agentID: first, children: [Fixture.child("same", state: "complete")], now: at(30))
        _ = runs.sweep(now: at(61))

        #expect(runs.children(of: first).map(\.runID) == ["same"])
        #expect(runs.children(of: second).map(\.runID) == ["other"])
    }

    @Test func aStalePublisherOnlyPurgesItsOwnAgent() {
        var runs = runs(ttl: 60, staleAfter: 120)
        let quiet = AgentID()
        let active = AgentID()
        runs.apply(agentID: quiet, children: [Fixture.child("a")], now: t0)
        runs.apply(agentID: active, children: [Fixture.child("b")], now: at(100))

        _ = runs.sweep(now: at(150))

        #expect(runs.children(of: quiet).isEmpty)
        #expect(runs.children(of: active).map(\.runID) == ["b"])
    }

    @Test func attentionRollsUpAcrossTheFleet() {
        var runs = runs()
        runs.apply(agentID: AgentID(), children: [Fixture.child("a", attention: true), Fixture.child("b")], now: t0)
        runs.apply(agentID: AgentID(), children: [Fixture.child("c", attention: true)], now: t0)
        #expect(runs.attentionCount == 2)
    }

    /// A pi-subagents vocabulary addition must never let a possibly-running row be swept.
    @Test(arguments: [
        ("complete", true), ("failed", true), ("stopped", true), ("paused", true), ("rejected", true),
        ("running", false), ("queued", false), ("hibernating", false),
    ])
    func onlyKnownFinishedStatesAreTerminal(state: String, terminal: Bool) {
        #expect(Fixture.child("x", state: state).isTerminal == terminal)
    }
}
