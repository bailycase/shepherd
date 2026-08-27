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

    @Test @MainActor func terminalAgentStatusesHideSubagentsAndOverrideBadges() {
        #expect(!AgentRow.showsSubagents(for: .done))
        #expect(!AgentRow.showsSubagents(for: .blocked))
        #expect(AgentRow.showsSubagents(for: .working))
        #expect(AgentRow.showsSubagents(for: .idle))
        #expect(AgentRow.trailingAccessory(status: .done, badge: 1, subCount: 2) == .status("done"))
        #expect(AgentRow.trailingAccessory(status: .blocked, badge: 1, subCount: 2) == .status("blocked"))
        #expect(AgentRow.trailingAccessory(status: .working, badge: 1, subCount: 2) == .badge(1))
        #expect(AgentRow.trailingAccessory(status: .working, badge: nil, subCount: 2) == .subagents(2))
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

@Suite("Child inspector command")
@MainActor
struct ChildInspectorCommandTests {
    @Test func quotesPathsAndTargetsChildIndex() {
        let command = ShepherdViewModel.inspectorCommand(
            runner: "/Users/x/Library/Application Support/Shepherd/shepherd-inspect.mjs",
            asyncDir: "/tmp/dir with spaces/run-1",
            runID: "run-1",
            childIndex: 2
        )
        #expect(command == "node '/Users/x/Library/Application Support/Shepherd/shepherd-inspect.mjs' --async-dir '/tmp/dir with spaces/run-1' --run-id 'run-1' --index 2")
    }

    @Test func omitsIndexForSingleRuns() {
        let command = ShepherdViewModel.inspectorCommand(
            runner: "/r.mjs", asyncDir: "/a", runID: "id", childIndex: nil
        )
        #expect(!command.contains("--index"))
    }
}
