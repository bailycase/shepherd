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

    @Test func countersListTurnsToolsAndTokens() {
        #expect(nativeSubagentCounters(Board.worker) == "78 turns · 82 tools · 922k tok")
        let one = ChildRun(runID: "a", label: "l", state: "running", turns: 1, toolCalls: 1, tokens: 1_600_000)
        #expect(nativeSubagentCounters(one) == "1 turn · 1 tool · 1.6m tok")
        #expect(nativeSubagentCounters(Fixture.run("bare")) == "")
    }

    @Test func resultLineIsTheDoneCardFooter() {
        #expect(nativeSubagentResultLine(Board.tests.result!) == ["2 files", "+96 -3", "19 tools", "118k tok"])
        #expect(nativeSubagentResultLine(ChildResultSummary(files: 1, added: 0, removed: 0, tools: 1, tokens: 5))
            == ["1 file", "+0 -0", "1 tool", "5 tok"])
    }

    @Test func liveRunsCountToNowAndFinishedRunsFreezeAtTheirEnd() {
        #expect(nativeSubagentElapsed(Board.worker, now: Board.now).map(nativeSubagentDurationText) == "37m 21s")
        #expect(nativeSubagentElapsed(Board.reviewer, now: Board.now).map(nativeSubagentDurationText) == "2m 10s")
        #expect(nativeSubagentElapsed(Board.tests, now: Board.now.addingTimeInterval(9999)).map(nativeSubagentDurationText) == "4m 02s")
    }

    @Test func elapsedIsUnknownWithoutAStartAndZeroForAnEndlessFinishedRun() {
        #expect(nativeSubagentElapsed(Fixture.run("n"), now: Board.now) == nil)
        #expect(nativeSubagentElapsed(Fixture.run("f", state: "failed", startedAt: 5), now: Board.now) == 0)
    }

    @Test func accessibilityLabelNamesRoleStateAndMinutes() {
        #expect(nativeSubagentAccessibilityLabel(Board.worker, now: Board.now) == "worker, running, 37 minutes")
        #expect(nativeSubagentAccessibilityLabel(Board.reviewer, now: Board.now) == "reviewer, needs you, 2 minutes")
        #expect(nativeSubagentAccessibilityLabel(Board.tests, now: Board.now) == "tests, done, 4 minutes")
        #expect(nativeSubagentAccessibilityLabel(Board.docs, now: Board.now) == "docs, failed, 13 minutes")
    }

    @Test func accessibilityLabelFallsBackToTheLabelAndSeconds() {
        let brief = Fixture.run("scout", startedAt: Board.nowMS - 42_000)
        #expect(nativeSubagentAccessibilityLabel(brief, now: Board.now) == "scout, running, 42 seconds")
        #expect(nativeSubagentAccessibilityLabel(Fixture.run("scout"), now: Board.now) == "scout, running")
        let single = Fixture.run("scout", startedAt: Board.nowMS - 61_000)
        #expect(nativeSubagentAccessibilityLabel(single, now: Board.now) == "scout, running, 1 minute")
    }
}

@Suite("Subagent rollups and runs strip")
struct SubagentRollupTests {
    /// 7 done, 3 running, 1 needs you, 1 failed, spawned a second apart over 12 minutes.
    static var twelve: [ChildRun] {
        (0..<12).map { i in
            let state = i < 7 ? "complete" : i < 11 ? "running" : "failed"
            return Fixture.run("r\(i)", state: state, startedAt: Board.nowMS - 12 * 60_000 + Double(i) * 1000,
                               endedAt: state == "running" ? nil : Board.nowMS - 60_000, needsAttention: i == 10,
                               tokens: i == 0 ? 581_000 : nil)
        }
    }

    @Test func stripSummarizesStatesTotalsAndSpawnOrderCells() {
        let summary = nativeRunsStripSummary(Self.twelve.reversed(), now: Board.now)
        #expect(summary.count == 12)
        #expect(summary.states == "7 done · 3 running · 1 needs you · 1 failed")
        #expect(summary.totals == "581k tok · 12m")
        #expect(summary.cells == Array(repeating: .done, count: 7) + Array(repeating: .running, count: 3) + [.needsYou, .failed])
    }

