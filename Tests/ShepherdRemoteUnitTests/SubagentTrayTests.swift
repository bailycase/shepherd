import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdRemote

/// The subagent tray's rules (SubagentTray, Subagents, SubagentsDone, SubagentsQueue boards):
/// its rows, its order, its header, when it shows, and the thread's record of its runs.
@Suite("Subagent tray")
struct SubagentTrayTests {
    static func run(_ id: String, state: String = "running", role: String? = nil, startedAt: Double = 0, endedAt: Double? = nil,
                    needsAttention: Bool = false, paused: Bool? = nil) -> ChildRun {
        ChildRun(runID: id, label: role.map { "\($0): task" } ?? id, state: state, startedAt: startedAt, endedAt: endedAt,
                 needsAttention: needsAttention, role: role, paused: paused)
    }

    // MARK: Rows

    /// A running row says what it is doing now: the call in flight in the present tense (it
    /// shimmers), a finished one in the past, a path shortened to its file name.
    @Test(arguments: [
        (ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/ShepherdRemote/NativeThreadPresentation.swift", at: 1),
         "Editing", "NativeThreadPresentation.swift", true),
        (ChildActivity(tool: "edit", preview: "Sources/A/B.swift", at: 1), "Edited", "B.swift", false),
        (ChildActivity(kind: ChildActivity.runningKind, tool: "bash", preview: "cd app && swift test --filter X", at: 1),
         "Running tests", "swift test", true),
        (ChildActivity(kind: ChildActivity.runningKind, tool: "bash", preview: "swift build", at: 1), "Building", "swift build", true),
        (ChildActivity(kind: ChildActivity.runningKind, tool: "read", preview: "README.md", at: 1), "Reading", "README.md", true),
        (ChildActivity(kind: ChildActivity.runningKind, tool: "grep", preview: "\"token\" in Sources", at: 1), "Searching", "\"token\" in Sources", true),
        (ChildActivity(kind: ChildActivity.runningKind, tool: "web_fetch", at: 1), "Running", "web_fetch", true),
    ] as [(ChildActivity, String, String?, Bool)])
    func aRunningRowSaysWhatItIsDoingNow(activity: ChildActivity, verb: String, subject: String?, live: Bool) {
        var run = Self.run("w", role: "worker")
        run.lastActivity = activity
        #expect(nativeTrayRow(run).line == .working(verb: verb, subject: subject, live: live))
    }

    @Test func aRunWithNoCallYetIsStarting() {
        #expect(nativeTrayRow(Self.run("w")).line == .working(verb: "Starting", subject: nil, live: true))
        var reporting = Self.run("w")
        reporting.currentTool = "bash"
        #expect(nativeTrayRow(reporting).line == .working(verb: "Running a command", subject: nil, live: true))
    }

