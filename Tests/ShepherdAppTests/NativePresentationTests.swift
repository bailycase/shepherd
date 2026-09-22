import AppKit
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
@testable import ShepherdApp
@testable import TerminalSurfaceKit

@Suite("Desktop native presentation", .serialized)
@MainActor
struct NativePresentationTests {
    @Test func toolPreviewPrefersActionAndFallsBackToSavedOutput() throws {
        var message = try JSONDecoder().decode(NativeThreadMessage.self, from: Data(#"{"entryID":"t","role":"toolResult","toolName":"bash","argumentsText":"{\"command\":\"swift test\"}","blocks":[{"kind":"text","text":"Build complete\nAll tests passed"}],"truncated":false}"#.utf8))
        #expect(desktopNativeToolPreview(message) == "swift test")
        message.argumentsText = nil
        #expect(desktopNativeToolPreview(message) == "Build complete")
        message.blocks = []
        #expect(desktopNativeToolPreview(message) == nil)
    }

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
        #expect(NativeAgentPill.needsApproval.label == "Needs approval")
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
        #expect(nativeHeadTruncated(path, max: path.count - 1).hasSuffix("DesktopNativeThreadView.swift"))
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
        let segments = nativeToolSegments([a, read], placement: placements[turns[1].id]!)
        #expect(segments == [.subagents([runA]), .rows([read])])
        #expect(nativeToolSegments([read, a], placement: placements[turns[1].id]!) == [.rows([read]), .subagents([runA])])
        #expect(nativeToolSegments([read], placement: NativeSubagentPlacement()) == [.rows([read])])
        // Above the threshold, every spawn row folds into one strip at the first spawn's position.
        var many = NativeSubagentPlacement()
        var rows: [NativeThreadMessage] = []
        for i in 0..<5 {
            var spawn = spawnA; spawn.toolCallID = "s\(i)"
            rows.append(spawn)
            many.byToolCall["s\(i)"] = [ChildRun(runID: "m\(i)", label: "l", state: "complete", toolCallID: "s\(i)")]
        }
        let folded = nativeToolSegments([read] + rows + [read], placement: many)
        #expect(folded.count == 3)
        if case .subagents(let runs) = folded[1] { #expect(runs.count == 5) } else { Issue.record("expected one strip segment") }
    }

    @Test func sparsePreferencesAndAgentDraftsSurviveToggles() throws {
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let presentation = NativePresentation(defaults: defaults)
        let a = AgentID(), b = AgentID()
        #expect(!presentation.isNative(a) && !presentation.isNative(b))
        let draft = presentation.store(for: a)
        draft.draft = "unsent native prompt"
        draft.delivery = .steer
        presentation.store(for: b).draft = "other agent"
        for _ in 0..<3 {
            presentation.setNative(true, for: a)
            #expect(NativePresentation(defaults: defaults).isNative(a))
            presentation.setNative(false, for: a)
            #expect(defaults.dictionary(forKey: NativePresentation.defaultsKey)?.isEmpty == true)
        }
        #expect(presentation.store(for: a) === draft)
        #expect(draft.draft == "unsent native prompt" && draft.delivery == .steer)
        #expect(presentation.store(for: b).draft == "other agent")
        presentation.setNative(true, for: a)
        presentation.setNative(true, for: b)
        presentation.prune(liveAgents: [a])
        #expect(presentation.nativeAgents == [a])
        #expect(presentation.store(for: a) === draft)
        #expect(presentation.store(for: b).draft.isEmpty)
    }

    @Test func defaultViewAppliesUnlessTheAgentWasOverridden() throws {
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // A pre-default build's plain list still reads as native overrides.
        let legacy = AgentID()
        defaults.set([legacy.rawValue], forKey: NativePresentation.defaultsKey)
        let presentation = NativePresentation(defaults: defaults)
        #expect(presentation.isNative(legacy) && !presentation.defaultNative)

        let pinnedTerminal = AgentID(), untouched = AgentID()
        presentation.defaultNative = true
        #expect(presentation.isNative(untouched) && presentation.isNative(legacy))
        presentation.setNative(false, for: pinnedTerminal)
        #expect(!presentation.isNative(pinnedTerminal))
        // Re-choosing the default clears the override instead of pinning it.
        presentation.setNative(true, for: legacy)
        #expect(presentation.overrides[legacy] == nil)

        let reloaded = NativePresentation(defaults: defaults)
        #expect(reloaded.defaultNative && !reloaded.isNative(pinnedTerminal) && reloaded.isNative(untouched))
        reloaded.defaultNative = false
        #expect(!reloaded.isNative(untouched) && !reloaded.isNative(pinnedTerminal))
    }

    /// D2: an RPC agent has no terminal, so it is native regardless of the default or any
    /// override, and flipping it never persists anything.
    @Test func rpcAgentsAreAlwaysNativeAndNeverRecordAnOverride() throws {
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let presentation = NativePresentation(defaults: defaults)
        let space = SpaceID()
        let rpc = Agent(name: "rpc", spaceID: space, tabID: TabID(), runtime: .rpc)
        let terminal = Agent(name: "tty", spaceID: space, tabID: TabID(), runtime: .terminal)
        #expect(!presentation.defaultNative)
        #expect(presentation.isNative(rpc) && !presentation.isNative(terminal))
        #expect(!presentation.canSwitch(rpc) && presentation.canSwitch(terminal))
        presentation.setNative(false, for: rpc)
        #expect(presentation.isNative(rpc))
        #expect(presentation.overrides[rpc.id] == nil)
        #expect(defaults.dictionary(forKey: NativePresentation.defaultsKey) == nil)
        // A stale override from when this id was a terminal agent cannot un-native it either.
        presentation.setNative(false, for: rpc.id)
        presentation.defaultNative = true
        #expect(presentation.isNative(rpc))
        presentation.setNative(false, for: terminal)
        #expect(!presentation.isNative(terminal) && presentation.overrides[terminal.id] == false)
        #expect(NativePresentation(defaults: defaults).isNative(rpc))
        // Snapshot side: the view keys its RPC affordances on the runtime field.
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
        #expect(NativePresentation.primaryAgent(in: tab, pane: primary, agents: [agent]) == agent)
        #expect(NativePresentation.primaryAgent(in: tab, pane: auxiliary, agents: [agent]) == nil)
        var review = primary
        review.isReview = true
        #expect(NativePresentation.primaryAgent(in: tab, pane: review, agents: [agent]) == nil)
        var inspector = tab
        inspector.inspectorFor = id
        #expect(NativePresentation.primaryAgent(in: inspector, pane: primary, agents: [agent]) == nil)
        let shell = Tab(spaceID: nil, order: 0, layout: .leaf(primary))
        #expect(NativePresentation.primaryAgent(in: shell, pane: primary, agents: [agent]) == nil)
        agent.paneID = nil
        #expect(NativePresentation.primaryAgent(in: tab, pane: primary, agents: [agent]) == nil)
    }

    @Test func markdownKeepsCodeLiteralAndUnclosedFences() {
        let parts = desktopNativeMarkdown("**prose**\n````swift\nlet x = \"```\"\n```\n````\nlast")
        #expect(parts.map(\.code) == [false, true, false])
        #expect(parts.map(\.text) == ["**prose**", "let x = \"```\"\n```", "last"])
        #expect(desktopNativeMarkdown("```\npartial").last?.code == true)
        #expect(desktopNativeMarkdown("```\npartial").last?.text == "partial")
        #expect(desktopNativeMarkdown("ordinary `inline` text").first?.code == false)
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
            .init(text: "two", children: [.code("let x = \"```\"\n- not a list")]),
        ]))
        #expect(blocks[4] == .quote("quoted\nmore"))
        #expect(blocks[5] == .rule)
        #expect(blocks[6] == .heading(level: 2, text: "Sub"))
        #expect(blocks[7] == .paragraph("tail"))
        #expect(blocks.count == 8)