    @Test func aFinishedStripMeasuresEarliestStartToLatestEnd() {
        let runs = [Fixture.run("a", state: "complete", startedAt: 0, endedAt: 120_000),
                    Fixture.run("b", state: "complete", startedAt: 60_000, endedAt: 300_000)]
        #expect(nativeRunsStripSummary(runs, now: Board.now).totals == "5m")
    }

    @Test func anEmptyStripIsBlank() {
        #expect(nativeRunsStripSummary([], now: Board.now) == NativeRunsStripSummary(count: 0, states: "", totals: "", cells: []))
        #expect(NativeRunsStripSummary.collapseThreshold == 3)
    }

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

    @Test func runningLabelCountsOnlyRunningCardsAgainstAllRuns() {
        #expect(nativeSubagentRunningLabel([Board.worker, Board.reviewer, Board.tests], now: Board.now) == "1 of 3 subagents running · 37m")
        #expect(nativeSubagentRunningLabel([Fixture.run("a")], now: Board.now) == "1 of 1 subagent running")
        #expect(nativeSubagentRunningLabel([Board.tests], now: Board.now) == nil)
    }
}

@Suite("Subagent ledger")
struct SubagentLedgerTests {
    @Test func aGroupIsTerminalOnlyWhenEveryRunFinishedWithoutAsking() {
        #expect(nativeSubagentGroupIsTerminal(Board.done))
        #expect(!nativeSubagentGroupIsTerminal(Board.cards))
        #expect(!nativeSubagentGroupIsTerminal([]))
        var asking = Board.done[0]
        asking.needsAttention = true
        #expect(!nativeSubagentGroupIsTerminal([asking]))
    }

    @Test func ledgerSummarizesACompletedGroup() {
        let ledger = nativeSubagentLedger(Board.done.reversed())
        #expect(ledger.title == "3 subagents")
        #expect(ledger.status == "all done · 45m wall · 1.5m tok")
        #expect(ledger.added == 318 && ledger.removed == 64)
        #expect(ledger.files == 6 && ledger.diffText == "6 files", "paths touched by two runs count once")
    }

    /// Every arrival order of the three runs, as indexes into `Board.done`.
    @Test(arguments: [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    func rowsFollowSpawnOrderWithFirstSentenceSummaries(arrival: [Int]) {
        let rows = nativeSubagentLedger(arrival.map { Board.done[$0] }).rows
        #expect(rows.map(\.run.role) == ["worker", "reviewer", "tests"])
        #expect(rows.map(\.state) == [.done, .done, .done])
        #expect(rows[0].summary == "Restyled desktop thread, sidebar, composer and iOS to the spec; system…")
        #expect(rows[1].summary == "Two token collisions fixed.", "falls back to the output")
        #expect(rows[2].summary == "Added 6 tests.")
        #expect(rows.allSatisfy { $0.summary.count <= NativeSubagentLedger.summaryLimit })
        #expect(rows.map(\.meta) == ["5 files · 118 tools · 41m", "24 tools · 12m", "2 files · 19 tools · 4m"])
    }

    @Test func aFailedRunChangesTheHeaderAndShowsItsExitReason() {
        var failed = Board.done[2]
        failed.state = "failed"
        failed.exitReason = "exit 1 · context limit reached"
        failed.result = nil
        failed.files = nil
        let ledger = nativeSubagentLedger([Board.done[0], Board.done[1], failed])
        #expect(ledger.status == "2 done · 1 failed · 45m wall · 1.5m tok")
        #expect(ledger.rows[2].state == .failed && ledger.rows[2].summary == "exit 1 · context limit reached")
        #expect(ledger.added == 200 && ledger.files == 5)
    }

    @Test func aFailedRunWithoutAReasonShowsItsState() {
        #expect(nativeSubagentLedger([Fixture.run("x", state: "stopped")]).rows[0].summary == "stopped")
    }

    @Test func aBareGroupHasNoWallTimeNoTokensAndNoDiffSlot() {
        let bare = nativeSubagentLedger([Fixture.run("x", state: "complete")])
        #expect(bare.title == "1 subagent" && bare.status == "all done")
        #expect(bare.diffText == nil && bare.rows[0].meta == "" && bare.rows[0].summary == "")
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