    /// Its diff so far and its time: live from its start, or its duration once finished.
    @Test func aRowCarriesItsDiffAndItsTime() {
        var live = Self.run("w", role: "worker", startedAt: 1_000)
        live.files = [ChildFileChange(path: "A.swift", added: 20, removed: 3), ChildFileChange(path: "B.swift", added: 11, removed: 1)]
        let row = nativeTrayRow(live)
        #expect(row.name == "task" && row.role == "worker" && row.added == 31 && row.removed == 4)
        #expect(row.since == 1_000 && row.until == nil)
        var done = Self.run("t", state: "complete", startedAt: 1_000, endedAt: 241_000)
        done.summary = "Added 6 presentation tests · 14 pass."
        done.result = ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 1)
        let finished = nativeTrayRow(done)
        #expect(finished.line == .result("Added 6 presentation tests · 14 pass"))
        #expect(finished.added == 96 && finished.removed == 3 && finished.since == 1_000 && finished.until == 241_000)
        #expect(nativeTrayRow(Self.run("x")).added == nil, "no diff, no stat")
    }

    /// A run that asked its parent says so quietly, timed from when it asked: the user is never asked.
    @Test func aRunThatAskedItsParentSaysSo() {
        var run = Self.run("r", role: "reviewer", needsAttention: true)
        run.question = ChildQuestion(text: "Two token names collide with existing `Tokens.textSecondary`. Rename the new token names, or replace the old ones everywhere?")
        run.lastActivity = ChildActivity(tool: "shepherd_parent_message", at: 5_000)
        let row = nativeTrayRow(run)
        #expect(row.phase == .asked)
        #expect(row.line == .asked("Rename the new token names, or replace the old ones everywhere?"))
        #expect(row.since == 5_000)
        #expect(row.accessibilityLabel == "task, reviewer, Waiting on parent, asked the parent: Rename the new token names, or replace the old ones everywhere?")
        run.question = nil
        run.attentionText = nil
        #expect(nativeTrayRow(run).line == .asked(""), "a question with no words still says the run asked")
        #expect(nativeTrayRow(run).accessibilityLabel == "task, reviewer, Waiting on parent, asked the parent")
    }

    @Test(arguments: [("exit 1 · context limit reached after 41 turns", "context limit reached after 41 turns"),
                      ("killed by the user", "killed by the user"), ("exit code · weird", "exit code · weird")])
    func aFailedRowSaysWhyWithoutItsExitCode(reason: String, line: String) {
        var run = Self.run("f", state: "failed", endedAt: 10)
        run.exitReason = reason
        #expect(nativeTrayRow(run).line == .failed(line))
    }

    @Test func waitingRowsSayWhy() {
        #expect(nativeTrayRow(Self.run("q", state: "queued")).line == .waiting("Waiting to start"))
        #expect(nativeTrayRow(Self.run("p", paused: true)).line == .waiting("Paused before its next model request"))
    }

    @Test func identicalTaskLabelsKeepEachResultAndQuestionBoundToItsRun() throws {
        var first = Self.run("first", state: "complete", role: "worker", endedAt: 10)
        first.summary = "Fixed the Mac client."
        var second = Self.run("second", state: "complete", role: "worker", startedAt: 1, endedAt: 20)
        second.summary = "Fixed the phone client."
        let tray = NativeSubagentTray([second, first])
        #expect(tray.rows.map(\.name) == ["task", "task"])
        #expect(tray.rows.map(\.id) == ["first", "second"])
        #expect(tray.rows.map(\.runID) == ["first", "second"])
        #expect(tray.rows.map(\.line) == [.result("Fixed the Mac client"), .result("Fixed the phone client")])
        #expect([first, second].map(nativeRunSummary).map(\.result) == ["Fixed the Mac client.", "Fixed the phone client."])
        second.needsAttention = true
        second.question = ChildQuestion(text: "Ship it?")
        let asking = NativeSubagentTray([second, first]).rows
        #expect(asking.map(\.line) == [.result("Fixed the Mac client"), .asked("Ship it?")])
        #expect(nativeRunSummary(second).question == "Ship it?" && nativeRunSummary(first).question == nil)
    }

    @Test func workflowRowsKeepTheirLaneIdentityWhenTheRunIDIsShared() {
        var first = Self.run("workflow", role: "worker")
        first.childIndex = 0
        first.label = "frontend"
        var second = first
        second.childIndex = 1
        second.label = "backend"
        let rows = NativeSubagentTray([second, first]).rows
        #expect(rows.map(\.id) == ["workflow#0", "workflow#1"])
        #expect(rows.map(\.runID) == ["workflow", "workflow"])
        #expect(rows.map(\.name) == ["frontend", "backend"])
    }

    // MARK: Order and header

    /// Up to four runs keep spawn order; past that, live runs (one waiting on its parent among them), failed, done.
    @Test func aLongTraySortsTheRunsStillGoingFirst() {
        let three = [Self.run("tests", state: "complete", startedAt: 3, endedAt: 4), Self.run("worker", startedAt: 1),
                     Self.run("reviewer", startedAt: 2, needsAttention: true)]
        #expect(nativeTrayOrder(three).map(\.runID) == ["worker", "reviewer", "tests"])
        let eight = [Self.run("d1", state: "complete", startedAt: 1, endedAt: 2), Self.run("w1", startedAt: 2),
                     Self.run("f1", state: "failed", startedAt: 3, endedAt: 4), Self.run("w2", startedAt: 4),
                     Self.run("r1", startedAt: 5, needsAttention: true), Self.run("d2", state: "complete", startedAt: 6, endedAt: 7),
                     Self.run("w3", startedAt: 7), Self.run("d3", state: "complete", startedAt: 8, endedAt: 9)]
        #expect(nativeTrayOrder(eight).map(\.runID) == ["w1", "w2", "r1", "w3", "f1", "d1", "d2", "d3"],
                "a question for the parent is nothing to act on, so it takes no lead")
    }

    @Test func theHeaderCountsEachStateAndSaysAllDoneAtTheEnd() {
        let live = NativeSubagentTray([Self.run("w", startedAt: 1), Self.run("r", startedAt: 2, needsAttention: true),
                                       Self.run("t", state: "complete", startedAt: 3, endedAt: 4)])
        #expect(live.title == "3 subagents")
        #expect(live.cells == [.running, .asked, .done])
        #expect(live.tally == [NativeTrayTally(text: "1 running", phase: .running), NativeTrayTally(text: "1 waiting on parent", phase: nil),
                               NativeTrayTally(text: "1 done", phase: nil)])
        #expect(!live.allDone)
        let done = NativeSubagentTray([Self.run("a", state: "complete", endedAt: 1), Self.run("b", state: "complete", endedAt: 2)])
        #expect(done.tally == [NativeTrayTally(text: "all done", phase: nil)] && done.allDone)
        let failed = nativeTrayTally([.done, .failed, .done])
        #expect(failed.map(\.text) == ["2 done", "1 failed"])
    }

    @Test func aWorkflowOfManyRunsShowsItsFirstCells() {
        let tray = NativeSubagentTray((0..<200).map { Self.run("lane\($0)", startedAt: Double($0)) })
        #expect(tray.cells.count == NativeSubagentTray.maxCells)
        #expect(tray.tally.map(\.text) == ["200 running"])
    }

    // MARK: When it shows

    private static func turns(_ ids: [String]) -> [String] { ids }

    /// The newest spawn group shows while any run is live, and once all finished until your
    /// next message.
    @Test func theTrayStaysUntilYourNextMessage() {
        let group = [Self.run("a", state: "complete", startedAt: 1, endedAt: 100), Self.run("b", state: "complete", startedAt: 2, endedAt: 200)]
        let placements = ["t1": NativeSubagentPlacement(trailing: group)]
        #expect(nativeTrayRuns(group, placements: placements, turnOrder: ["u1", "t1"], lastUserMessageAt: 0)?.count == 2)
        #expect(nativeTrayRuns(group, placements: placements, turnOrder: ["u1", "t1"], lastUserMessageAt: 150) == nil,
                "finishing after a new message does not move an old run into its turn")
        #expect(nativeTrayRuns(group, placements: placements, turnOrder: ["u1", "t1", "u2"], lastUserMessageAt: 300) == nil)
        let live = [Self.run("a", startedAt: 1)]
        #expect(nativeTrayRuns(live, placements: ["t1": NativeSubagentPlacement(trailing: live)], turnOrder: ["u1", "t1", "u2"],
                               lastUserMessageAt: 300)?.count == 1, "a live run always shows")
        #expect(nativeTrayRuns([], placements: [:], turnOrder: [], lastUserMessageAt: nil) == nil)
    }

    @Test func historyPagingNeverPromotesOldRunsIntoTheTray() {
        let old = Self.run("old", state: "complete", startedAt: 1, endedAt: 500)
        let current = Self.run("current", state: "complete", startedAt: 210, endedAt: 300)
        let live = Self.run("continuing", startedAt: 2)
        let runs = [old, current, live]
        #expect(nativeTrayRuns(runs, placements: [:], turnOrder: [], lastUserMessageAt: 200)?.map(\.runID)
                == ["continuing", "current"])
        #expect(nativeTrayRuns([old], placements: [:], turnOrder: [], lastUserMessageAt: nil) == nil)
        #expect(nativeTrayRuns(runs, placements: [:], turnOrder: [], lastUserMessageAt: 600)?.map(\.runID)
                == ["continuing"])
    }

    // MARK: The thread's record

    @Test func theRecordNamesTheRunsThenSumsThemOnceFinished() throws {
        var worker = Self.run("w", state: "complete", role: "worker", startedAt: 0, endedAt: 41 * 60_000)
        worker.result = ChildResultSummary(files: 5, added: 190, removed: 58, tools: 1, tokens: 1)
        var reviewer = Self.run("r", state: "complete", role: "reviewer", startedAt: 1, endedAt: 12 * 60_000)
        reviewer.result = ChildResultSummary(files: 0, added: 32, removed: 3, tools: 1, tokens: 1)
        var tests = Self.run("t", state: "complete", role: "tests", startedAt: 41 * 60_000, endedAt: 45 * 60_000)
        tests.result = ChildResultSummary(files: 2, added: 96, removed: 3, tools: 1, tokens: 1)
        let record = try #require(NativeSubagentRecord([tests, reviewer, worker]))
        #expect(record.started == NativeSubagentRecordLine(title: "Started 3 subagents", meta: "task · task · task"))
        #expect(record.finished == NativeSubagentRecordLine(title: "3 subagents finished", meta: "45m · 7 files · +318 −64"))
        #expect(record.firstRunID == "w")
        #expect(record.finishedAt == 45 * 60_000.0)
    }

    @Test func aRecordCountsFailuresAndNamesAtMostSixRuns() throws {
        let runs = (0..<8).map { Self.run("lane\($0)", state: $0 == 0 ? "failed" : "complete", startedAt: Double($0), endedAt: 60_000) }
        let record = try #require(NativeSubagentRecord(runs))
        #expect(record.started.meta == "lane0 · lane1 · lane2 · lane3 · lane4 · lane5 · +2 more")
        #expect(record.finished?.meta == "1m · 1 failed")
        #expect(NativeSubagentRecord([]) == nil)
        #expect(try #require(NativeSubagentRecord([Self.run("a")])).finished == nil, "still running")
    }
}
