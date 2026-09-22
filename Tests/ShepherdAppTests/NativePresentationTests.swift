import AppKit
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
@testable import ShepherdApp
@testable import TerminalSurfaceKit

@Suite("Desktop native presentation", .serialized)
@MainActor
struct NativePresentationTests {
    private func message(_ fields: [String: Any]) -> NativeThreadMessage {
        var json = fields
        json["entryID"] = json["entryID"] ?? UUID().uuidString
        json["truncated"] = false
        return try! JSONDecoder().decode(NativeThreadMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func tool(_ name: String, args: String?, output: String, error: Bool = false, status: String = "complete") -> NativeThreadMessage {
        var fields: [String: Any] = ["role": "toolResult", "toolName": name, "status": status, "isError": error,
                                     "blocks": output.isEmpty ? [] : [["kind": "text", "text": output]]]
        if let args { fields["argumentsText"] = args }
        return message(fields)
    }

    @Test func touchedPathsAreTheCurrentTurnsEditsWhileRunning() {
        let earlier = tool("edit", args: #"{"path":"old.swift"}"#, output: "")
        let user = message(["role": "user", "blocks": [["kind": "text", "text": "go"]]])
        let edit = tool("edit", args: #"{"path":"/repo/a.swift"}"#, output: "", status: "running")
        let write = tool("write", args: #"{"path":"b.swift","content":"x"}"#, output: "")
        let read = tool("read", args: #"{"path":"c.swift"}"#, output: "x")
        let messages = [earlier, user, edit, write, read]
        #expect(nativeTouchedPaths(messages, running: true) == ["/repo/a.swift", "b.swift"])
        #expect(nativeTouchedPaths(messages, running: false).isEmpty)
    }

    @Test func toolRowsPreviewPerToolKind() {
        let read = NativeToolRow(tool("read", args: #"{"path":"Sources/A.swift","offset":237,"limit":160}"#, output: Array(repeating: "x", count: 160).joined(separator: "\n")))
        #expect(read.preview == "Sources/A.swift" && read.previewSuffix == ":237–396")
        #expect(read.results.map(\.text) == ["160 lines"] && read.state == .done && read.expandable)
        #expect(read.accessibilityLabel == "read, Sources/A.swift:237–396, 160 lines, done")

        let edit = NativeToolRow(tool("edit", args: #"{"path":"App/iOS/ThreadView.swift","edits":[{"oldText":"a\nb\nc","newText":"a\nB"}]}"#, output: "Successfully replaced 1 block(s)"))
        #expect(edit.preview == "App/iOS/ThreadView.swift" && edit.diff == NativeDiffStat(added: 1, removed: 2, blocks: 1))
        #expect(edit.results.map(\.text) == ["1 block"])

        let bash = NativeToolRow(tool("bash", args: #"{"command":"xcodebuild -scheme X build\necho done"}"#, output: "lots\n** BUILD SUCCEEDED **"))
        #expect(bash.preview == "xcodebuild -scheme X build" && bash.results.first == .init("BUILD SUCCEEDED", tone: .success))
        let tests = NativeToolRow(tool("bash", args: #"{"command":"swift test"}"#, output: "◆ Test run with 1 test in 1 suite passed after 0.001 seconds.\n1 test passed"))
        #expect(tests.results.first == .init("1 passed", tone: .success))
        let failed = NativeToolRow(tool("bash", args: #"{"command":"swift test"}"#, output: "error: cannot find X\n\nCommand exited with code 1", error: true))
        #expect(failed.state == .failed && failed.results.first == .init("exit 1", tone: .danger))
        let running = NativeToolRow(tool("bash", args: #"{"command":"sleep 5"}"#, output: "", status: "running"))
        #expect(running.state == .running && running.results.isEmpty && !running.expandable)
        let unknown = NativeToolRow(tool("bash", args: #"{"command":"ls"}"#, output: "a\nb"))
        #expect(unknown.results.isEmpty)

        let grep = NativeToolRow(tool("grep", args: #"{"pattern":"speakerLabel","path":"Sources/"}"#, output: "a.swift:1: x\nb.swift:2: y\nc.swift:3: z"))
        #expect(grep.preview == "\"speakerLabel\"" && grep.previewSuffix == " in Sources/" && grep.results.map(\.text) == ["3 matches"])
        #expect(NativeToolRow(tool("grep", args: #"{"pattern":"zzz"}"#, output: "No matches found")).results.map(\.text) == ["0 matches"])

        let other = NativeToolRow(tool("web_fetch", args: #"{"url":"https://example.com"}"#, output: "<html>"))
        #expect(other.preview == "https://example.com")
        let saved = NativeToolRow(tool("custom", args: nil, output: "\n\nfirst useful line\nsecond"))
        #expect(saved.preview == "first useful line")
        // Spec §5: previews cap at 120 characters.
        let long = NativeToolRow(tool("custom", args: nil, output: String(repeating: "y", count: 300)))
        #expect(long.preview.count == 120)
    }

    @Test func diffStatCountsMovedLinesAsUnchanged() {
        #expect(NativeDiffStat(edits: [("a\nb", "b\na")]) == NativeDiffStat(added: 0, removed: 0, blocks: 1))
        #expect(NativeDiffStat(edits: [("a", "a\nb\nc"), ("x\ny", "")]) == NativeDiffStat(added: 2, removed: 2, blocks: 2))
        #expect(NativeDiffStat(edits: [("one\ntwo\nthree", "one\n2\nthree\nfour")]) == NativeDiffStat(added: 2, removed: 1, blocks: 1))
    }

    @Test func durationFormatting() {
        #expect(nativeDurationText(10.21) == "10.2s")
        #expect(nativeDurationText(0.4) == "0.4s")
        #expect(nativeDurationText(48) == "48s")
        #expect(nativeDurationText(48.9, live: true) == "48s")
        #expect(nativeDurationText(64) == "1m 04s")
        #expect(nativeDurationText(3725) == "1h 02m")
        #expect(nativeDurationText(-3) == "0s")
    }

    @Test func statusMapsToPill() {
        #expect(nativeAgentPill(running: false, awaitingAnswer: false, error: false) == .idle)
        #expect(nativeAgentPill(running: true, awaitingAnswer: false, error: false) == .running)
        #expect(nativeAgentPill(running: true, awaitingAnswer: true, error: false) == .needsApproval)
        #expect(nativeAgentPill(running: true, awaitingAnswer: true, error: true) == .error)
        #expect(nativeAgentPill(running: false, awaitingAnswer: false, error: false, stopped: true) == .stopped)
        // A pending dialog outranks a live run; an error outranks everything; stopped only when nothing else applies.
        #expect(nativeAgentPill(running: false, awaitingAnswer: true, error: false, stopped: true) == .needsApproval)
        #expect(nativeAgentPill(running: true, awaitingAnswer: false, error: false, stopped: true) == .running)
        #expect(nativeAgentPill(running: false, awaitingAnswer: false, error: true, stopped: true) == .error)
        #expect(NativeAgentPill.needsApproval.label == "Needs you")
        #expect([NativeAgentPill.idle, .running, .error, .stopped].map(\.label) == ["Idle", "Running", "Error", "Stopped"])
    }

    @Test func phoneToolGroupSummaryCountsInFirstSeenOrder() {
        let read = tool("read", args: nil, output: ""), edit = tool("edit", args: nil, output: ""), bash = tool("bash", args: nil, output: "")
        #expect(nativeToolGroupSummary([read]) == "1 tool call · read 1")
        #expect(nativeToolGroupSummary([bash, read, bash, edit, edit, edit]) == "6 tool calls · bash 2 · read 1 · edit 3")
        let unnamed = message(["role": "toolResult", "blocks": []])
        #expect(nativeToolGroupSummary([unnamed, unnamed]) == "2 tool calls · result 2")
        #expect(nativeToolGroupSummary([]) == "0 tool calls")
    }

    @Test func headTruncationKeepsTheFilename() {
        let path = "Sources/ShepherdApp/DesktopNativeThreadView.swift"
        #expect(nativeHeadTruncated(path, max: 20) == "…iveThreadView.swift")
        #expect(nativeHeadTruncated(path, max: 20).count == 20)
        #expect(nativeHeadTruncated(path, max: path.count) == path)
        #expect(nativeHeadTruncated(path, max: path.count - 1).hasSuffix("ThreadView.swift"))
        #expect(nativeHeadTruncated("", max: 5) == "")
        // Degenerate widths leave the string alone rather than returning a bare ellipsis.
        #expect(nativeHeadTruncated("abc", max: 1) == "abc")
        #expect(nativeHeadTruncated("abc", max: 0) == "abc")
    }

    @Test func turnItemsCollapseConsecutiveToolsAndProseSplitsThem() {
        let prose = message(["entryID": "p", "role": "assistant", "blocks": [["kind": "thinking", "text": "hmm"], ["kind": "text", "text": "Doing it."]]])
        let a = tool("read", args: nil, output: ""), b = tool("edit", args: nil, output: ""), c = tool("bash", args: nil, output: "")
        let items = nativeTurnItems([prose, a, b, prose, c])
        #expect(items.count == 6)
        #expect(items[0] == .thinking("hmm") && items[1] == .prose("Doing it."))
        #expect(items[2] == .tools([a, b]) && items[5] == .tools([c]))
        #expect(nativeToolGroupSummary([a, b, b, c, c]) == "5 tool calls · read 1 · edit 2 · bash 2")
        #expect(nativeHeadTruncated("Sources/ShepherdApp/DesktopNativeThreadView.swift", max: 33) == "…pp/DesktopNativeThreadView.swift")
        #expect(nativeHeadTruncated("short.swift", max: 30) == "short.swift")
        let user = message(["entryID": "u", "role": "user", "blocks": []])
        #expect(nativeTurns([user, prose, a, user]).map(\.isUser) == [true, false, true])
    }

    // MARK: Subagent cards (docs/design-spec/subagent-card-states.png)

    private static let boardNow = Date(timeIntervalSince1970: 10_000)
    /// The four cards on the board, timed so the durations read as drawn.
    private static var boardRuns: [ChildRun] {
        let now = boardNow.timeIntervalSince1970 * 1000
        return [
            ChildRun(runID: "native-worker", label: "worker: restyle", state: "running", startedAt: now - (37 * 60 + 21) * 1000, needsAttention: false,
                     role: "worker", model: "anthropic/claude-fable-5-1", thinking: "high", context: "background", step: ChildStep(index: 1, total: 1),
                     turns: 78, toolCalls: 82, tokens: 922_000, contextPercent: 62,
                     lastActivity: ChildActivity(tool: "edit", preview: "Sources/ShepherdRemote/NativeThreadPresentation.swift", diff: ChildDiff(added: 31, removed: 0), at: now - 4000),
                     toolCallID: "spawn-worker", task: "Restyle desktop native thread view and iOS app to match the spec in Shepherd chat UI.html; no fake affordances; system fonts at spec sizes.", sessionFile: "/tmp/worker.jsonl"),
            ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: now - (2 * 60 + 10) * 1000, needsAttention: true,
                     attentionText: "Two token names collide", role: "reviewer", model: "anthropic/claude-opus", context: "async", turns: 3, tokens: 40_000,
                     question: ChildQuestion(text: "Two token names collide with existing `Tokens.textSecondary`. Rename the new ones to `text2`, or replace the old ones everywhere?",
                                             options: ["Replace everywhere", "Rename new ones"]), toolCallID: "spawn-reviewer"),
            ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: now - 600_000, endedAt: now - 600_000 + (4 * 60 + 2) * 1000, needsAttention: false,
                     role: "tests", model: "anthropic/claude-sonnet", context: "async", turns: 9, toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118_000), toolCallID: "spawn-tests",
                     output: "Added 6 presentation tests (preview text per tool kind, DiffStat, duration formatting). All 14 pass on macOS and iOS simulators."),
            ChildRun(runID: "native-docs", label: "docs: write", state: "failed", startedAt: now - 900_000, endedAt: now - 100_000, needsAttention: false,
                     role: "docs", turns: 41, exitReason: "exit 1 · context limit reached after 41 turns", toolCallID: "spawn-docs"),
        ]
    }

    @Test func subagentCardStateMapping() {
        let runs = Self.boardRuns
        #expect(runs.map(nativeSubagentState) == [.running, .needsYou, .done, .failed])
        #expect(nativeSubagentState(ChildRun(runID: "q", label: "l", state: "queued")) == .running)
        #expect(nativeSubagentState(ChildRun(runID: "s", label: "l", state: "stopped")) == .failed)
        // Unknown future states stay live, like ChildRun.isTerminal.
        #expect(nativeSubagentState(ChildRun(runID: "x", label: "l", state: "pondering")) == .running)
        #expect(nativeSubagentCounters(runs[0]) == "78 turns · 82 tools · 922k tok")
        #expect(nativeSubagentCounters(ChildRun(runID: "a", label: "l", state: "running", turns: 1, toolCalls: 1, tokens: 1_600_000)) == "1 turn · 1 tool · 1.6m tok")
        #expect(nativeSubagentResultLine(runs[2].result!) == ["2 files", "+96 -3", "19 tools", "118k tok"])
        #expect(nativeSubagentAccessibilityLabel(runs[0], now: Self.boardNow) == "worker, running, 37 minutes")
        #expect(nativeSubagentAccessibilityLabel(runs[1], now: Self.boardNow) == "reviewer, needs you, 2 minutes")
        #expect(nativeSubagentAccessibilityLabel(runs[2], now: Self.boardNow) == "tests, done, 4 minutes")
        #expect(nativeSubagentAccessibilityLabel(runs[3], now: Self.boardNow).hasPrefix("docs, failed"))
    }

    @Test func subagentDurationsAndAges() {
        let runs = Self.boardRuns
        #expect(nativeSubagentElapsed(runs[0], now: Self.boardNow).map(nativeSubagentDurationText) == "37m 21s")
        #expect(nativeSubagentElapsed(runs[1], now: Self.boardNow).map(nativeSubagentDurationText) == "2m 10s")
        // Finished runs freeze at endedAt no matter how late "now" is.
        #expect(nativeSubagentElapsed(runs[2], now: Self.boardNow.addingTimeInterval(9999)).map(nativeSubagentDurationText) == "4m 02s")
        #expect(nativeSubagentElapsed(ChildRun(runID: "n", label: "l", state: "running"), now: Self.boardNow) == nil)
        #expect(nativeSubagentShortDuration(37 * 60 + 21) == "37m")
        #expect(nativeSubagentShortDuration(48) == "48s")
        #expect(nativeSubagentShortDuration(7300) == "2h")
        #expect(nativeAgeText(runs[0].lastActivity!.at, now: Self.boardNow) == "4s ago")
        #expect(nativeAgeText(Self.boardNow.timeIntervalSince1970 * 1000 + 5000, now: Self.boardNow) == "0s ago")
        #expect(nativeCompactTokens(581_000) == "581k" && nativeCompactTokens(1_600_000) == "1.6m" && nativeCompactTokens(2_000_000) == "2m" && nativeCompactTokens(999) == "999")
    }

    @Test func runsStripSummaryAndRollups() {
        let now = Self.boardNow.timeIntervalSince1970 * 1000
        var runs: [ChildRun] = []
        for i in 0..<12 {
            let state = i < 7 ? "complete" : i < 10 ? "running" : i == 10 ? "running" : "failed"
            runs.append(ChildRun(runID: "r\(i)", label: "l", state: state, startedAt: now - 12 * 60_000 + Double(i) * 1000,
                                 endedAt: state == "running" ? nil : now - 60_000, needsAttention: i == 10, tokens: i == 0 ? 581_000 : nil))
        }
        let summary = nativeRunsStripSummary(runs.shuffled(), now: Self.boardNow)
        #expect(summary.count == 12)
        #expect(summary.states == "7 done · 3 running · 1 needs you · 1 failed")
        #expect(summary.totals == "581k tok · 12m")
        // Cells follow spawn order, not the publish order.
        #expect(summary.cells == Array(repeating: .done, count: 7) + Array(repeating: .running, count: 3) + [.needsYou, .failed])
        #expect(nativeRunsStripSummary([], now: Self.boardNow) == NativeRunsStripSummary(count: 0, states: "", totals: "", cells: []))

        let board = Self.boardRuns
        #expect(nativeSubagentRollup(board) == "4 subagents · 1.1m tok")
        #expect(nativeSubagentRollup(Array(board.prefix(3))) == "3 subagents · 1.1m tok")
        #expect(nativeSubagentRollup([]) == nil)
        #expect(nativeSubagentNeedsYouLabel(board) == "1 subagent needs you")
        #expect(nativeSubagentNeedsYouLabel([board[1], board[1]]) == "2 subagents need you")
        #expect(nativeSubagentNeedsYouLabel([board[0]]) == nil)
        #expect(nativeSubagentRunningLabel(Array(board.prefix(3)), now: Self.boardNow) == "1 of 3 subagents running · 37m")
        #expect(nativeSubagentRunningLabel([board[2]], now: Self.boardNow) == nil)
    }

    /// The completed group on the board: worker / reviewer / tests, all done, 45m wall.
    private static var doneRuns: [ChildRun] {
        let t0 = boardNow.timeIntervalSince1970 * 1000 - 45 * 60_000
        return [
            ChildRun(runID: "native-worker", label: "worker: restyle", state: "complete", startedAt: t0, endedAt: t0 + 41 * 60_000, role: "worker",
                     model: "anthropic/claude-fable-5-1", context: "background", turns: 78, toolCalls: 118, tokens: 922_000,
                     result: ChildResultSummary(files: 5, added: 200, removed: 60, tools: 118, tokens: 922_000), toolCallID: "spawn-worker",
                     task: "Restyle desktop native thread view and iOS app to match the spec.",
                     output: "Restyled desktop thread, sidebar, composer and iOS to the spec; system fonts at spec sizes throughout. Nothing else touched.",
                     files: [ChildFileChange(path: "Sources/ShepherdApp/ThreadView.swift", added: 120, removed: 40),
                             ChildFileChange(path: "Sources/ShepherdApp/SidebarView.swift", added: 30, removed: 10),
                             ChildFileChange(path: "Sources/ShepherdApp/DesktopNativeComposer.swift", added: 20, removed: 5),
                             ChildFileChange(path: "App/iOS/ThreadView.swift", added: 25, removed: 5),
                             ChildFileChange(path: "Sources/ShepherdApp/DesignTokens.swift", added: 5, removed: 0)],
                     summary: "Restyled desktop thread, sidebar, composer and iOS to the spec; system fonts at spec sizes throughout. Nothing else touched.",
                     sessionID: "child-worker", cwd: "/tmp"),
            ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "complete", startedAt: t0 + 60_000, endedAt: t0 + 13 * 60_000, role: "reviewer",
                     model: "anthropic/claude-opus", context: "async", turns: 6, toolCalls: 24, tokens: 460_000,
                     result: ChildResultSummary(files: 0, added: 0, removed: 0, tools: 24, tokens: 460_000), toolCallID: "spawn-reviewer",
                     task: "Check each step against the spec.", output: "Two token collisions fixed by renaming; everything else matches the spec.",
                     summary: "Two token collisions fixed by renaming; everything else matches the spec.", sessionID: "child-reviewer", cwd: "/tmp"),
            ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: t0 + 41 * 60_000, endedAt: t0 + 45 * 60_000 + 2000, role: "tests",
                     model: "anthropic/claude-sonnet", context: "async", turns: 11, toolCalls: 19, tokens: 118_000,
                     result: ChildResultSummary(files: 2, added: 118, removed: 4, tools: 19, tokens: 118_000), toolCallID: "spawn-tests",
                     task: "Add presentation tests for the restyle and run the suites on macOS and iOS.",
                     output: "Added 6 presentation tests (preview text per tool kind, DiffStat, duration formatting). All 14 pass on macOS and iOS simulators.",
                     sessionFile: "/tmp/tests.jsonl",
                     files: [ChildFileChange(path: "Tests/ShepherdAppTests/NativePresentationTests.swift", added: 96, removed: 3),
                             ChildFileChange(path: "Tests/ShepherdIOSChecks/ThreadStoreCheck.swift", added: 22, removed: 1)],
                     summary: "Added 6 presentation tests (preview text per tool kind, DiffStat, duration formatting). All 14 pass on macOS and iOS simulators.",
                     sessionID: "child-tests", cwd: "/tmp"),
        ]
    }

    @Test func ledgerSummarizesACompletedGroup() {
        let runs = Self.doneRuns
        #expect(nativeSubagentGroupIsTerminal(runs))
        #expect(!nativeSubagentGroupIsTerminal(Self.boardRuns))
        #expect(!nativeSubagentGroupIsTerminal([]))
        var asking = runs[0]; asking.needsAttention = true
        #expect(!nativeSubagentGroupIsTerminal([asking]))

        let ledger = nativeSubagentLedger(runs.shuffled())
        #expect(ledger.title == "3 subagents")
        #expect(ledger.status == "all done · 45m wall · 1.5m tok")
        #expect(ledger.added == 318 && ledger.removed == 64 && ledger.files == 7 && ledger.diffText == "7 files")
        // Rows follow spawn order; the summary is the first sentence, tail-truncated.
        #expect(ledger.rows.map { $0.run.role } == ["worker", "reviewer", "tests"])
        #expect(ledger.rows[0].summary == "Restyled desktop thread, sidebar, composer and iOS to the spec; system…")
        #expect(ledger.rows[2].summary == "Added 6 presentation tests (preview text per tool kind, DiffStat, durat…")
        #expect(ledger.rows[1].summary == "Two token collisions fixed by renaming; everything else matches the spe…")
        #expect(ledger.rows.allSatisfy { $0.summary.count <= NativeSubagentLedger.summaryLimit })
        #expect(ledger.rows.map(\.meta) == ["5 files · 118 tools · 41m", "24 tools · 12m", "2 files · 19 tools · 4m"])
        #expect(ledger.rows.map(\.state) == [.done, .done, .done])

        // A failed sibling changes the header and the row's summary is its exit reason.
        var failed = runs[2]; failed.state = "failed"; failed.exitReason = "exit 1 · context limit reached"; failed.result = nil; failed.files = nil
        let mixed = nativeSubagentLedger([runs[0], runs[1], failed])
        #expect(mixed.status == "2 done · 1 failed · 45m wall · 1.5m tok")
        #expect(mixed.rows[2].state == .failed && mixed.rows[2].summary == "exit 1 · context limit reached")
        #expect(mixed.added == 200 && mixed.files == 5)
        // Nothing touched: no diff slot; no timing: no wall.
        let bare = nativeSubagentLedger([ChildRun(runID: "x", label: "docs", state: "complete")])
        #expect(bare.status == "all done" && bare.diffText == nil && bare.rows[0].meta == "" && bare.rows[0].summary == "")
    }

    @Test func firstSentenceAndTurnTimes() {
        #expect(nativeFirstSentence("One. Two.") == "One.")
        #expect(nativeFirstSentence("v1.2 shipped today. Next.") == "v1.2 shipped today.")
        #expect(nativeFirstSentence("no  end\nhere") == "no end here")
        #expect(nativeFirstSentence(String(repeating: "a", count: 100), limit: 10) == "aaaaaaaaa…")
        #expect(nativeFirstSentence("") == "")
        let utc = TimeZone(identifier: "UTC")!
        #expect(nativeClockText(1_758_539_340_000, timeZone: utc) == "11:09 AM")
        #expect(nativeClockText(1_758_539_340_000, meridiem: false, timeZone: utc) == "11:09")
        #expect(nativeTurnTimeText(startedAt: nil, endedAt: 5) == nil)
        let start = Date().timeIntervalSince1970 * 1000
        let text = try? #require(nativeTurnTimeText(startedAt: start, endedAt: start + (45 * 60 + 12) * 1000))
        #expect(text?.hasSuffix(" · 45m 12s") == true)
        #expect(nativeTurnTimeText(startedAt: start, endedAt: nil) == nativeClockText(start))
        // A sub-second turn shows only its clock time, not "0s".
        #expect(nativeTurnTimeText(startedAt: start, endedAt: start + 400) == nativeClockText(start))
    }

    /// Real sessions carry pi system entries, blank assistant messages, and repeated provider
    /// failures; none of them should become prose.
    @Test func realSessionNoiseIsDroppedOrFolded() {
        let user = message(["entryID": "u", "role": "user", "blocks": [["kind": "text", "text": "go"]]])
        let system = message(["entryID": "s", "role": "system", "blocks": [["kind": "text", "text": ""]]])
        let blank = message(["entryID": "b", "role": "assistant", "blocks": []])
        let failed = { (id: String) in message(["entryID": id, "role": "assistant", "status": "error", "blocks": [["kind": "text", "text": "503 no available server"]]]) }
        let reply = message(["entryID": "r", "role": "assistant", "blocks": [["kind": "text", "text": "Done."]]])
        let turns = nativeTurns([system, user, blank, failed("e1"), failed("e2"), reply])
        #expect(turns.map(\.isUser) == [true, false])
        #expect(nativeTurnItems(turns[1].messages) == [.error("503 no available server", count: 2), .prose("Done.")])
        // An empty user message still opens a turn.
        #expect(nativeTurns([message(["entryID": "u0", "role": "user", "blocks": []]), reply]).count == 2)
    }

    @Test func subagentToolPreviewNamesTheAgentNotTheLaunchBoilerplate() {
        let boiler = "Run fan-out: 0/32 used, 32 remaining\nAsync workflow [x]"
        #expect(NativeToolRow(tool("subagent", args: #"{"agent":"delegate","task":"Say hello\nmore"}"#, output: boiler)).preview == "delegate · Say hello")
        #expect(NativeToolRow(tool("subagent", args: #"{"workflowScript":"return 1"}"#, output: boiler)).preview == "workflow")
        #expect(NativeToolRow(tool("subagent", args: #"{"action":"status"}"#, output: boiler)).preview == "status")
        // A child's question shows the question, under a readable name, not the JSON receipt.
        let ask = NativeToolRow(tool("shepherd_parent_message", args: #"{"message":"Rename or replace?","needsReply":true}"#,
                                     output: #"{"shepherdParentMessage":"Rename or replace?"}"#))
        #expect(ask.name == "to parent" && ask.preview == "Rename or replace?" && ask.results.map(\.text) == ["asked"])
        // Extension notes drop the "custom ·" role prefix.
        #expect(nativeTurnItems([message(["entryID": "c", "role": "custom", "blocks": [["kind": "text", "text": "Workflow w1: done"]]])]) == [.note("Workflow w1: done")])
    }

    @Test func siblingsStepInSpawnOrderWithinTheGroup() {
        let runs = Self.doneRuns
        let spawn = { (id: String) -> NativeThreadMessage in
            NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: [], toolName: "shepherd_child_start", toolCallID: id, status: "complete")
        }
        let user = message(["entryID": "u", "role": "user", "blocks": []])
        let other = ChildRun(runID: "native-other", label: "docs", state: "complete", startedAt: 0, toolCallID: "spawn-other")
        let turns = nativeTurns([user, spawn("spawn-other"), user, spawn("spawn-tests"), spawn("spawn-worker"), spawn("spawn-reviewer")])
        let siblings = nativeSubagentSiblings(of: "native-tests", in: runs.reversed() + [other], turns: turns)
        #expect(siblings.map(\.runID) == ["native-worker", "native-reviewer", "native-tests"])
        #expect(nativeSubagentSiblings(of: "native-other", in: runs + [other], turns: turns).map(\.runID) == ["native-other"])
        // With no spawn rows loaded every run is a sibling, still in spawn order.
        #expect(nativeSubagentSiblings(of: "native-tests", in: runs.reversed(), turns: []).map(\.runID) == ["native-worker", "native-reviewer", "native-tests"])
    }

    @Test func subagentsSitAtTheirSpawnCallOrTrailTheLastTurn() {
        let spawnA = tool("shepherd_child_start", args: #"{"task":"a"}"#, output: "{}")
        let spawnB = tool("shepherd_child_start", args: #"{"task":"b"}"#, output: "{}")
        var a = spawnA; a.toolCallID = "spawn-a"
        var b = spawnB; b.toolCallID = "spawn-b"
        let read = tool("read", args: nil, output: "x")
        let user = message(["entryID": "u", "role": "user", "blocks": []])
        let prose = message(["entryID": "p", "role": "assistant", "blocks": [["kind": "text", "text": "Splitting."]]])
        let turns = nativeTurns([user, prose, a, read, user, b])
        let runA = ChildRun(runID: "ra", label: "l", state: "running", toolCallID: "spawn-a")
        let runB = ChildRun(runID: "rb", label: "l", state: "running", toolCallID: "spawn-b")
        let orphan = ChildRun(runID: "ro", label: "l", state: "complete", toolCallID: "gone")
        let bare = ChildRun(runID: "rn", label: "l", state: "running")
        let placements = nativeSubagentPlacements([runA, runB, orphan, bare], turns: turns)
        #expect(placements[turns[1].id]?.byToolCall == ["spawn-a": [runA]])
        #expect(placements[turns[1].id]?.trailing == [])
        #expect(placements[turns[3].id]?.byToolCall == ["spawn-b": [runB]])
        #expect(placements[turns[3].id]?.trailing == [orphan, bare])
        // The group splits around the spawn row: rows before, the card, rows after.
        let segments = toolSegments([a, read], placement: placements[turns[1].id]!)
        #expect(segments == [.subagents([runA]), .rows([read])])
        #expect(toolSegments([read, a], placement: placements[turns[1].id]!) == [.rows([read]), .subagents([runA])])
        #expect(toolSegments([read], placement: NativeSubagentPlacement()) == [.rows([read])])
        let wait = tool("shepherd_child_wait", args: nil, output: "internal run report")
        #expect(toolSegments([a, wait, read], placement: placements[turns[1].id]!) == [.subagents([runA]), .rows([read])])
        #expect(toolSegments([wait], placement: NativeSubagentPlacement()) == [.rows([wait])])
        // Above the threshold, every spawn row folds into one strip at the first spawn's position.
        var many = NativeSubagentPlacement()
        var rows: [NativeThreadMessage] = []
        for i in 0..<5 {
            var spawn = spawnA; spawn.toolCallID = "s\(i)"
            rows.append(spawn)
            many.byToolCall["s\(i)"] = [ChildRun(runID: "m\(i)", label: "l", state: "complete", toolCallID: "s\(i)")]
        }
        let folded = toolSegments([read] + rows + [read], placement: many)
        #expect(folded.count == 3)
        if case .subagents(let runs) = folded[1] { #expect(runs.count == 5) } else { Issue.record("expected one strip segment") }
        // A finished group of any size folds the same way, into the ledger at the first spawn row.
        var done = NativeSubagentPlacement()
        for run in Self.doneRuns { done.byToolCall[run.toolCallID!] = [run] }
        let spawns = ["spawn-worker", "spawn-reviewer", "spawn-tests"].map { id -> NativeThreadMessage in var s = spawnA; s.toolCallID = id; return s }
        #expect(subagentGroupFolds(done) && !subagentGroupFolds(placements[turns[1].id]!))
        let ledger = toolSegments(spawns + [read], placement: done)
        #expect(ledger.count == 2)
        if case .subagents(let runs) = ledger[0] { #expect(runs.count == 3) } else { Issue.record("expected one ledger segment") }
    }

    @Test func threadStoresKeepDraftsPerAgentAndPruneTheGone() {
        let stores = NativeThreadStores<AgentID>()
        let a = AgentID(), b = AgentID()
        let draft = stores.store(for: a)
        draft.draft = "unsent prompt"
        draft.delivery = .steer
        stores.store(for: b).draft = "other agent"
        #expect(stores.store(for: a) === draft)
        stores.prune(live: [a])
        #expect(stores.store(for: a) === draft && draft.draft == "unsent prompt" && draft.delivery == .steer)
        #expect(stores.store(for: b).draft.isEmpty)
    }

    /// Terminal-era Terminal/Native preferences are dropped on launch; nothing else is touched.
    @Test func legacyPresentationPreferencesAreForgotten() throws {
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["agent": true], forKey: "shepherd.nativeAgents")
        defaults.set(true, forKey: "shepherd.nativeDefault")
        defaults.set("terminal", forKey: "shepherd.agent.defaultRuntime")
        defaults.set(["space"], forKey: "shepherd.collapsedSpaces")
        LegacyTerminalAgents.forgetPresentationPreferences(in: defaults)
        for key in LegacyTerminalAgents.obsoleteKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.stringArray(forKey: "shepherd.collapsedSpaces") == ["space"])
    }

    @Test func tokenAndContextFormatting() {
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false, supportedActions: [],
                                            dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, runtime: "rpc")
        #expect(snapshot.isRPC)
        #expect(nativeTokenCount(999) == "999" && nativeTokenCount(42_400) == "42k" && nativeTokenCount(1_250_000) == "1.2M")
        #expect(nativeContextTooltip(NativeThreadStats(contextTokens: 42000, contextWindow: 200000, contextPercent: 21, totalTokens: 105000, cost: 0.451))
            == "42000 context tokens of 200k (21%) · 105k tokens this session · $0.45")
        #expect(nativeModelShortName("anthropic/claude/preview") == "claude/preview" && nativeModelShortName("bare") == "bare")
    }

    @Test func onlyTheActualPrimaryLocalLeafIsEligible() {
        let space = Space(name: "scratch", path: "/tmp")
        let id = AgentID()
        let primary = LeafPane(cwd: "/tmp", agentID: id)
        let auxiliary = LeafPane(cwd: "/tmp", agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .vertical, ratio: 0.4,
            first: .leaf(auxiliary), second: .leaf(primary)))
        var agent = Agent(id: id, name: "fixture", spaceID: space.id, tabID: tab.id, paneID: primary.id)
        #expect(primaryAgent(in: tab, pane: primary, agents: [agent]) == agent)
        #expect(primaryAgent(in: tab, pane: auxiliary, agents: [agent]) == nil)
        var review = primary
        review.isReview = true
        #expect(primaryAgent(in: tab, pane: review, agents: [agent]) == nil)
        var inspector = tab
        inspector.inspectorFor = id
        #expect(primaryAgent(in: inspector, pane: primary, agents: [agent]) == nil)
        let shell = Tab(spaceID: nil, order: 0, layout: .leaf(primary))
        #expect(primaryAgent(in: shell, pane: primary, agents: [agent]) == nil)
        agent.paneID = nil
        #expect(primaryAgent(in: tab, pane: primary, agents: [agent]) == nil)
    }

    @Test func blockParserHandlesHeadingsListsQuotesRulesAndFencesInLists() {
        let text = """
        # Plan
        Intro line
        continues here.

        - first **bold**
        - second
          - nested `code`
          - nested two
        - third

        1. one
        2. two
           ```swift
           let x = "```"
           - not a list
           ```

        > quoted
        > more

        ---

        ## Sub
        tail
        """
        let blocks = nativeMarkdownBlocks(text)
        #expect(blocks[0] == .heading(level: 1, text: "Plan"))
        #expect(blocks[1] == .paragraph("Intro line\ncontinues here."))
        #expect(blocks[2] == .list(ordered: false, start: 1, items: [
            .init(text: "first **bold**"),
            .init(text: "second", children: [.list(ordered: false, start: 1, items: [.init(text: "nested `code`"), .init(text: "nested two")])]),
            .init(text: "third"),
        ]))
        // A fence indented under an item belongs to it, and its body stays literal (the dash line is code).
        #expect(blocks[3] == .list(ordered: true, start: 1, items: [
            .init(text: "one"),
            .init(text: "two", children: [.code("let x = \"```\"\n- not a list", language: "swift")]),
        ]))
        #expect(blocks[4] == .quote("quoted\nmore"))
        #expect(blocks[5] == .rule)
        #expect(blocks[6] == .heading(level: 2, text: "Sub"))
        #expect(blocks[7] == .paragraph("tail"))
        #expect(blocks.count == 8)

        // Ordered lists keep their start number; an unclosed fence runs to the end; "#" without
        // a space and a lone dash are plain text.
        #expect(nativeMarkdownBlocks("3) c\n4) d") == [.list(ordered: true, start: 3, items: [.init(text: "c"), .init(text: "d")])])
        #expect(nativeMarkdownBlocks("```\npartial") == [.code("partial", language: nil)])
        #expect(nativeMarkdownBlocks("#hashtag and -dash") == [.paragraph("#hashtag and -dash")])
        #expect(nativeMarkdownBlocks("") == [])
        // A blank line ends a list unless the next line is indented under an item.
        #expect(nativeMarkdownBlocks("- a\n\nafter") == [.list(ordered: false, start: 1, items: [.init(text: "a")]), .paragraph("after")])
        #expect(nativeMarkdownBlocks("- a\n\n  still a") == [.list(ordered: false, start: 1, items: [.init(text: "a\n\nstill a")])])
    }

    @Test func scrollFollowerSticksAndDetachesOnlyOnUserIntent() {
        // (distance, userIntent, gesture, contentGrew) → (sticky, unseen)
        let cases: [(name: String, start: NativeScrollFollower, distance: Double, intent: Bool, gesture: Bool, grew: Bool, sticky: Bool, unseen: Bool)] = [
            ("starts sticky; programmatic growth keeps it", .init(), 300, false, false, true, true, false),
            ("wheel intent away from the bottom detaches", .init(), 300, true, false, false, false, false),
            // A gesture in progress is not intent by itself: the view decides whether it moved
            // the offset up (intent) or rows merely re-measured under it (layout).
            ("gesture in progress without an upward move stays stuck", .init(), 40, false, true, false, true, false),
            ("layout jitter without intent never detaches", .init(), 500, false, false, false, true, false),
            ("content grows while detached marks unseen", .init(sticky: false), 300, false, false, true, false, true),
            ("returning within 4pt re-sticks and clears unseen", .init(sticky: false, unseen: true), 3, false, false, false, true, false),
        ]
        for c in cases {
            var follower = c.start
            follower.userScrolling = c.gesture
            follower.observe(distanceFromBottom: c.distance, userIntent: c.intent, contentGrew: c.grew)
            #expect(follower.sticky == c.sticky, "\(c.name)")
            #expect(follower.unseen == c.unseen, "\(c.name)")
        }
        var detached = NativeScrollFollower(sticky: false, unseen: true)
        #expect(detached.showsJump(running: false) && detached.showsJump(running: true))
        detached.unseen = false
        #expect(!detached.showsJump(running: false) && detached.showsJump(running: true))
        detached.jumpToLatest()
        #expect(detached.sticky && !detached.showsJump(running: true))
        #expect(nativeWorkingLabel([]) == "Working…")
        #expect(nativeWorkingLabel([message(["role": "assistant", "status": "streaming", "blocks": [["kind": "thinking", "text": "hm"]]])]) == "Thinking…")
        #expect(nativeWorkingLabel([tool("bash", args: nil, output: "", status: "running")]) == "Running bash…")
    }

    @Test func pendingEchoShowsAfterAcceptAndSettlesAgainstTheSnapshot() async throws {
        let store = NativeThreadStore()
        var current = try JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(#"""
        {"piSessionID":"s","generation":"g","revision":1,"running":false,"supportedActions":["send"],"dialogsSupported":true,
         "dialogs":[],"messages":[{"entryID":"a","role":"assistant","blocks":[{"kind":"text","text":"hi"}],"truncated":false}],"provisional":[],"clipped":false}
        """#.utf8))
        var outcome: NativeThreadResult = .failure(code: "x", message: "not yet")
        let run = Task {
            await store.run { request in
                if case .snapshot = request { return .snapshot(value: current) }
                return outcome
            }
        }
        defer { run.cancel() }
        try await waitFor { store.ready }

        // Failure: draft stays, nothing echoed.
        store.draft = "do the thing"
        await store.send()
        #expect(store.draft == "do the thing" && store.pending.isEmpty && store.notice == "not yet")

        // A mismatched acknowledgement is not an acceptance: no echo, draft kept.
        outcome = .accepted(operationID: UUID())
        await store.send()
        #expect(store.pending.isEmpty && store.draft == "do the thing")
        run.cancel()
        store.stop()

        // Accepted: the echo shows at the tail with a pending id until pi persists the message.
        var accepted: UUID?
        let run2 = Task {
            await store.run { request in
                switch request {
                case .snapshot: return .snapshot(value: current)
                case .send(_, _, let id, _, _, _): accepted = id; return .accepted(operationID: id)
                default: return .failure(code: "x", message: "x")
                }
            }
        }
        defer { run2.cancel() }
        try await waitFor { store.ready && store.snapshot?.revision == 1 }
        store.draft = "do the thing"
        await store.send()
        #expect(accepted != nil && store.draft.isEmpty)
        #expect(store.pending.map(\.entryID) == ["pending:\(accepted!.uuidString)"])
        #expect(store.pending.first?.status == "pending" && store.pending.first?.role == "user")
        #expect(store.displayedMessages.map(\.entryID) == ["a", "pending:\(accepted!.uuidString)"])

        // An unrelated snapshot keeps the echo; the matching user message drops it.
        current.revision = 2
        await store.refresh()
        #expect(store.pending.count == 1)
        current.revision = 3
        current.messages.append(NativeThreadMessage(entryID: "u", role: "user", blocks: [.init(kind: .text, text: "do the thing\n")]))
        await store.refresh()
        #expect(store.pending.isEmpty && store.displayedMessages.map(\.entryID) == ["a", "u"])

        // A session change discards echoes outright.
        store.draft = "again"
        await store.send()
        #expect(store.pending.count == 1)
        current.piSessionID = "other"
        current.revision = 1
        await store.refresh(fresh: true)
        #expect(store.pending.isEmpty)

        // settledRunning holds 400 ms past the snapshot's running=false so tool gaps don't flicker.
        current.running = true; current.revision = 2
        await store.refresh()
        #expect(store.settledRunning)
        current.running = false; current.revision = 3
        await store.refresh()
        #expect(store.settledRunning)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!store.settledRunning)
    }

    @Test func nativeWindowStopsPollingWhenHiddenAndRendersStandardQuestions() async throws {
        let store = NativeThreadStore()
        var snapshot = try JSONDecoder().decode(NativeThreadSnapshot.self, from: Data(#"""
        {"piSessionID":"fixture","generation":"g","revision":1,"running":true,"model":"anthropic/claude-opus",
         "supportedActions":["send","abort","answer"],"dialogsSupported":true,
         "dialogs":[{"id":"choose","kind":"select","title":"Choose the deployment target","options":["Local scratch only","Other / custom answer"]}],
         "messages":[
          {"entryID":"u","role":"user","blocks":[{"kind":"text","text":"Check the native desktop presentation without starting a second pi process."}],"truncated":false},
          {"entryID":"a","role":"assistant","blocks":[{"kind":"thinking","text":"Check focus and exact dialog values."},{"kind":"text","text":"**The same agent is still running.** This is a native transcript, not parsed terminal output.\n\n```swift\nlet mode = presentation.isNative(agent.id)\n```"}],"truncated":false},
          {"entryID":"t1","role":"toolResult","toolName":"read","toolCallID":"c1","status":"complete","argumentsText":"{\"path\":\"Sources/ShepherdApp/ThreadView.swift\",\"offset\":237,\"limit\":160}","blocks":[{"kind":"text","text":"struct ThreadView: View {\n    @ObservedObject var store: NativeThreadStore\n}"}],"truncated":false},
          {"entryID":"t2","role":"toolResult","toolName":"edit","toolCallID":"c2","status":"complete","argumentsText":"{\"path\":\"App/iOS/ThreadView.swift\",\"edits\":[{\"oldText\":\"a\\nb\\nc\\nd\",\"newText\":\"a\"}]}","blocks":[{"kind":"text","text":"Successfully replaced 1 block(s) in App/iOS/ThreadView.swift."}],"truncated":false},
          {"entryID":"t3","role":"toolResult","toolName":"grep","toolCallID":"c3","status":"complete","argumentsText":"{\"pattern\":\"speakerLabel\",\"path\":\"Sources/\"}","blocks":[{"kind":"text","text":"Sources/A.swift:12: speakerLabel\nSources/B.swift:40: speakerLabel\nSources/C.swift:7: speakerLabel"}],"truncated":false},
          {"entryID":"t4","role":"toolResult","toolName":"bash","toolCallID":"c4","status":"complete","argumentsText":"{\"command\":\"swift test --filter toolPreviewPrefersActionAndFallsBackToSavedOutput\"}","blocks":[{"kind":"text","text":"Build complete! (10.20 sec)\n◇ Suite \"Desktop native presentation\" started.\n◆ Test run with 1 test in 1 suite passed after 0.001 seconds.\n1 test passed"}],"truncated":false},
          {"entryID":"t5","role":"toolResult","toolName":"bash","toolCallID":"c5","status":"complete","isError":true,"argumentsText":"{\"command\":\"swift test --filter NativePresentationTests\"}","blocks":[{"kind":"text","text":"error: cannot find 'MobileTokens' in scope\n  --> App/iOS/ThreadView.swift:41:27\n\nCommand exited with code 1"}],"truncated":false},
          {"entryID":"a2","role":"assistant","blocks":[{"kind":"text","text":"Removed the visible speaker labels and the desktop gutter. User-message fills still distinguish the conversation."}],"truncated":false}],
         "widgets":[{"namespace":"fixture.build","key":"status","kind":"status","title":"Build status","text":"Focused checks passed"},
                    {"namespace":"fixture.review","key":"notes","kind":"text","title":"Review notes","text":"Plain text only: **not bold**\nNo callbacks or controls."}],
         "provisional":[{"entryID":"provisional:tool:c6","role":"toolResult","toolName":"bash","toolCallID":"c6","status":"running","argumentsText":"{\"command\":\"xcodebuild -scheme 'Shepherd (Dev)' build\"}","blocks":[],"truncated":false}],"clipped":false}
        """#.utf8))
        // SHEPHERD_NATIVE_SCREENSHOT_STATE=running renders the same thread mid-turn with no dialog.
        if ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_STATE"] == "running" { snapshot.dialogs = [] }
        var requests: [NativeThreadRequest] = []
        let request: NativeThreadStore.Request = { value in
            requests.append(value)
            return .snapshot(value: snapshot)
        }
        // Header + thread, the way the workspace composes them for a native agent.
        func content(active: Bool) -> some View {
            VStack(spacing: 0) {
                ThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities")
                ThreadView(store: store, active: active, isFocused: active, request: request)
            }
        }
        _ = NSApplication.shared
        // SHEPHERD_NATIVE_SCREENSHOT_WIDTH lets the screenshot pass check narrow windows.
        let width = ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_WIDTH"].flatMap(Double.init) ?? 1180
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content(active: true).preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        #expect(store.snapshot?.widgets?.map(\.kind) == [.status, .text])
        store.draft = "draft stays native"
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        try capture(host, name: "native-thread")
        host.rootView = content(active: false).preferredColorScheme(ThemeManager.shared.mode.colorScheme)
        try await waitFor { !store.ready }
        let stoppedCount = requests.count
        try await Task.sleep(for: .milliseconds(2200))
        #expect(requests.count == stoppedCount)
        #expect(store.draft == "draft stays native")
        host.rootView = content(active: true).preferredColorScheme(ThemeManager.shared.mode.colorScheme)
        try await waitFor { store.ready && requests.count > stoppedCount }
        #expect(requests.last == .snapshot())
        #expect(store.draft == "draft stays native")
    }

    /// Renders a real pi session (SHEPHERD_REAL_SESSION=<jsonl>) through the native projection so
    /// the visual pass sees real output, not fixtures. Skipped when the env var is unset.
    @Test func realSessionRenders() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["SHEPHERD_REAL_SESSION"] else { return }
        guard case .transcript(let page) = RPCThreadState.transcript(runID: "real", file: file, beforeEntryID: nil) else {
            Issue.record("unreadable session \(file)"); return
        }
        let snapshot = NativeThreadSnapshot(piSessionID: "real", generation: "g", revision: 1, running: false,
                                            supportedActions: ["send", "abort", "answer"], dialogsSupported: true, dialogs: [],
                                            messages: page.messages, provisional: [], clipped: false)
        let store = NativeThreadStore()
        let request: NativeThreadStore.Request = { _ in .snapshot(value: snapshot) }
        _ = NSApplication.shared
        let width = env["SHEPHERD_NATIVE_SCREENSHOT_WIDTH"].flatMap(Double.init) ?? 1500
        let height = env["SHEPHERD_NATIVE_SCREENSHOT_HEIGHT"].flatMap(Double.init) ?? 1300
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: "Real session")
            ThreadView(store: store, active: true, isFocused: true, request: request)
        }.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        try capture(host, name: "real-session")
    }

    /// The board's thread (docs/design-spec/subagents-with-inspector.png): a user turn, the
    /// "Splitting into three" prose, three spawn calls that the cards replace, a closing line.
    private static func subagentSnapshot(running: Bool) -> NativeThreadSnapshot {
        func spawn(_ id: String, _ role: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "{\"id\":\"native-\(role)\"}")],
                                toolName: "shepherd_child_start", toolCallID: id, argumentsText: "{\"task\":\"\(role)\",\"role\":\"\(role)\"}", status: "complete")
        }
        return NativeThreadSnapshot(
            piSessionID: "fixture", generation: "g", revision: 1, running: running, model: "anthropic/claude-fable-5-1", thinking: "high",
            supportedActions: ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents"], dialogsSupported: true, dialogs: [],
            messages: [
                NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Restyle all of Shepherd's native UI to match the design spec. Split it up if that's faster.")]),
                NativeThreadMessage(entryID: "a", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Splitting into three: a worker for the restyle itself, a reviewer that checks each step against the spec, and a tests run in parallel. I'll integrate when they hand off.")]),
                spawn("spawn-worker", "worker"), spawn("spawn-reviewer", "reviewer"), spawn("spawn-tests", "tests"),
                NativeThreadMessage(entryID: "a2", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "*Waiting on worker and reviewer. Tests are integrated.*")]),
            ],
            provisional: [], clipped: false, runtime: "rpc",
            stats: NativeThreadStats(contextTokens: 60_000, contextWindow: 200_000, contextPercent: 30, totalTokens: 1_600_000),
            subagents: Array(boardRuns.prefix(3)))
    }

    @Test func inspectorLoadsCompleteTranscriptAndHonorsDetachedReading() async throws {
        let store = NativeThreadStore()
        let snapshot = Self.subagentSnapshot(running: false)
        let older = NativeThreadMessage(entryID: "c:old", role: "user", blocks: [.init(kind: .text, text: "original task")])
        let newest = NativeThreadMessage(entryID: "c:new", role: "assistant", blocks: [.init(kind: .text, text: "finished")])
        let request: NativeThreadStore.Request = { request in
            if case .subagentTranscript(_, let id, let cursor) = request {
                return .transcript(value: NativeSubagentTranscript(runID: id, messages: cursor == nil ? [newest] : [older],
                                                                  olderCursor: cursor == nil ? "c:new" : nil, earlierCount: cursor == nil ? 1 : 0))
            }
            return .snapshot(value: snapshot)
        }
        let polling = Task { await store.run(request: request) }
        defer { polling.cancel(); store.stop() }
        try await waitFor { store.ready }
        let model = SubagentTranscriptModel()
        let following = Task { await model.follow(store: store, runID: "native-tests") { false } }
        defer { following.cancel() }
        try await waitFor { model.loaded }
        model.setFollowing(false)
        await model.reload(store: store, runID: "native-tests")
        #expect(!model.following)
        await model.loadAll(store: store, runID: "native-tests")
        #expect(model.messages.map(\.entryID) == ["c:old", "c:new"])
        #expect(model.earlierCount == 0 && !model.loadingOlder)
    }

    @Test func subagentAllStatesRenderTheBoard() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        let actions = SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }, enabled: true)
        let runs = Self.boardRuns
        let many = (0..<12).map { index -> ChildRun in
            var run = runs[index < 7 ? 2 : index < 10 ? 0 : index == 10 ? 1 : 3]
            run.runID = "strip-\(index)"
            run.startedAt = Double(index)
            return run
        }
        let content = VStack(alignment: .leading, spacing: 22) {
            ForEach(runs, id: \.id) { run in
                SubagentCard(run: run, actions: actions)
            }
            Text("MANY PARALLEL RUNS").font(NativeFonts.section).foregroundStyle(NativeTokens.textMuted)
            RunsStrip(runs: many, actions: actions, expanded: .constant(false))
        }
        .padding(32).frame(width: 760, alignment: .topLeading).background(NativeTokens.bgSurface)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        try capture(host, name: "subagents-all-states")
    }

    /// Screenshot-only: the three cards on the board, with real timings (the clock runs from
    /// startedAt), rendered as the workspace composes them. Compare with
    /// docs/design-spec/subagents-with-inspector.png.
    @Test func subagentCardsRenderTheBoard() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        let store = NativeThreadStore()
        // Re-time the board runs to "now" so the header durations read 37m 21s / 2m 10s / 4m 02s.
        let shift = Date().timeIntervalSince1970 * 1000 - Self.boardNow.timeIntervalSince1970 * 1000
        var snapshot = Self.subagentSnapshot(running: true)
        snapshot.subagents = snapshot.subagents?.map { run in
            var run = run
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            run.lastActivity?.at += shift
            return run
        }
        var inspected: [ChildRun] = []
        let request: NativeThreadStore.Request = { _ in .snapshot(value: snapshot) }
        let content = VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities")
            ThreadView(store: store, active: true, isFocused: true, request: request,
                                    agentName: "Investigate", inspectSubagent: { inspected.append($0) })
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        try capture(host, name: "subagents")
        // The three cards sit where their spawn calls were; the placement is what the view renders.
        #expect(store.subagents.count == 3)
        let placements = nativeSubagentPlacements(store.subagents, turns: nativeTurns(store.displayedMessages))
        #expect(placements.values.first?.byToolCall.keys.sorted() == ["spawn-reviewer", "spawn-tests", "spawn-worker"])
        #expect(inspected.isEmpty)
    }

    /// The completed board: the same thread once every run is terminal, with pi timestamps so the
    /// footer reads "11:09 AM · 45m 12s · 3 subagents" and the ledger replaces the cards.
    private static func doneSnapshot() -> NativeThreadSnapshot {
        var snapshot = subagentSnapshot(running: false)
        let end = Date().timeIntervalSince1970 * 1000
        let start = end - (45 * 60 + 12) * 1000
        snapshot.messages[0].timestamp = start
        for index in 1..<snapshot.messages.count { snapshot.messages[index].timestamp = start + Double(index) * 1000 }
        snapshot.messages[snapshot.messages.count - 1].timestamp = end
        snapshot.messages[snapshot.messages.count - 1].blocks = [NativeThreadBlock(kind: .text, text: "All three handed off. Integrated the restyle; the suites are green on both platforms.")]
        let shift = end - boardNow.timeIntervalSince1970 * 1000
        snapshot.subagents = doneRuns.map { run in
            var run = run
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            return run
        }
        return snapshot
    }

    /// Screenshot-only: the completed group as a ledger card with the turn footer beneath it.
    @Test func subagentLedgerRendersTheBoard() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        let store = NativeThreadStore()
        let snapshot = Self.doneSnapshot()
        let request: NativeThreadStore.Request = { _ in .snapshot(value: snapshot) }
        let content = VStack(spacing: 0) {
            ThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities")
            ThreadView(store: store, active: true, isFocused: true, request: request,
                                    agentName: "Investigate", inspectSubagent: { _ in }, inspectedRunID: "native-tests")
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        try capture(host, name: "subagents-done")
        #expect(nativeSubagentGroupIsTerminal(store.subagents))
    }

    /// Screenshot-only: the read-only inspector on the finished "tests" run: RESULT block with
    /// file links, a from-parent bubble, the turn line, and the Re-run / Fork / Copy bar.
    @Test func subagentDoneInspectorRendersTheBoard() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        let store = NativeThreadStore()
        let snapshot = Self.doneSnapshot()
        let end = snapshot.subagents![2].endedAt!
        func tool(_ id: String, _ name: String, _ args: String, _ output: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "c:\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: output)],
                                toolName: name, toolCallID: id, argumentsText: args, status: "complete", isError: false)
        }
        let page = NativeSubagentTranscript(runID: "native-tests", messages: [
            NativeThreadMessage(entryID: "c:u1", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Add presentation tests for the restyle and run the suites on macOS and iOS.")], timestamp: end - 4 * 60_000),
            NativeThreadMessage(entryID: "c:a1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Reading the current suite to match its fixtures.")]),
            tool("r1", "read", #"{"path":"Tests/ShepherdAppTests/NativePresentationTests.swift","offset":1,"limit":120}"#, Array(repeating: "x", count: 120).joined(separator: "\n")),
            tool("e1", "edit", #"{"path":"Tests/ShepherdAppTests/NativePresentationTests.swift","edits":[{"oldText":"a","newText":"a\nb\nc"}]}"#, "Successfully replaced 1 block(s)"),
            NativeThreadMessage(entryID: "c:u2", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Also cover the iOS thread store check.")], timestamp: end - 2 * 60_000),
            NativeThreadMessage(entryID: "c:a2", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Added the iOS check alongside.")]),
            tool("b1", "bash", #"{"command":"swift test --filter NativePresentationTests"}"#, "14 tests passed"),
            NativeThreadMessage(entryID: "c:a3", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Added 6 presentation tests (preview text per tool kind, DiffStat, duration formatting). All 14 pass on macOS and iOS simulators.")], timestamp: end),
        ], olderCursor: nil, earlierCount: 0)
        let request: NativeThreadStore.Request = { value in
            if case .subagentTranscript = value { return .transcript(value: page) }
            return .snapshot(value: snapshot)
        }
        let inspector = RightPaneState()
        inspector.runByAgent[AgentID(rawValue: "a")] = "native-tests"
        let content = RightPaneSplit(state: inspector, showPane: true) {
            VStack(spacing: 0) {
                ThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities")
                ThreadView(store: store, active: true, isFocused: true, request: request, agentName: "Investigate",
                                        inspectSubagent: { _ in }, inspectedRunID: "native-tests")
            }
        } pane: {
            SubagentInspector(store: store, runID: "native-tests", active: true, close: {}, select: { _ in }, fork: { _ in nil })
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1370, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        try capture(host, name: "subagents-done-inspector")
    }

    /// Screenshot-only: the thread with the worker open in the side-panel inspector, its
    /// transcript served from a synthetic page. Compare with docs/design-spec/subagents-with-inspector.png.
    @Test func subagentInspectorRendersTheBoard() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        let store = NativeThreadStore()
        let shift = Date().timeIntervalSince1970 * 1000 - Self.boardNow.timeIntervalSince1970 * 1000
        var snapshot = Self.subagentSnapshot(running: true)
        snapshot.subagents = snapshot.subagents?.map { run in
            var run = run
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            run.lastActivity?.at += shift
            if run.runID == "native-worker" { run.currentTool = "bash" }
            return run
        }
        func tool(_ id: String, _ name: String, _ args: String, _ output: String, running: Bool = false) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "c:\(id)", role: "toolResult", blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                                toolName: name, toolCallID: id, argumentsText: args, status: running ? "running" : "complete", isError: false)
        }
        let page = NativeSubagentTranscript(runID: "native-worker", messages: [
            NativeThreadMessage(entryID: "c:a1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "Tokens landed. Now moving the tool-row derivations into a shared presentation file so macOS and iOS use the same previews.")]),
            tool("r1", "read", #"{"path":"Sources/ShepherdApp/ThreadView.swift","offset":1,"limit":420}"#, Array(repeating: "x", count: 420).joined(separator: "\n")),
            tool("w1", "write", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, "wrote 142 lines"),
            tool("e1", "edit", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift","edits":[{"oldText":"a\nb","newText":"a\nB\nc"}]}"#, "Successfully replaced 1 block(s)"),
            tool("b1", "bash", #"{"command":"swift build --target ShepherdRemote"}"#, "", running: true),
            NativeThreadMessage(entryID: "c:a2", role: "assistant", blocks: [NativeThreadBlock(kind: .thinking, text: "Checking the build output.")], status: "streaming"),
        ], olderCursor: "c:a1", earlierCount: 72)
        let request: NativeThreadStore.Request = { value in
            if case .subagentTranscript = value { return .transcript(value: page) }
            return .snapshot(value: snapshot)
        }
        let inspector = RightPaneState()
        inspector.runByAgent[AgentID(rawValue: "a")] = "native-worker"
        let content = RightPaneSplit(state: inspector, showPane: true) {
            VStack(spacing: 0) {
                ThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities")
                ThreadView(store: store, active: true, isFocused: true, request: request, agentName: "Investigate", inspectSubagent: { _ in })
            }
        } pane: {
            SubagentInspector(store: store, runID: "native-worker", active: true, close: {})
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1370, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitFor { store.ready }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        try capture(host, name: "subagents-inspector")
    }

    /// Screenshot-only: renders the restyled sidebar against a scratch server so the
    /// artboard comparison covers real rows (sections, dots, right slots, bottom block).
    @Test func sidebarRendersSpecRows() async throws {
        guard ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] != nil else { return }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: "/tmp/native-sidebar-\(UInt32.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let server = SessionServer(socketPath: dir.appendingPathComponent("s").path, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop() }
        let space = Space(name: "Shepherd", path: dir.path)
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        let rows: [(String, AgentStatus)] = [("Plan shepherd extensions", .working), ("Dock review pane", .working),
                                             ("Fix remote subagent deletion", .idle), ("Fix terminal output buffer", .idle),
                                             ("Investigate SwiftUI live preview", .idle), ("Fix remote nightly", .blocked), ("Fix agent deletion workflow", .done)]
        for (title, status) in rows {
            let id = AgentID()
            let pane = LeafPane(cwd: dir.path, agentID: id)
            let tab = Tab(spaceID: space.id, order: tabs.count, layout: .leaf(pane))
            var agent = Agent(id: id, name: title, spaceID: space.id, tabID: tab.id, paneID: pane.id)
            agent.status = status
            tabs.append(tab); agents.append(agent)
        }
        tabs.append(Tab(spaceID: nil, order: 0, layout: .leaf(LeafPane(cwd: dir.path)), name: "~"))
        let automation = Automation(name: "Merge PR #24 after CI", prompt: "watch", cwd: dir.path, enabled: false)
        try await server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents, automations: [automation]))
        let vm = ShepherdViewModel(server: server, settings: AppSettings(store: defaults),
                                   keybindings: KeybindingsStore(store: defaults), remoteHosts: RemoteHostStore(defaults: defaults),
                                   sidebarDefaults: defaults, themeInstaller: { _ in })
        try await waitFor { vm.state.agents.count == rows.count }
        vm.selectedSpaceID = space.id
        vm.selectedAgentID = agents[4].id
        // Loaded children must not add rows to the sidebar; they live in the thread cards.
        vm.applyAgentChildren(agents[4].id, Self.boardRuns.prefix(3).map { run in
            var run = run
            let shift = Date().timeIntervalSince1970 * 1000 - Self.boardNow.timeIntervalSince1970 * 1000
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            return run
        })
        vm.applyAgentChildren(agents[6].id, Self.doneRuns)
        // An unreachable second machine makes the tree show its THIS MAC / host structure.
        vm.remoteHosts.addHost(name: "Horizon", host: "127.0.0.1", port: 1, token: "x")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 256, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SidebarView(vm: vm).frame(width: 256, height: 640)
            .background(NativeTokens.bgCanvas).preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        try capture(host, name: "sidebar")
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }

    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
