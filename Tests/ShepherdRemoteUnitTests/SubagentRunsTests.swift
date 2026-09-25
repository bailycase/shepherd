import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The touch client's subagent runs (MobileSubagents, MobileSubagent, MobileSteer boards).
@Suite("Subagent runs on touch")
struct SubagentRunsTests {
    static let start: Double = 1_000_000

    static func run(_ id: String, state: String = "running", label: String? = nil, role: String? = nil, startedAt: Double? = nil,
                    endedAt: Double? = nil, needsAttention: Bool = false, paused: Bool? = nil, toolCallID: String? = nil) -> ChildRun {
        ChildRun(runID: id, label: label ?? id, state: state, startedAt: startedAt, endedAt: endedAt, needsAttention: needsAttention,
                 role: role, toolCallID: toolCallID, paused: paused)
    }

    // MARK: Phases

    @Test(arguments: [
        ("running", false, nil, NativeRunPhase.running), ("queued", false, nil, .queued), ("running", false, true, .paused),
        ("queued", false, true, .paused), ("running", true, nil, .needsYou), ("complete", false, nil, .done),
        ("failed", false, nil, .failed), ("stopped", false, nil, .failed), ("pondering", false, nil, .running),
    ] as [(String, Bool, Bool?, NativeRunPhase)])
    func runsMapToTheirPhase(state: String, needsAttention: Bool, paused: Bool?, expected: NativeRunPhase) {
        #expect(nativeRunPhase(Self.run("r", state: state, needsAttention: needsAttention, paused: paused)) == expected)
    }

    @Test func onlyUnfinishedPhasesAreLive() {
        #expect(NativeRunPhase.allCases.filter(\.isLive) == [.running, .queued, .paused, .needsYou])
    }

    // MARK: Names

    @Test(arguments: [
        ("worker: restyle", "worker", "worker", nil), ("worker", "worker", "worker", nil),
        ("frontend", "worker", "frontend", "worker"), ("scout", nil, "scout", nil),
    ] as [(String, String?, String, String?)])
    func aNativeChildIsNamedByItsRoleAndALaneByItsKey(label: String, role: String?, name: String, tag: String?) {
        let names = nativeRunNames(Self.run("r", label: label, role: role))
        #expect(names.name == name)
        #expect(names.role == tag)
    }

    // MARK: Summaries

    @Test func aRunningRunShowsItsStepContextTokensAndLastCall() {
        var run = Self.run("w", label: "worker: restyle", role: "worker", startedAt: Self.start)
        run.context = "background"
        run.model = "anthropic/fable-5-1"
        run.step = ChildStep(index: 1, total: 3)
        run.contextPercent = 34
        run.tokens = 922_000
        run.lastActivity = ChildActivity(tool: "edit", preview: "Sources/ShepherdRemote/NativeThreadPresentation.swift", at: Self.start)
        let summary = nativeRunSummary(run)
        #expect(summary.name == "worker")
        #expect(summary.tags == "background · fable-5-1")
        #expect(summary.phase == .running)
        #expect(summary.step == "step 1 of 3")
        #expect(summary.progress == 0.34)
        #expect(summary.tokens == "922k")
        #expect(summary.detail == "edit NativeThreadPresentation.swift")
        #expect(summary.compactDetail == "step 1 of 3 · edit NativeThreadPresentation.swift")
        #expect(summary.meta == nil)
    }

    @Test func aRunWaitingOnYouCarriesItsQuestionAndWhenItAsked() {
        var run = Self.run("r", role: "reviewer", startedAt: Self.start, needsAttention: true)
        run.question = ChildQuestion(text: "Two token names collide with `Tokens.textSecondary`. Rename the new ones, or replace the old ones everywhere?",
                                     options: ["Replace everywhere", "Rename new ones"])
        run.lastActivity = ChildActivity(tool: "shepherd_parent_message", at: Self.start + 5_000)
        let summary = nativeRunSummary(run)
        #expect(summary.phase == .needsYou)
        #expect(summary.options == ["Replace everywhere", "Rename new ones"])
        #expect(summary.askedAt == Self.start + 5_000)
        #expect(summary.compactDetail == "needs you: Rename the new ones, or replace the old ones everywhere?")
    }

