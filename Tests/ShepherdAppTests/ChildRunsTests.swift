import Testing
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdApp

@Suite("Child run rows")
struct ChildRunsTests {
    private func run(_ id: String, state: String = "running", attention: Bool = false) -> ChildRun {
        ChildRun(runID: id, label: id, state: state, needsAttention: attention)
    }

    @Test @MainActor func agentRowsShowOnlyStatusOrKeyboardBadges() {
        #expect(AgentRow.trailingAccessory(status: .done, badge: 1) == .status("done"))
        #expect(AgentRow.trailingAccessory(status: .blocked, badge: 1) == .status("blocked"))
        #expect(AgentRow.trailingAccessory(status: .working, badge: 1) == .badge(1))
        #expect(AgentRow.trailingAccessory(status: .working, badge: nil) == .none)
    }

    @Test func publishReplacesRowsWholesale() {
        var runs = ChildRuns()
        let agent = AgentID()
        runs.apply(agentID: agent, children: [run("a"), run("b")])
        #expect(runs.children(of: agent).count == 2)
        runs.apply(agentID: agent, children: [run("b")])
        #expect(runs.children(of: agent).map(\.runID) == ["b"])
    }

    @Test func terminalRowsUseEachAgentsOwnTimestamp() {
        var runs = ChildRuns()
        runs.terminalTTL = 60
        let firstAgent = AgentID()
        let secondAgent = AgentID()
        let t0 = Date()

        runs.apply(agentID: firstAgent, children: [run("same", state: "complete")], now: t0)
        runs.apply(
            agentID: secondAgent,
            children: [run("same", state: "complete")],
            now: t0.addingTimeInterval(30)
        )
        _ = runs.sweep(now: t0.addingTimeInterval(61))

        #expect(runs.children(of: firstAgent).isEmpty)
        #expect(runs.children(of: secondAgent).map(\.runID) == ["same"])
    }

    @Test func terminalRowsSurviveThenExpire() {
        var runs = ChildRuns()
        runs.terminalTTL = 60
        let agent = AgentID()
        let t0 = Date()
        // A finished lane stays visible next to a running one…
        runs.apply(agentID: agent, children: [run("a", state: "complete"), run("b")], now: t0)
        #expect(runs.children(of: agent).count == 2)
        // …keeps its original terminal timestamp across republish…
        runs.apply(agentID: agent, children: [run("a", state: "complete"), run("b")], now: t0.addingTimeInterval(30))
        #expect(runs.children(of: agent).count == 2)
        // …and expires TTL after it first went terminal.
        runs.apply(agentID: agent, children: [run("a", state: "complete"), run("b")], now: t0.addingTimeInterval(61))
        #expect(runs.children(of: agent).map(\.runID) == ["b"])
    }

    @Test func unansweredTerminalRowsSurviveTTLUntilAttentionClears() {
        var runs = ChildRuns()
        runs.terminalTTL = 60
        let agent = AgentID()
        let t0 = Date()
        let question = run("question", state: "complete", attention: true)
        runs.apply(agentID: agent, children: [question, run("history", state: "complete")], now: t0)
        let expiredHistory = runs.sweep(now: t0.addingTimeInterval(61))
        #expect(expiredHistory)
        #expect(runs.children(of: agent).map(\.runID) == ["question"])
        runs.apply(agentID: agent, children: [question], now: t0.addingTimeInterval(90))
        let expiredQuestion = runs.sweep(now: t0.addingTimeInterval(151))
        #expect(!expiredQuestion)
        #expect(runs.attentionCount == 1)
        runs.apply(agentID: agent, children: [run("question", state: "complete")], now: t0.addingTimeInterval(152))
        #expect(runs.children(of: agent).count == 1)
        let expiredAnswer = runs.sweep(now: t0.addingTimeInterval(213))
        #expect(expiredAnswer)
        #expect(runs.children(of: agent).isEmpty)
        runs.apply(agentID: agent, children: [question], now: t0.addingTimeInterval(214))
        let expiredPublisher = runs.sweep(now: t0.addingTimeInterval(335))
        #expect(expiredPublisher)
        #expect(runs.children(of: agent).isEmpty)
    }

