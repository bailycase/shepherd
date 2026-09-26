import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Child runs as the Agents components show them: state, names, the tray's rows and header,
/// its layout, and the inspector header.
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

    // MARK: Tray

    @Test(arguments: [(NativeRunPhase.running, AgentState.running), (.queued, .queued), (.paused, .queued), (.needsYou, .attention),
                      (.done, .done), (.failed, .failed)])
    func phasesMapOntoTheOneStatusEnum(phase: NativeRunPhase, state: AgentState) {
        #expect(SubagentPresentation.state(phase) == state)
    }

    /// The header's cells and tally keep their states; a quiet part carries none.
    @Test func theTrayHeaderCarriesItsStates() {
        var asking = Self.run("a", startedAt: Self.t0 + 1)
        asking.needsAttention = true
        let tray = NativeSubagentTray([Self.run("w"), asking, Self.run("t", state: "complete", startedAt: Self.t0 + 2, endedAt: Self.t0 + 60_000)])
        let (summary, rows) = SubagentPresentation.tray(tray)
        #expect(summary.title == "3 subagents")
        #expect(summary.cells == [.running, .attention, .done])
        #expect(summary.tally == [.init("1 needs you", state: .attention), .init("1 running", state: .running), .init("1 done")])
        #expect(rows.map(\.state) == [.running, .attention, .done])
    }

    /// A row's figure counts live from its start, and is its duration once finished.
    @Test func aTrayRowsTimesAreDates() {
        let tray = NativeSubagentTray([Self.run("w"), Self.run("t", state: "complete", startedAt: Self.t0 + 1, endedAt: Self.t0 + 4 * 60_000)])
        let rows = SubagentPresentation.tray(tray).rows
        #expect(rows[0].since == Date(timeIntervalSince1970: Self.t0 / 1000) && rows[0].until == nil)
        #expect(rows[1].until == Date(timeIntervalSince1970: (Self.t0 + 4 * 60_000) / 1000))
    }

    /// Four rows, then "Show N more"; open, every row, then "Show fewer".
    @Test(arguments: [(3, false, 3, nil as Int?), (4, false, 4, nil), (8, false, 4, 4), (8, true, 8, 0)])
    func aLongTrayShowsFourRowsThenMore(count: Int, expanded: Bool, rows: Int, hidden: Int?) {
        let runs = (0..<count).map { NWSubagentTrayRun(id: "r\($0)", name: "r\($0)", state: .running, line: .waiting("")) }
        let items = SubagentTrayLayout.items(runs, expanded: expanded)
        #expect(items.filter { if case .run = $0 { true } else { false } }.count == rows)
        let more: Int? = items.last.flatMap { if case .more(let hidden, _) = $0 { hidden } else { nil } }
        #expect(more == hidden)
    }

    @Test func summaryLinesDropInlineMarkdown() {
        var run = Self.run(state: "complete", endedAt: Self.t0 + 60_000)
        run.summary = "Added 6 tests to `NativePresentationTests`; all pass on **macOS**. Then iOS."
        #expect(SubagentPresentation.summaryLine(run) == "Added 6 tests to NativePresentationTests; all pass on macOS.")
        run.summary = "Kept an unpaired ` and 2 * 3."
        #expect(SubagentPresentation.summaryLine(run) == "Kept an unpaired ` and 2 * 3.")
    }

    @Test(arguments: [("Fixed it.", "Fixed it"), ("Fixed it", "Fixed it"), ("Wait...", "Wait..."), ("Done?", "Done?")])
    func aSentenceLeadingALineDropsItsPeriod(sentence: String, line: String) {
        #expect(SubagentPresentation.lineWithoutFinalPeriod(sentence) == line)
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
        run.contextPercent = 1e300
        #expect(SubagentPresentation.goalNote(run) == "step 1 / 1 · 100%", "a child's percent over a tiny window")
        run.contextPercent = -3
        #expect(SubagentPresentation.goalNote(run) == "step 1 / 1 · 0%")
        run.state = "complete"
        #expect(SubagentPresentation.goalNote(run) == nil)
    }

    @Test(arguments: [(AppLayout.inspectorMaxFiles + 1, "1 more file"), (AppLayout.inspectorMaxFiles + 3, "3 more files")])
    func filesPastTheListAreCounted(count: Int, text: String) {
        #expect(SubagentPresentation.moreFiles(count) == text)
    }

    @Test(arguments: [("anthropic/claude-sonnet", "claude-sonnet"), ("gpt-5", "gpt-5"), ("cpa/~anthropic/claude-haiku", "claude-haiku")])
    func modelTagsDropTheProvider(model: String, tag: String) {
        #expect(SubagentPresentation.modelTag(model) == tag)
    }

    // MARK: A finished run's position

    private static func message(_ id: String, _ role: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: id)])
    }

    /// The task, three replies, a steer, two replies: turns "task", "one", "steer", "two" by
    /// their first messages.
    private static let transcript = nativeTurns([
        message("task", "user"),
        message("one", "assistant"), message("one.t", "toolResult"), message("one.b", "assistant"),
        message("one.bt", "toolResult"), message("one.c", "assistant"),
        message("steer", "user"),
        message("two", "assistant"), message("two.t", "toolResult"), message("two.b", "assistant"),
    ])

    private static func id(_ first: String) -> String? {
        transcript.first { $0.messages.first?.entryID == first }?.id
    }

    @Test(arguments: [
        ("task", nil as Int?, "turn 1 of 5"),
        ("one", nil, "turn 1 of 5"),
        ("steer", nil, "turn 4 of 5"),
        ("two", 11, "turn 4 of 11"),
    ])
    func aFinishedRunSaysWhichTurnIsOnScreen(top: String, total: Int?, expected: String) throws {
        #expect(Self.transcript.count == 4)
        let top = try #require(Self.id(top))
        #expect(SubagentPresentation.position(turns: Self.transcript, top: top, total: total) == expected)
    }

    @Test func noTurnOnScreenOrNoRepliesHasNoPosition() {
        #expect(SubagentPresentation.position(turns: Self.transcript, top: nil, total: 5) == nil)
        #expect(SubagentPresentation.position(turns: Self.transcript, top: "gone", total: 5) == nil)
        let task = nativeTurns([Self.message("task", "user")])
        #expect(SubagentPresentation.position(turns: task, top: task.first?.id, total: nil) == nil)
    }
}