    @Test func aWaitWithoutAParentMessageHasNoStart() {
        var run = Self.run("r", needsAttention: true)
        run.attentionText = "Which base?"
        run.lastActivity = ChildActivity(tool: "read", at: Self.start)
        let summary = nativeRunSummary(run)
        #expect(summary.askedAt == nil)
        #expect(summary.question == "Which base?")
    }

    @Test func theCallInFlightIsTheCardsLineAndTheTranscriptsTail() {
        var run = Self.run("w", role: "worker")
        run.currentTool = "bash"
        run.lastActivity = ChildActivity(kind: ChildActivity.runningKind, tool: "bash", preview: "sleep 25", at: Self.start)
        #expect(nativeRunSummary(run).detail == "bash sleep 25")
        #expect(nativeRunWorking(run) == "Running bash sleep 25…")
    }

    /// A finished call never names the one running now: an older host reports finished calls only.
    @Test(arguments: [
        (nil, nil, nil, "Thinking…"),
        (true, "bash", ChildActivity(kind: ChildActivity.runningKind, tool: "bash", preview: "sleep 25", at: 1), "Pause requested"),
        (nil, "bash", ChildActivity(tool: "bash", preview: "swift build", at: 1), "Running bash…"),
        (nil, "bash", nil, "Running bash…"),
        (nil, "edit", ChildActivity(kind: ChildActivity.runningKind, tool: "read", preview: "A.swift", at: 1), "Running edit…"),
        (nil, "edit", ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/App/ThreadView.swift", at: 1), "Running edit ThreadView.swift…"),
    ] as [(Bool?, String?, ChildActivity?, String)])
    func aLiveRunsTailNamesOnlyTheCallInFlight(paused: Bool?, tool: String?, activity: ChildActivity?, line: String) {
        var run = Self.run("w", paused: paused)
        run.currentTool = tool
        run.lastActivity = activity
        #expect(nativeRunWorking(run) == line)
    }

    @Test func aFinishedRunShowsItsFirstSentenceDiffAndMeta() {
        var run = Self.run("t", state: "complete", role: "tests", startedAt: Self.start, endedAt: Self.start + 242_000)
        run.summary = "Added 6 **presentation** tests. All 14 pass."
        run.result = ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000)
        let summary = nativeRunSummary(run)
        #expect(summary.detail == "Added 6 presentation tests")
        #expect(summary.added == 96)
        #expect(summary.removed == 3)
        #expect(summary.meta == "2 files · 4m")
        #expect(summary.duration == 242)
        #expect(summary.result == "Added 6 **presentation** tests. All 14 pass.")
    }

    @Test func aFailedRunGivesItsReason() {
        var run = Self.run("f", state: "failed", startedAt: Self.start, endedAt: Self.start + 1_000)
        run.exitReason = "exit 1 · context limit reached"
        let summary = nativeRunSummary(run)
        #expect(summary.phase == .failed)
        #expect(summary.detail == "exit 1 · context limit reached")
        #expect(summary.result == "exit 1 · context limit reached")
    }

    @Test func editedFilesSumIntoTheDiffWithoutAResult() {
        var run = Self.run("e", state: "complete")
        run.files = [ChildFileChange(path: "a", added: 4, removed: 1), ChildFileChange(path: "b", added: 8, removed: 3)]
        let summary = nativeRunSummary(run)
        #expect(summary.added == 12)
        #expect(summary.removed == 4)
        #expect(summary.meta == "2 files")
    }