    @Test func finishedNativeTranscriptsRemainInspectableUntilRemoved() {
        var runs = ChildRuns()
        let agent = AgentID()
        let t0 = Date()
        let completed = ChildRun(runID: "native", label: "worker", state: "complete", sessionFile: "/tmp/child.jsonl")
        let failed = ChildRun(runID: "failed", label: "reviewer", state: "failed", sessionFile: "/tmp/failed.jsonl")
        runs.apply(agentID: agent, children: [completed, failed, run("legacy", state: "complete"), run("live")], now: t0)
        // A fresh publish after the legacy terminal TTL must keep the finished native rows.
        runs.apply(agentID: agent, children: [completed, failed, run("legacy", state: "complete"), run("live")],
                   now: t0.addingTimeInterval(301))
        #expect(runs.children(of: agent).map(\.runID) == ["native", "failed", "live"])
        // No further updates: stale live rows go away, finished transcripts stay clickable.
        let staleChanged = runs.sweep(now: t0.addingTimeInterval(500))
        #expect(staleChanged)
        #expect(runs.children(of: agent).map(\.runID) == ["native", "failed"])
        let laterChanged = runs.sweep(now: t0.addingTimeInterval(1_000))
        #expect(!laterChanged)
        // A publisher's explicit removal and parent shutdown still clear retained rows.
        runs.apply(agentID: agent, children: [completed], now: t0.addingTimeInterval(1_001))
        #expect(runs.children(of: agent).map(\.runID) == ["native"])
        runs.clear(agent: agent)
        #expect(runs.children(of: agent).isEmpty)
    }

    @Test func stalePublisherLosesAllRows() {
        var runs = ChildRuns()
        runs.staleAfter = 120
        let agent = AgentID()
        let t0 = Date()
        runs.apply(agentID: agent, children: [run("a")], now: t0)
        // Live row, but no publish for > staleAfter: publisher is gone.
        let changed = runs.sweep(now: t0.addingTimeInterval(121))
        #expect(changed)
        #expect(runs.children(of: agent).isEmpty)
    }

    @Test func sweepReportsNoChangeWhenQuiet() {
        var runs = ChildRuns()
        let agent = AgentID()
        let t0 = Date()
        runs.apply(agentID: agent, children: [run("a")], now: t0)
        let changed = runs.sweep(now: t0.addingTimeInterval(1))
        #expect(!changed)
    }

    @Test func unknownStatesCountAsLive() {
        // A pi-subagents vocabulary addition must never let a row be swept
        // while possibly still running.
        let future = ChildRun(runID: "x", label: "x", state: "hibernating")
        #expect(!future.isTerminal)
    }

    @Test func attentionFeedsTheRollup() {
        var runs = ChildRuns()
        runs.apply(agentID: AgentID(), children: [run("a", attention: true), run("b")])
        runs.apply(agentID: AgentID(), children: [run("c", attention: true)])
        #expect(runs.attentionCount == 2)
    }

    @Test func clearPurgesAgentTimestampsWithoutTouchingAnotherAgent() {
        var runs = ChildRuns()
        runs.terminalTTL = 60
        let firstAgent = AgentID()
        let secondAgent = AgentID()
        let t0 = Date()

        runs.apply(agentID: firstAgent, children: [run("same", state: "complete")], now: t0)
        runs.apply(agentID: secondAgent, children: [run("same", state: "complete")], now: t0)
        runs.clear(agent: firstAgent)
        runs.apply(
            agentID: secondAgent,
            children: [run("same", state: "complete")],
            now: t0.addingTimeInterval(30)
        )
        _ = runs.sweep(now: t0.addingTimeInterval(61))

        #expect(runs.children(of: firstAgent).isEmpty)
        #expect(runs.children(of: secondAgent).isEmpty)
    }

    @Test func stalePublisherPurgesOnlyItsAgentTimestamps() {
        var runs = ChildRuns()
        runs.terminalTTL = 60
        runs.staleAfter = 120
        let firstAgent = AgentID()
        let secondAgent = AgentID()
        let t0 = Date()

        runs.apply(agentID: firstAgent, children: [run("same", state: "complete")], now: t0)
        runs.apply(agentID: secondAgent, children: [run("same", state: "complete")], now: t0)
        _ = runs.sweep(now: t0.addingTimeInterval(121))
        runs.apply(
            agentID: secondAgent,
            children: [run("same", state: "complete")],
            now: t0.addingTimeInterval(121)
        )
        _ = runs.sweep(now: t0.addingTimeInterval(150))

        #expect(runs.children(of: firstAgent).isEmpty)
        #expect(runs.children(of: secondAgent).map(\.runID) == ["same"])
    }
}
