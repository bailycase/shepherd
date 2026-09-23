import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Child runs as the Agents components show them: state, names, the card's one line, the
/// ledger and strip summaries, and the inspector header.
@Suite("Subagent presentation")
struct SubagentPresentationTests {
    /// 10:00:00 UTC, in milliseconds.
    private static let t0: Double = 1_700_042_400_000

    private static func run(_ id: String = "r", label: String = "worker: restyle", state: String = "running", role: String? = "worker",
                            startedAt: Double? = t0, endedAt: Double? = nil) -> ChildRun {
        ChildRun(runID: id, label: label, state: state, startedAt: startedAt, endedAt: endedAt, role: role)
    }

    // MARK: State

    @Test(arguments: [
        ("running", false, false, AgentState.running), ("queued", false, false, .queued), ("running", true, false, .queued),
        ("running", false, true, .attention), ("complete", false, false, .done), ("failed", false, false, .failed),
        ("stopped", false, false, .failed),
    ])
    func runsMapOntoTheOneStatusEnum(state: String, paused: Bool, asking: Bool, expected: AgentState) {
        var run = Self.run(state: state)
        run.paused = paused
        run.needsAttention = asking
        #expect(SubagentPresentation.state(run) == expected)
    }

    @Test func aPausedRunSaysPausedNotQueued() {
        var run = Self.run()
        #expect(SubagentPresentation.stateLabel(run) == nil)
        run.paused = true
        #expect(SubagentPresentation.stateLabel(run) == "Paused")
        #expect(SubagentPresentation.card(run).detail == "paused before its next model request")
        #expect(SubagentPresentation.card(Self.run(state: "queued")).detail == "waiting to start")
    }

    @Test(arguments: [
        ("worker: restyle the thread", "worker", "worker", nil as String?),
        ("worker", "worker", "worker", nil),
        ("desktop", "worker", "desktop", "worker"),
        ("lane-3", nil, "lane-3", nil),
    ])
    func aCardIsNamedWithoutRepeatingItsRole(label: String, role: String?, name: String, tag: String?) {
        let names = SubagentPresentation.names(Self.run(label: label, role: role))
        #expect(names.name == name)
        #expect(names.role == tag)
    }

    // MARK: Card line

    @Test(arguments: [
        ("Sources/ShepherdRemote/NativeThreadPresentation.swift", "edit NativeThreadPresentation.swift"),
        ("swift build --target ShepherdRemote", "edit swift build --target ShepherdRemote"),
        ("", "edit"),
    ])
    func aRunningCardShowsItsLastCallWithAFileName(preview: String, line: String) {
        var run = Self.run()
        run.lastActivity = ChildActivity(tool: "edit", preview: preview, at: Self.t0)
        #expect(SubagentPresentation.activity(run) == line)
    }

    @Test func withNoFinishedCallTheCardShowsTheToolInFlight() {
        var run = Self.run()
        #expect(SubagentPresentation.activity(run) == "working")
        run.currentTool = "bash"
        #expect(SubagentPresentation.activity(run) == "bash")
    }

    @Test func aRunningCardMeasuresItsContextWindow() {
        var run = Self.run()
        #expect(SubagentPresentation.card(run).progress == nil)
        run.contextPercent = 62
        let card = SubagentPresentation.card(run)
        #expect(card.progress == 0.62)
        #expect(card.progressLabel == "Context window used")
    }

    /// Only a native child's ask gives an honest start for the wait.
    @Test func theWaitCountsFromTheAskOnly() {
        var run = Self.run()
        run.needsAttention = true
        run.question = ChildQuestion(text: "Keep the alias?", options: ["Migrate", "Keep alias"])
        run.lastActivity = ChildActivity(tool: "bash", at: Self.t0 + 5_000)
        #expect(SubagentPresentation.card(run).waitingSince == nil)
        run.lastActivity = ChildActivity(tool: "shepherd_parent_message", at: Self.t0 + 60_000)
        let card = SubagentPresentation.card(run)
        #expect(card.waitingSince == Date(timeIntervalSince1970: (Self.t0 + 60_000) / 1000))
        #expect(card.detail == "waiting on your answer")
        #expect(card.question == NWSubagentQuestion(text: "Keep the alias?", options: ["Migrate", "Keep alias"]))
    }