    @Test(arguments: [
        ("Rename or replace?", "Rename or replace?"),
        ("Two names collide. Rename the new ones, or replace the old?", "Rename the new ones, or replace the old?"),
        ("Tell me which base to use.", "Tell me which base to use."),
        ("Keep `MobileTokens`?", "Keep MobileTokens?"),
    ])
    func aQuestionIsShortenedToTheSentenceThatAsks(text: String, line: String) {
        #expect(nativeQuestionLine(text) == line)
    }

    // MARK: Sections and tallies

    @Test func theNewestSpawningTurnIsThisTurnAndTheRestAreEarlierNewestFirst() {
        let old1 = Self.run("old1", state: "complete", startedAt: 1, endedAt: 10, toolCallID: "c1")
        let old2 = Self.run("old2", state: "complete", startedAt: 2, endedAt: 20, toolCallID: "c2")
        let stillLive = Self.run("bg", startedAt: 3, toolCallID: "c3")
        let now1 = Self.run("now1", startedAt: 50, toolCallID: "c4")
        let now2 = Self.run("now2", state: "complete", startedAt: 40, endedAt: 60, toolCallID: "c5")
        let placements = [
            "t1": NativeSubagentPlacement(byToolCall: ["c1": [old1], "c2": [old2], "c3": [stillLive]]),
            "t3": NativeSubagentPlacement(byToolCall: ["c4": [now1], "c5": [now2]]),
        ]
        let sections = nativeRunSections([old1, old2, stillLive, now1, now2], placements: placements, turnOrder: ["u0", "t1", "u2", "t3"])
        #expect(sections.current.map(\.runID) == ["bg", "now2", "now1"])
        #expect(sections.earlier.map(\.runID) == ["old2", "old1"])
    }

    @Test func withoutPlacementsEveryRunIsCurrent() {
        let runs = [Self.run("b", startedAt: 2), Self.run("a", startedAt: 1)]
        #expect(nativeRunSections(runs, placements: [:], turnOrder: []).current.map(\.runID) == ["a", "b"])
    }

    @Test func theTallyCountsLivePhasesWhileAnyRunIsLive() {
        let runs = [Self.run("a"), Self.run("b", needsAttention: true), Self.run("c", state: "complete")]
        #expect(nativeRunTally(runs)?.text == "1 running · 1 needs you")
        #expect(nativeRunTally(runs)?.phase == .running)
        #expect(nativeRunTally([Self.run("b", needsAttention: true)])?.phase == .needsYou)
    }

    @Test func aFinishedTallySaysHowTheRunsEnded() {
        #expect(nativeRunTally([Self.run("a", state: "complete"), Self.run("b", state: "complete")])?.text == "all done")
        let mixed = nativeRunTally([Self.run("a", state: "complete"), Self.run("b", state: "failed")])
        #expect(mixed?.text == "1 done · 1 failed")
        #expect(mixed?.phase == .failed)
        #expect(nativeRunTally([]) == nil)
    }