        // Ordered lists keep their start number; an unclosed fence runs to the end; "#" without
        // a space and a lone dash are plain text.
        #expect(nativeMarkdownBlocks("3) c\n4) d") == [.list(ordered: true, start: 3, items: [.init(text: "c"), .init(text: "d")])])
        #expect(nativeMarkdownBlocks("```\npartial") == [.code("partial")])
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
            ("drag gesture detaches", .init(), 40, false, true, false, false, false),
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

    /// Real leaf, real Ghostty NSView and PTY. Presentation changes must not attach again,
    /// alter the split/mounted order, deliver native drafts as PTY input, or lose live output.
    @Test func primaryLeafToggleKeepsTerminalSessionAndSurfaceMounted() async throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: "/tmp/native-pane-\(UInt32.random(in: 0..<1_000_000))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "native-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let server = SessionServer(socketPath: dir.appendingPathComponent("s").path, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop() }
        let info = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: [
            "/bin/sh", "-c", "stty -echo; printf 'ready-for-presentation\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done"
        ]))
        let space = Space(name: "fixture", path: dir.path)
        let id = AgentID()
        let pane = LeafPane(sessionID: info.id, cwd: dir.path, agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "fixture", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        try await server.putState(state)
        let vm = ShepherdViewModel(server: server, settings: AppSettings(store: defaults),
                                   keybindings: KeybindingsStore(store: defaults), remoteHosts: RemoteHostStore(defaults: defaults),
                                   sidebarDefaults: defaults, themeInstaller: { _ in })
        try await waitFor { vm.state.agents.count == 1 }
        vm.selectedSpaceID = space.id
        vm.selectedAgentID = id
        vm.focusedPaneID = pane.id
        let session = vm.sessions.session(for: pane, in: tab)
        let thread = vm.nativePresentation.store(for: id)
        thread.draft = "never send this draft to the PTY"
        let mounted = vm.mountedTabs.map(\.id)
        var attachments = 0
        let attached = session.terminal.onSurfaceAttachmentChanged
        session.terminal.onSurfaceAttachmentChanged = { generation in
            attachments += 1
            attached?(generation)
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            WorkspaceHeaderView(vm: vm)
            PaneLeafView(vm: vm, tab: tab, pane: pane)
        }.preferredColorScheme(ThemeManager.shared.mode.colorScheme))
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        window.layoutIfNeeded()
        try await waitFor { session.phase == .live && !TerminalFirstResponder.surfaceViews(in: host).isEmpty }
        let surface = try #require(TerminalFirstResponder.surfaceViews(in: host).first)
        let initialAttachments = attachments
        try await waitFor { window.firstResponder === surface }
        try capture(host, name: "terminal-primary")
        for i in 0..<3 {
            vm.nativePresentation.setNative(true, for: id)
            try await waitFor { !session.terminal.model.renderingActive }
            try await waitFor { window.firstResponder is NSTextView }
            #expect(window.firstResponder !== surface)
            if i == 0 {
                try await waitFor { thread.loadError != nil }
                try capture(host, name: "native-unavailable")
            }
            var dropped = false
            session.terminal.onFileDrop = { _ in dropped = true }
            #expect(!session.terminal.model.sendDroppedFiles([dir.appendingPathComponent("image.png")]))
            #expect(!dropped)
            session.terminal.onFileDrop = nil
            #expect(thread.draft == "never send this draft to the PTY")
            server.write(sessionID: info.id, data: Data("hidden-\(i)\n".utf8))
            try await waitFor { session.terminal.model.session.readViewportText()?.contains("hidden-\(i)") == true }
            vm.nativePresentation.setNative(false, for: id)
            try await waitFor { session.terminal.model.renderingActive && window.firstResponder === surface }
            #expect(TerminalFirstResponder.surfaceViews(in: host).first === surface)
            #expect(vm.sessions.session(for: pane, in: tab) === session)
            #expect(vm.nativePresentation.store(for: id) === thread)
            #expect(vm.mountedTabs.map(\.id) == mounted)
            #expect(vm.activeTabID == tab.id && vm.state.tabs.first?.layout == tab.layout)
            #expect(attachments == initialAttachments)
            #expect(!thread.ready)
            // Ordinary state refreshes also keep the store and terminal identity.
            vm.adopt(server.state)
        }
        session.terminal.onInput?(Data("terminal-input-still-works\n".utf8))
        try await waitFor { session.terminal.model.session.readViewportText()?.contains("terminal-input-still-works") == true }
        #expect(await server.listSessions().map(\.id) == [info.id])
        #expect(await server.sessionInfo(sessionID: info.id)?.isAlive == true)
        #expect(await server.screenText(sessionID: info.id)?.contains(thread.draft) == false)
        #expect(server.state.tabs.first?.layout == tab.layout)
        // A half-typed terminal line is not the native draft and survives the switch.
        session.terminal.onInput?(Data("terminal-draft-".utf8))
        vm.focusedPaneID = nil
        vm.nativePresentation.setNative(true, for: id)
        try await waitFor { !session.terminal.model.renderingActive }
        #expect(!(window.firstResponder is NSTextView))
        vm.focusedPaneID = pane.id
        try await waitFor { window.firstResponder is NSTextView }
        vm.nativePresentation.setNative(false, for: id)
        try await waitFor { window.firstResponder === surface }
        session.terminal.onInput?(Data("retained\n".utf8))
        try await waitFor { session.terminal.model.session.readViewportText()?.contains("terminal-draft-retained") == true }
        #expect(thread.draft == "never send this draft to the PTY")
        // Menu/header eligibility follows the active layout, not an old selected agent.
        vm.selectedRemoteAgent = RemoteAgentRef(hostID: UUID(), agentID: id)
        #expect(vm.nativePresentationAgent == nil)
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
          {"entryID":"t1","role":"toolResult","toolName":"read","toolCallID":"c1","status":"complete","argumentsText":"{\"path\":\"Sources/ShepherdApp/DesktopNativeThreadView.swift\",\"offset\":237,\"limit\":160}","blocks":[{"kind":"text","text":"struct DesktopNativeThreadView: View {\n    @ObservedObject var store: NativeThreadStore\n}"}],"truncated":false},
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
                NativeThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities",
                                   native: .constant(true), showTerminal: {})
                DesktopNativeThreadView(store: store, active: active, isFocused: active, request: request, showTerminal: {})
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
            NativeThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities", native: .constant(true), showTerminal: nil)
            DesktopNativeThreadView(store: store, active: true, isFocused: true, request: request, showTerminal: nil,
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
            tool("r1", "read", #"{"path":"Sources/ShepherdApp/DesktopNativeThreadView.swift","offset":1,"limit":420}"#, Array(repeating: "x", count: 420).joined(separator: "\n")),
            tool("w1", "write", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift"}"#, "wrote 142 lines"),
            tool("e1", "edit", #"{"path":"Sources/ShepherdRemote/NativeThreadPresentation.swift","edits":[{"oldText":"a\nb","newText":"a\nB\nc"}]}"#, "Successfully replaced 1 block(s)"),
            tool("b1", "bash", #"{"command":"swift build --target ShepherdRemote"}"#, "", running: true),
            NativeThreadMessage(entryID: "c:a2", role: "assistant", blocks: [NativeThreadBlock(kind: .thinking, text: "Checking the build output.")], status: "streaming"),
        ], olderCursor: "c:a1", earlierCount: 72)
        let request: NativeThreadStore.Request = { value in
            if case .subagentTranscript = value { return .transcript(value: page) }
            return .snapshot(value: snapshot)
        }
        let inspector = NativeInspectorState()
        inspector.runByAgent[AgentID(rawValue: "a")] = "native-worker"
        let content = NativeInspectorSplit(state: inspector, showInspector: true) {
            VStack(spacing: 0) {
                NativeThreadHeader(store: store, project: "Shepherd", title: "Investigate SwiftUI live preview capabilities", native: .constant(true), showTerminal: nil)
                DesktopNativeThreadView(store: store, active: true, isFocused: true, request: request, showTerminal: nil, agentName: "Investigate", inspectSubagent: { _ in })
            }
        } inspector: {
            NativeSubagentInspector(store: store, runID: "native-worker", active: true, close: {})
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
        // The board's nested children under the selected agent: worker 37m, reviewer needs you, tests done.
        vm.applyAgentChildren(agents[4].id, Self.boardRuns.prefix(3).map { run in
            var run = run
            let shift = Date().timeIntervalSince1970 * 1000 - Self.boardNow.timeIntervalSince1970 * 1000
            run.startedAt = run.startedAt.map { $0 + shift }
            run.endedAt = run.endedAt.map { $0 + shift }
            return run
        })
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
