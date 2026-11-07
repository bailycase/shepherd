import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The side pane's Subagents tab (SubagentList board) as values: the summary and its tally, the two
/// sections and their clocks, each row's words from the tray's producer, and the tab's count and dot.
@Suite("Subagent list")
struct SubagentListTests {
    private static let utc = TimeZone(identifier: "UTC")!
    /// 14:41:00 UTC on 2023-11-14, in milliseconds.
    private static let turn: Double = 1_699_972_860_000
    private static let earlier: Double = 1_699_970_280_000

    private static let worker = ChildRun(
        runID: "worker", label: "worker: restyle", state: "running", startedAt: turn, needsAttention: false, role: "worker",
        lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/NativeThreadPresentation.swift", at: turn + 1000),
        task: "Restyle the desktop native thread view to match the spec",
        files: [ChildFileChange(path: "a", added: 31, removed: 4)])
    private static let reviewer = ChildRun(
        runID: "reviewer", label: "reviewer: check", state: "running", startedAt: turn + 60_000, needsAttention: true, role: "reviewer",
        lastActivity: ChildActivity(tool: "shepherd_parent_message", at: turn + 120_000),
        question: ChildQuestion(text: "Rename the new token names, or replace the old ones everywhere?", options: []), task: "check")
    private static let tests = ChildRun(
        runID: "tests", label: "tests: run", state: "complete", startedAt: turn + 120_000, endedAt: turn + 360_000, role: "tests",
        result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 4, tokens: 5), task: "run",
        output: "Added 6 presentation tests · 14 pass.")
    private static let scout = ChildRun(
        runID: "scout", label: "scout: find", state: "complete", startedAt: earlier, endedAt: earlier + 360_000, role: "scout",
        task: "Find every place the thread view sets a font", output: "41 call sites in 9 files.")
    private static let researcher = ChildRun(
        runID: "researcher", label: "researcher: read", state: "stopped", startedAt: earlier + 60_000, endedAt: earlier + 1_260_000, role: "researcher",
        task: "Read the SwiftUI preview docs")

    private static var runs: [ChildRun] { [worker, reviewer, tests, scout, researcher] }

    /// The latest turn that spawned any run holds the first three; the thread's turn ids, newest last.
    private static func list(_ runs: [ChildRun] = runs) -> SubagentListPresentation {
        let placed = NativeSubagentPlacement(trailing: [worker, reviewer, tests])
        return SubagentListPresentation(runs: runs, placements: ["turn-2": placed], turnOrder: ["turn-1", "turn-2"], timeZone: utc)
    }

    @Test func theSummaryCountsEveryRunAndTalliesLiveFirstThenHowTheRestEnded() {
        let list = Self.list()
        #expect(list.title == "5 subagents")
        #expect(list.tally.map(\.text) == ["1 running", "1 waiting on parent", "2 done", "1 stopped"])
        #expect(list.count == 5)
    }

    @Test func aStoppedRunSaysStoppedAndAFailedOneFailed() {
        var failed = Self.researcher
        failed.state = "failed"
        let parts = SubagentListPresentation.tally([Self.researcher, failed, Self.tests]).map(\.text)
        #expect(parts == ["1 done", "1 failed", "1 stopped"])
    }

    @Test func bothSectionsReadInSpawnOrderAndThisTurnHoldsTheLatestSpawns() throws {
        let list = Self.list()
        #expect(list.sections.map(\.title) == ["This turn", "Earlier in this thread"])
        #expect(list.sections[0].items.map(\.run.runID) == ["worker", "reviewer", "tests"])
        // The board's order: spawn order in both sections (the touch client lists earlier runs newest first).
        #expect(list.sections[1].items.map(\.run.runID) == ["scout", "researcher"], "the scout began first")
        #expect(list.sections[0].time == "started 2:41 PM")
        #expect(list.sections[1].time == "1:58 PM", "when the first of them began")
    }

    @Test func aSectionWithNoRunsIsNotDrawn() {
        // No placement names a turn, so nothing is current: the finished runs are all earlier.
        let list = SubagentListPresentation(runs: [Self.scout, Self.researcher], placements: [:], turnOrder: [], timeZone: Self.utc)
        #expect(list.sections.map(\.title) == ["Earlier in this thread"])
        #expect(SubagentListPresentation().isEmpty && SubagentListPresentation().sections.isEmpty)
    }

    @Test func rowsReadAsTheTraysRowsDo() throws {
        let rows = Self.list().sections.flatMap(\.items).map(\.row)
        let worker = try #require(rows.first { $0.id == "worker" })
        #expect(worker.line == .working(verb: "Editing", subject: "NativeThreadPresentation.swift", live: true))
        #expect(worker.role == "worker" && worker.added == 31 && worker.removed == 4)
        let reviewer = try #require(rows.first { $0.id == "reviewer" })
        #expect(reviewer.line == .asked("Rename the new token names, or replace the old ones everywhere?"))
        #expect(reviewer.state == .queued, "a run waiting on its parent is hollow, never the user's attention")
        let tests = try #require(rows.first { $0.id == "tests" })
        #expect(tests.line == .result("Added 6 presentation tests · 14 pass") && tests.state == .done)
        #expect(tests.until != nil, "a finished run shows its duration, not a running clock")
    }

    /// The user's decision: a blue dot is still working, a green one is done.
    @Test func theTabsDotIsBlueWhileAnyRunIsWorkingGreenOnceAllSucceededAndRedIfAnyFailedOrStopped() {
        func status(_ runs: [ChildRun]) -> AgentState? { SidePaneTabs.subagents(runs)?.status }
        #expect(status([]) == nil, "no runs, no tab and no dot")
        #expect(SidePaneTabs.subagents([])?.count == nil)
        #expect(status(Self.runs) == .running, "live and done and stopped together: still working")
        #expect(status([Self.worker, Self.tests]) == .running, "live and done: still working")
        #expect(status([Self.reviewer, Self.tests]) == .running, "a run waiting on its parent is still working")
        var paused = Self.worker
        paused.paused = true
        #expect(status([paused, Self.tests]) == .running, "a paused run is still going")
        var queued = Self.worker
        queued.state = "queued"
        #expect(status([queued]) == .running, "a queued one too")
        #expect(status([Self.tests, Self.scout]) == .done, "every run finished well, none live: done")
        #expect(status([Self.tests, Self.researcher]) == .failed, "a stopped run is never a success")
        var failed = Self.researcher
        failed.state = "failed"
        #expect(status([Self.tests, failed]) == .failed, "nor a failed one")
        #expect(status([Self.worker, failed]) == .running, "work still going outranks a failure; the failure shows once it ends")
        #expect(SidePaneTabs.subagents(Self.runs)?.count == 5, "the count is every run, current and earlier")
    }

    @Test func theDotIsTheStatesOwnAndTheNewsDotStaysTheAgentsAlone() throws {
        for (state, expected) in [(AgentState.running, "running"), (.done, "done"), (.failed, "failed")] {
            let tab = try #require(SidePaneTabs.items(news: [], changedFiles: 5, subagents: (3, state)).last)
            #expect(tab.status == state && !tab.news, "\(expected): a status, not news")
        }
        let none = SidePaneTabs.items(news: [], changedFiles: 5, subagents: nil)
        #expect(none.allSatisfy { $0.status == nil }, "no runs: no dot")
        // News is pi's: Changes and Browser take it as before, and never take a status.
        let news = SidePaneTabs.items(news: [.changes, .browser], changedFiles: 2, subagents: (3, .done))
        #expect(news.map(\.news) == [true, true, false, false] && news.map(\.status) == [nil, nil, nil, .done])
        #expect(SidePaneTabs.items(news: [.subagents], changedFiles: 2, subagents: (3, .done)).last?.news == true,
                "the pane's news still marks any tab it is told to")
    }

    @Test func theTabSitsAfterTheBrowserWithItsGlyphChordAndCount() throws {
        let tabs = SidePaneTabs.items(news: [], changedFiles: 5, subagents: (5, .running))
        #expect(tabs.map(\.title) == ["Changes", "Browser", "Files", "Subagents"])
        let tab = try #require(tabs.last)
        #expect(tab.systemImage == "arrow.triangle.branch" && tab.shortcut == "⌃4" && tab.count == 5)
        #expect(SidePaneTabs.items(news: [], changedFiles: 5, subagents: nil).map(\.title) == ["Changes", "Browser", "Files"])
        let noBrowser = SidePaneTabs.items(news: [], changedFiles: 5, browser: false, subagents: (1, .done))
        #expect(noBrowser.map(\.title) == ["Changes", "Files", "Subagents"], "a host with no tunnels has no Browser")
        #expect(noBrowser.last?.shortcut == "⌃4", "and Subagents keeps ⌃4, after Artifacts (PaneStates: Artifacts is ⌃3)")
    }
}