    @Test func theWaitingLineNamesTheLiveRuns() {
        #expect(nativeRunWaitingLabel([Self.run("worker", startedAt: 1), Self.run("reviewer", startedAt: 2, needsAttention: true),
                                       Self.run("tests", state: "complete")]) == "Waiting on worker and reviewer")
        #expect(nativeRunWaitingLabel((1...4).map { Self.run("lane\($0)") }) == "Waiting on 4 subagents")
        #expect(nativeRunWaitingLabel([Self.run("tests", state: "complete")]) == nil)
    }

    @Test func aFinishedGroupStatusSpansFirstStartToLastEnd() {
        let runs = [Self.run("a", state: "complete", startedAt: 0, endedAt: 600_000),
                    Self.run("b", state: "complete", startedAt: 60_000, endedAt: 2_700_000)]
        #expect(nativeRunGroupStatus(runs) == "all done · 45m")
        #expect(nativeRunGroupStatus([Self.run("a")]) == nil)
    }

    @Test func theInspectorMetaEndsInWhenAFinishedRunEnded() {
        var run = Self.run("t", state: "complete", endedAt: 0)
        run.model = "anthropic/claude-sonnet"
        run.turns = 11
        let meta = nativeRunInspectorMeta(run, timeZone: TimeZone(identifier: "UTC")!)
        #expect(meta.meta == "claude-sonnet · 11 turns")
        #expect(meta.accent == "done 12:00")
    }

    // MARK: Controls and commands

    @Test(arguments: [
        (Self.run("r"), [NativeRunControl.pause, .stop]), (Self.run("q", state: "queued"), [.pause, .stop]),
        (Self.run("p", paused: true), [.continue, .stop]), (Self.run("n", needsAttention: true), [.stop]),
        (Self.run("d", state: "complete"), [.rerun]), (Self.run("f", state: "failed"), [.rerun]),
    ])
    func eachPhaseOffersItsControls(run: ChildRun, controls: [NativeRunControl]) {
        #expect(nativeRunControls(run) == controls)
    }

    @Test func controlsMapToTheirSubagentActions() {
        #expect(NativeRunControl.allCases.map { NativeRunCommand($0).action } == [.pause, .continue, .cancel, .resume])
        #expect(NativeRunControl.allCases.allSatisfy { NativeRunCommand($0).text == nil && NativeRunCommand($0).mode == nil })
    }

    @Test func aSteerReachesOnlyTheChildBeforeItsNextTurn() {
        let command = NativeRunCommand.steer("  also check the iPad layout \n")
        #expect(command?.action == .message)
        #expect(command?.text == "also check the iPad layout")
        #expect(command?.mode == .steer)
        #expect(NativeRunCommand.steer(" \n ") == nil)
        #expect(NativeRunCommand.answer("Rename new ones") == NativeRunCommand.steer("Rename new ones"))
    }

    @Test func onlyALiveRunTakesASteer() {
        #expect(nativeRunAcceptsSteer(Self.run("r")))
        #expect(nativeRunAcceptsSteer(Self.run("n", needsAttention: true)))
        #expect(!nativeRunAcceptsSteer(Self.run("d", state: "complete")))
    }

    // MARK: Transcript

    static func message(_ id: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: id)])
    }

    @Test func aFreshNewestPageKeepsOlderPagesAlreadyLoaded() {
        let current = ["a", "b", "c", "d"].map(Self.message)
        let page = NativeSubagentTranscript(runID: "r", messages: ["c", "d", "e"].map(Self.message), olderCursor: "c", earlierCount: 2)
        let spliced = nativeTranscriptSplice(current, newest: page)
        #expect(spliced.messages.map(\.entryID) == ["a", "b", "c", "d", "e"])
        #expect(!spliced.replaced)
    }

    @Test func aPageWithNoOverlapReplacesTheTranscript() {
        let page = NativeSubagentTranscript(runID: "r", messages: ["x", "y"].map(Self.message))
        let spliced = nativeTranscriptSplice(["a"].map(Self.message), newest: page)
        #expect(spliced.messages.map(\.entryID) == ["x", "y"])
        #expect(spliced.replaced)
    }

    @Test func anOlderPageGoesInFrontWithoutRepeats() {
        let page = NativeSubagentTranscript(runID: "r", messages: ["a", "b", "c"].map(Self.message))
        #expect(nativeTranscriptPrepend(["c", "d"].map(Self.message), older: page).map(\.entryID) == ["a", "b", "c", "d"])
    }

    @Test func aTranscriptCopiesAsRoleAndToolText() {
        let messages = [
            NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Run the tests")]),
            NativeThreadMessage(entryID: "t", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "ok")], toolName: "bash"),
            NativeThreadMessage(entryID: "e", role: "assistant", blocks: []),
        ]
        #expect(nativeTranscriptText(messages) == "user: Run the tests\n\n[bash] ok")
    }
}
