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
        #expect(row.name == "worker" && row.added == 31 && row.removed == 4)
        #expect(row.since == 1_000 && row.until == nil)
        var done = Self.run("t", state: "complete", startedAt: 1_000, endedAt: 241_000)
        done.summary = "Added 6 presentation tests · 14 pass."
        done.result = ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 1)
        let finished = nativeTrayRow(done)
        #expect(finished.line == .result("Added 6 presentation tests · 14 pass"))
        #expect(finished.added == 96 && finished.removed == 3 && finished.since == 1_000 && finished.until == 241_000)
        #expect(nativeTrayRow(Self.run("x")).added == nil, "no diff, no stat")
    }

    /// A run waiting on you shows its question after "asks:", timed from when it asked.
    @Test func aRunThatNeedsYouAsks() {
        var run = Self.run("r", role: "reviewer", needsAttention: true)
        run.question = ChildQuestion(text: "Two token names collide with existing `Tokens.textSecondary`. Rename the new token names, or replace the old ones everywhere?")
        run.lastActivity = ChildActivity(tool: "shepherd_parent_message", at: 5_000)
        let row = nativeTrayRow(run)
        #expect(row.line == .asks("Rename the new token names, or replace the old ones everywhere?"))
        #expect(row.since == 5_000)
        #expect(row.accessibilityLabel == "reviewer, Needs you, asks: Rename the new token names, or replace the old ones everywhere?")
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

    // MARK: Order and header

    /// Up to four runs keep spawn order; past that, needs you, then live, failed, done.
    @Test func aLongTraySortsTheRunsToActOnFirst() {
        let three = [Self.run("tests", state: "complete", startedAt: 3, endedAt: 4), Self.run("worker", startedAt: 1),
                     Self.run("reviewer", startedAt: 2, needsAttention: true)]
        #expect(nativeTrayOrder(three).map(\.runID) == ["worker", "reviewer", "tests"])
        let eight = [Self.run("d1", state: "complete", startedAt: 1, endedAt: 2), Self.run("w1", startedAt: 2),
                     Self.run("f1", state: "failed", startedAt: 3, endedAt: 4), Self.run("w2", startedAt: 4),
                     Self.run("r1", startedAt: 5, needsAttention: true), Self.run("d2", state: "complete", startedAt: 6, endedAt: 7),
                     Self.run("w3", startedAt: 7), Self.run("d3", state: "complete", startedAt: 8, endedAt: 9)]
        #expect(nativeTrayOrder(eight).map(\.runID) == ["r1", "w1", "w2", "w3", "f1", "d1", "d2", "d3"])
    }

    @Test func theHeaderCountsEachStateAndSaysAllDoneAtTheEnd() {
        let live = NativeSubagentTray([Self.run("w", startedAt: 1), Self.run("r", startedAt: 2, needsAttention: true),
                                       Self.run("t", state: "complete", startedAt: 3, endedAt: 4)])
        #expect(live.title == "3 subagents")
        #expect(live.cells == [.running, .needsYou, .done])
        #expect(live.tally == [NativeTrayTally(text: "1 needs you", phase: .needsYou), NativeTrayTally(text: "1 running", phase: .running),
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
        #expect(nativeTrayRuns(group, placements: placements, turnOrder: ["u1", "t1"], lastUserMessageAt: 150)?.count == 2,
                "a message sent while one still ran does not fold it")
        #expect(nativeTrayRuns(group, placements: placements, turnOrder: ["u1", "t1", "u2"], lastUserMessageAt: 300) == nil)
        let live = [Self.run("a", startedAt: 1)]
        #expect(nativeTrayRuns(live, placements: ["t1": NativeSubagentPlacement(trailing: live)], turnOrder: ["u1", "t1", "u2"],
                               lastUserMessageAt: 300)?.count == 1, "a live run always shows")
        #expect(nativeTrayRuns([], placements: [:], turnOrder: [], lastUserMessageAt: nil) == nil)
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
        #expect(record.started == NativeSubagentRecordLine(title: "Started 3 subagents", meta: "worker · reviewer · tests"))
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

    // MARK: Answering

    @Test func aQuestionAnsweredFromTheTrayOffersItsAnswersANoteAndItsOwnWordsElseAReply() throws {
        var run = Self.run("r", role: "reviewer", needsAttention: true)
        run.question = ChildQuestion(text: "Rename or replace?", options: ["Replace everywhere", "Rename new ones"])
        let prompt = try #require(nativeSubagentQuestionPrompt(run))
        #expect(prompt.asker == .subagent("reviewer") && prompt.question == "Rename or replace?")
        #expect(prompt.options.map(\.title) == ["Replace everywhere", "Rename new ones"])
        #expect(prompt.takesNote && prompt.otherNumber == 3 && prompt.showsAnswer)
        run.question = ChildQuestion(text: "Which base?")
        let reply = try #require(nativeSubagentQuestionPrompt(run))
        #expect(reply.kind == .open && reply.placeholder == "Reply to reviewer…")
        run.question = nil
        run.attentionText = nil
        #expect(try #require(nativeSubagentQuestionPrompt(run)).question == "Waiting on your answer")
        #expect(nativeSubagentQuestionPrompt(Self.run("w")) == nil)
    }
}
