import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Subagent cards")
struct SubagentCardTests {
    @Test func boardRunsMapToTheFourCardStates() {
        #expect(Board.cards.map(nativeSubagentState) == [.running, .needsYou, .done, .failed])
    }

    @Test(arguments: [
        ("queued", false, NativeSubagentState.running), ("running", false, .running), ("complete", false, .done),
        ("failed", false, .failed), ("stopped", false, .failed), ("rejected", false, .failed), ("paused", false, .failed),
        ("pondering", false, .running), ("complete", true, .needsYou),
    ])
    func stateMapping(state: String, needsAttention: Bool, expected: NativeSubagentState) {
        #expect(nativeSubagentState(Fixture.run("r", state: state, needsAttention: needsAttention)) == expected)
    }

    @Test func liveRunsCountToNowAndFinishedRunsFreezeAtTheirEnd() {
        #expect(nativeSubagentElapsed(Board.worker, now: Board.now).map { nativeDurationText($0, live: true) } == "37m 21s")
        #expect(nativeSubagentElapsed(Board.reviewer, now: Board.now).map { nativeDurationText($0, live: true) } == "2m 10s")
        #expect(nativeSubagentElapsed(Board.tests, now: Board.now.addingTimeInterval(9999)).map { nativeDurationText($0, live: true) } == "4m 02s")
    }

    @Test func elapsedIsUnknownWithoutAStartAndZeroForAnEndlessFinishedRun() {
        #expect(nativeSubagentElapsed(Fixture.run("n"), now: Board.now) == nil)
        #expect(nativeSubagentElapsed(Fixture.run("f", state: "failed", startedAt: 5), now: Board.now) == 0)
    }
}

@Suite("Subagent rollups")
struct SubagentRollupTests {
    @Test func headerRollupCountsRunsAndTokens() {
        #expect(nativeSubagentRollup(Board.cards) == "4 subagents · 1.1m tok")
        #expect(nativeSubagentRollup([Fixture.run("a")]) == "1 subagent")
        #expect(nativeSubagentRollup([]) == nil)
    }

    @Test func needsYouLabelAgreesInNumber() {
        #expect(nativeSubagentNeedsYouLabel(Board.cards) == "1 subagent needs you")
        #expect(nativeSubagentNeedsYouLabel([Board.reviewer, Board.reviewer]) == "2 subagents need you")
        #expect(nativeSubagentNeedsYouLabel([Board.worker]) == nil)
    }
}

@Suite("Subagent groups")
struct SubagentGroupTests {
    @Test func aGroupIsTerminalOnlyWhenEveryRunFinishedWithoutAsking() {
        #expect(nativeSubagentGroupIsTerminal(Board.done))
        #expect(!nativeSubagentGroupIsTerminal(Board.cards))
        #expect(!nativeSubagentGroupIsTerminal([]))
        var asking = Board.done[0]
        asking.needsAttention = true
        #expect(!nativeSubagentGroupIsTerminal([asking]))
    }
}

@Suite("Subagent placement")
struct SubagentPlacementTests {
    typealias F = Fixture

    @Test func runsSitAtTheirSpawnCallOrTrailTheLastAgentTurn() {
        let spawnA = F.tool("shepherd_child_start", callID: "spawn-a"), spawnB = F.tool("shepherd_child_start", callID: "spawn-b")
        let turns = nativeTurns([F.user(), F.assistant("Splitting."), spawnA, F.tool("read"), F.user(), spawnB])
        let runA = F.run("ra", toolCallID: "spawn-a"), runB = F.run("rb", toolCallID: "spawn-b")
        let orphan = F.run("ro", state: "complete", toolCallID: "gone"), bare = F.run("rn")
        let placements = nativeSubagentPlacements([runA, runB, orphan, bare], turns: turns)
        #expect(placements[turns[1].id] == NativeSubagentPlacement(byToolCall: ["spawn-a": [runA]]))
        #expect(placements[turns[3].id] == NativeSubagentPlacement(byToolCall: ["spawn-b": [runB]], trailing: [orphan, bare]))
        #expect(placements.count == 2)
    }

    @Test func runsSharingASpawnCallStayTogetherInPublishOrder() {
        let turns = nativeTurns([F.user(), F.tool("subagent", callID: "fan")])
        let lanes = [F.run("l0", toolCallID: "fan"), F.run("l1", toolCallID: "fan")]
        #expect(nativeSubagentPlacements(lanes, turns: turns)[turns[1].id]?.byToolCall["fan"] == lanes)
    }

    @Test func aPlacementListsEveryRunAndKnowsWhenItIsEmpty() {
        let a = F.run("a"), b = F.run("b")
        let placement = NativeSubagentPlacement(byToolCall: ["x": [a]], trailing: [b])
        #expect(placement.all == [a, b] && !placement.isEmpty)
        #expect(NativeSubagentPlacement().isEmpty)
    }

    @Test func siblingsStepInSpawnOrderWithinTheirGroup() {
        let spawn = { (id: String) in F.tool("shepherd_child_start", callID: id) }
        let other = ChildRun(runID: "native-other", label: "docs", state: "complete", startedAt: 0, toolCallID: "spawn-other")
        let turns = nativeTurns([F.user(), spawn("spawn-other"), F.user(), spawn("spawn-tests"), spawn("spawn-worker"), spawn("spawn-reviewer")])
        #expect(nativeSubagentSiblings(of: "native-tests", in: Board.done.reversed() + [other], turns: turns).map(\.runID)
            == ["native-worker", "native-reviewer", "native-tests"])
        #expect(nativeSubagentSiblings(of: "native-other", in: Board.done + [other], turns: turns).map(\.runID) == ["native-other"])
    }

    @Test func withNoSpawnRowsLoadedEveryRunIsASibling() {
        #expect(nativeSubagentSiblings(of: "native-tests", in: Board.done.reversed(), turns: []).map(\.runID)
            == ["native-worker", "native-reviewer", "native-tests"])
    }
}