    @Test func aQuestionWithoutOptionsFallsBackToTheAttentionText() {
        var run = Self.run()
        run.needsAttention = true
        run.attentionText = "Which base?"
        #expect(SubagentPresentation.card(run).question == NWSubagentQuestion(text: "Which base?", options: []))
    }

    @Test func aDoneCardSaysWhatItDidThenToolsAndTime() {
        var run = Self.run(state: "complete", endedAt: Self.t0 + 12 * 60_000)
        run.summary = "2 spec deviations fixed. Both in the header."
        run.toolCalls = 26
        let card = SubagentPresentation.card(run)
        #expect(card.detail == "2 spec deviations fixed")
        #expect(card.detailMeta == "26 tools · 12m")
        run.summary = nil
        #expect(SubagentPresentation.card(run).detail == "finished")
    }

    @Test func aFailedCardSaysWhy() {
        var run = Self.run(state: "failed", endedAt: Self.t0 + 1_000)
        run.exitReason = "exit 1 · context limit reached after 41 turns"
        #expect(SubagentPresentation.card(run).detail == "exit 1 · context limit reached after 41 turns")
        run.exitReason = nil
        #expect(SubagentPresentation.card(run).detail == "failed")
    }

    @Test(arguments: [("Fixed it.", "Fixed it"), ("Fixed it", "Fixed it"), ("Wait...", "Wait..."), ("Done?", "Done?")])
    func aSentenceLeadingALineDropsItsPeriod(sentence: String, line: String) {
        #expect(SubagentPresentation.lineWithoutFinalPeriod(sentence) == line)
    }

    // MARK: Groups

    private static var finished: [ChildRun] {
        var worker = run("w", state: "complete", startedAt: t0, endedAt: t0 + 41 * 60_000)
        worker.summary = "Restyled the thread. Then the sidebar."
        worker.result = ChildResultSummary(files: 5, added: 200, removed: 60, tools: 118, tokens: 900_000)
        var reviewer = run("r", label: "reviewer: check", state: "complete", role: "reviewer", startedAt: t0 + 60_000, endedAt: t0 + 13 * 60_000)
        reviewer.output = "Two collisions fixed"
        reviewer.result = ChildResultSummary(files: 0, added: 0, removed: 0, tools: 24, tokens: 460_000)
        var tests = run("t", label: "tests: run", state: "complete", role: "tests", startedAt: t0 + 41 * 60_000, endedAt: t0 + 45 * 60_000)
        tests.result = ChildResultSummary(files: 2, added: 118, removed: 4, tools: 19, tokens: 118_000)
        return [tests, reviewer, worker]
    }

    @Test func theLedgerListsRunsInSpawnOrderWithFilesAndTime() {
        let ledger = SubagentPresentation.ledger(Self.finished)
        #expect(ledger.title == "3 subagents")
        #expect(ledger.state == .done)
        #expect(ledger.status == "all done · 45m")
        #expect(ledger.added == 318)
        #expect(ledger.removed == 64)
        #expect(ledger.entries.map(\.name) == ["worker", "reviewer", "tests"])
        #expect(ledger.entries.map(\.summary) == ["Restyled the thread.", "Two collisions fixed", ""])
        #expect(ledger.entries.map(\.meta) == ["5 files · 41m", "12m", "2 files · 4m"])
    }

    @Test func aLedgerWithAFailureCountsItAndTurnsRed() {
        var runs = Self.finished
        runs[0].state = "failed"
        runs[0].exitReason = "exit 1"
        let ledger = SubagentPresentation.ledger(runs)
        #expect(ledger.state == .failed)
        #expect(ledger.status == "2 done · 1 failed · 45m")
        #expect(ledger.entries.last?.summary == "exit 1")
    }

