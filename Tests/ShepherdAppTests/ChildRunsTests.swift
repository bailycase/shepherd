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

    @Test func sidebarElapsedIsCoarse() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(12)) == "12s")
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(125)) == "2m")
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(7_300)) == "2h")
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(200_000)) == "2d")
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(-5)) == "0s")
    }

    /// Spec §10: live groups are always expanded; a finished group folds for threads that are
    /// not selected unless the user unfolded it.
    @Test func finishedSubagentGroupsFoldOutsideTheSelectedThread() {
        let live = [run("a", state: "complete"), run("b")]
        let done = [run("a", state: "complete"), run("b", state: "failed")]
        #expect(!SubagentFolding.folded(children: live, selected: false, unfolded: false))
        #expect(SubagentFolding.folded(children: done, selected: false, unfolded: false))
        #expect(!SubagentFolding.folded(children: done, selected: true, unfolded: false))
        #expect(!SubagentFolding.folded(children: done, selected: false, unfolded: true))
        #expect(!SubagentFolding.folded(children: [], selected: false, unfolded: false))
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