    @Test func theStripTalliesStatesAndCountsWhileAnyRunLives() {
        var runs = Self.finished
        runs.append(Self.run("live", startedAt: Self.t0 + 50 * 60_000))
        var asking = Self.run("ask", startedAt: Self.t0 + 51 * 60_000)
        asking.needsAttention = true
        runs.append(asking)
        runs[0].tokens = 1_000_000
        runs[1].tokens = 600_000
        let strip = SubagentPresentation.strip(runs)
        #expect(strip.title == "5 subagents")
        #expect(strip.states == "3 done · 1 running · 1 needs you")
        #expect(strip.state == .attention)
        #expect(strip.cells == [.done, .done, .done, .running, .attention])
        #expect(strip.tokens == "1.6m tok")
        #expect(strip.since == Date(timeIntervalSince1970: Self.t0 / 1000))
        #expect(strip.until == nil)
    }

    @Test func aStripWithoutTokensShowsOnlyItsTime() {
        #expect(SubagentPresentation.strip(Self.finished).tokens == nil)
        #expect(SubagentPresentation.strip(Self.finished).until == Date(timeIntervalSince1970: (Self.t0 + 45 * 60_000) / 1000))
    }

    @Test func fewLiveRunsAreCardsManyAreAStripAndAFinishedGroupIsALedger() {
        let live = (0..<3).map { Self.run("l\($0)") }
        #expect(SubagentPresentation.layout(live, turnLive: false) == .cards)
        #expect(SubagentPresentation.layout(live + [Self.run("l3")], turnLive: false) == .strip)
        #expect(SubagentPresentation.layout(Self.finished, turnLive: false) == .ledger)
        #expect(SubagentPresentation.layout(Self.finished, turnLive: true) == .cards)
    }

    // MARK: Inspector

    @Test func aLiveHeaderShowsModelThinkingTurnsAndTokens() {
        var run = Self.run()
        run.model = "anthropic/claude-fable-5-1"
        run.thinking = "high"
        run.turns = 78
        run.tokens = 922_000
        let (meta, accent) = SubagentPresentation.inspectorMeta(run)
        #expect(meta == "claude-fable-5-1 · thinking high · 78 turns · 922k tok")
        #expect(accent == nil)
    }

    @Test func aFinishedHeaderEndsWithWhenItFinished() {
        var run = Self.run(state: "complete", endedAt: Self.t0 + 62 * 60_000)
        run.model = "anthropic/claude-sonnet"
        run.thinking = "high"
        run.turns = 11
        let (meta, accent) = SubagentPresentation.inspectorMeta(run, timeZone: TimeZone(identifier: "UTC")!)
        #expect(meta == "claude-sonnet · 11 turns")
        #expect(accent == "done 11:02")
        run.state = "stopped"
        #expect(SubagentPresentation.inspectorMeta(run, timeZone: TimeZone(identifier: "UTC")!).accent == "stopped 11:02")
    }

    @Test func theGoalNoteShowsStepAndContextWhileLive() {
        var run = Self.run()
        #expect(SubagentPresentation.goalNote(run) == nil)
        run.step = ChildStep(index: 1, total: 1)
        run.contextPercent = 61.6
        #expect(SubagentPresentation.goalNote(run) == "step 1 / 1 · 62%")
        run.state = "complete"
        #expect(SubagentPresentation.goalNote(run) == nil)
    }

    @Test(arguments: [("anthropic/claude-sonnet", "claude-sonnet"), ("gpt-5", "gpt-5"), ("cpa/~anthropic/claude-haiku", "claude-haiku")])
    func modelTagsDropTheProvider(model: String, tag: String) {
        #expect(SubagentPresentation.modelTag(model) == tag)
    }
}
