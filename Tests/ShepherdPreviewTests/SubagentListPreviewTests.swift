import AppKit
import Foundation
import ShepherdCore
@testable import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The side pane's Subagents tab (SubagentList board) in light and dark at text scale 1 and 1.3, drawn
/// from a real `NativeThreadStore` fed a snapshot, through the same strip and list the workspace draws:
/// the board's five runs (running, waiting on its parent, done, a finished earlier pair), a thread of
/// finished runs, none at all, and names and questions three times as long as the board's. See
/// `PreviewTests` for how previews run.
@Suite("Subagent list previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SubagentListPreviewTests {
    private static var now: Double { Date().timeIntervalSince1970 * 1000 }

    /// The board's runs, retimed to now so the figures read like its ("37m", "2m", "4m", "6m", "20m").
    private static var board: [ChildRun] {
        let now = now
        let turn = now - 37 * 60_000
        let earlier = now - 3 * 3_600_000
        return [
            ChildRun(runID: "native-worker", label: "worker: restyle", state: "running", startedAt: turn, currentTool: "edit", role: "worker",
                     lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/ShepherdRemote/NativeThreadPresentation.swift",
                                                 at: now - 4000),
                     task: "Restyle the desktop native thread view to match the spec",
                     files: [ChildFileChange(path: "Sources/ShepherdRemote/NativeThreadPresentation.swift", added: 31, removed: 4)]),
            ChildRun(runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: now - 30 * 60_000, needsAttention: true, role: "reviewer",
                     lastActivity: ChildActivity(tool: "shepherd_parent_message", at: now - 2 * 60_000),
                     question: ChildQuestion(text: "Rename the new token names, or replace the old ones everywhere?", options: ["Replace everywhere"]),
                     task: "check"),
            ChildRun(runID: "native-tests", label: "tests: run", state: "complete", startedAt: now - 8 * 60_000, endedAt: now - 4 * 60_000, role: "tests",
                     result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 4, tokens: 5), task: "run",
                     output: "Added 6 presentation tests · 14 pass."),
            ChildRun(runID: "native-scout", label: "scout: find", state: "complete", startedAt: earlier, endedAt: earlier + 6 * 60_000, role: "scout",
                     task: "Find every place the thread view sets a font", output: "41 call sites in 9 files."),
            ChildRun(runID: "native-researcher", label: "researcher: read", state: "stopped", startedAt: earlier + 10 * 60_000,
                     endedAt: earlier + 30 * 60_000, role: "researcher", exitReason: "Stopped: hit its 20-minute limit",
                     task: "Read the SwiftUI preview docs"),
        ]
    }

    /// A parent whose last turn spawned the first three.
    private static func snapshot(_ runs: [ChildRun], recent: [String], running: Bool = true) -> NativeThreadSnapshot {
        func spawn(_ id: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "{\"id\":\"native-\(id)\"}")],
                                toolName: "shepherd_child_start", toolCallID: "spawn-\(id)", argumentsText: "{\"task\":\"\(id)\",\"role\":\"\(id)\"}", status: "complete")
        }
        var runs = runs
        for index in runs.indices { runs[index].toolCallID = "spawn-" + runs[index].runID.replacingOccurrences(of: "native-", with: "") }
        return NativeThreadSnapshot(
            piSessionID: "fixture", generation: "g", revision: 1, running: running, model: "anthropic/claude-opus-4-5", thinking: "high",
            supportedActions: ["send", "abort", "subagents"], dialogsSupported: true, dialogs: [],
            messages: [NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Restyle the native UI.")],
                                           timestamp: now - 40 * 60_000)] + recent.map(spawn),
            provisional: [], clipped: false, runtime: "rpc", subagents: runs)
    }

    /// The strip over the list, as the workspace composes the pane's Subagents tab.
    private struct Pane: View {
        let store: NativeThreadStore
        /// The pane's own size: the workspace frames it, and an empty list would otherwise ask for its flexible height.
        let size: CGSize
        var body: some View {
            VStack(spacing: 0) {
                SHSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 5, subagents: SidePaneTabs.subagents(store.subagents)),
                               selection: SidePaneTab.subagents.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {}
                SubagentListTab(store: store, inspect: { _ in })
            }
            .frame(width: size.width, height: size.height)
            .background(Color.sh.bgWindow)
        }
    }

    private func render(_ surface: String, _ snapshot: NativeThreadSnapshot, size: CGSize = CGSize(width: 600, height: 560)) async throws {
        let store = NativeThreadStore()
        let task = Task { await store.run { _ in .snapshot(value: snapshot) } }
        defer { task.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to load") { store.ready && store.subagents.count == (snapshot.subagents ?? []).count }
        try await Preview.renderMatrix(surface, size: size) { Pane(store: store, size: size) }
    }

    @Test func theBoardsFiveRuns() async throws {
        try await render("subagent-list-board", Self.snapshot(Self.board, recent: ["worker", "reviewer", "tests"]), size: CGSize(width: 600, height: 410))
    }

    @Test func aThreadWhoseRunsAllFinished() async throws {
        let runs = Self.board.filter { $0.state != "running" }
        try await render("subagent-list-finished", Self.snapshot(runs, recent: ["tests"], running: false), size: CGSize(width: 600, height: 300))
    }

    @Test func aThreadWithNoRunsYet() async throws {
        try await render("subagent-list-empty", Self.snapshot([], recent: [], running: false), size: CGSize(width: 600, height: 300))
    }

    @Test func longNamesQuestionsAndFailuresTruncateAtTheTail() async throws {
        var runs = Self.board
        runs[0].task = "Restyle the desktop native thread view, the sidebar, the composer and every settings page to match the design spec, system fonts at the spec's sizes"
        runs[0].role = "worker-with-a-very-long-role-name"
        runs[1].question = ChildQuestion(text: "Two token names collide with the existing text secondary token, and a third shadows the tertiary one. Rename the new token names, or replace the old ones everywhere in the app and in the iOS client as well?", options: [])
        runs[4].exitReason = "exit 1 · context limit reached after 41 turns while reading the SwiftUI preview documentation for the design spec"
        runs[4].state = "failed"
        try await render("subagent-list-long", Self.snapshot(runs, recent: ["worker", "reviewer", "tests"]), size: CGSize(width: 600, height: 410))
    }

    @Test func aTabWithEveryRunLiveAndALongList() async throws {
        var runs: [ChildRun] = []
        for index in 0..<14 {
            var run = Self.board[index % 3]
            run.runID = "native-r\(index)"
            run.label = "worker-\(index): task"
            run.role = "worker-\(index)"
            run.task = "Task number \(index) of the migration"
            runs.append(run)
        }
        try await render("subagent-list-many", Self.snapshot(runs, recent: ["r0", "r1", "r2"]), size: CGSize(width: 600, height: 560))
    }

    // MARK: The tab's status dot

    /// The strip with each status the thread's real runs produce (`SidePaneTabs.subagents`), and the agent's own news dot
    /// on Changes and Browser beside it: working (blue), every run done (green), a stopped or failed run (red), and no runs.
    private struct Strips: View {
        let rows: [(String, [ChildRun])]
        var body: some View {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    SHSidePaneTabs(SidePaneTabs.items(news: index == 4 ? [.changes, .browser] : [], changedFiles: 5,
                                                      subagents: SidePaneTabs.subagents(rows[index].1)),
                                   selection: index % 2 == 0 ? SidePaneTab.subagents.rawValue : SidePaneTab.changes.rawValue,
                                   select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {}
                }
            }
            .background(Color.sh.bgWindow)
        }
    }

    @Test func theStatusDotInEveryState() async throws {
        let board = Self.board
        let working = board                                           // live, waiting on its parent, done, done, stopped
        let allDone = board.filter { $0.state == "complete" }         // none live, none failed
        let stopped = board.filter { $0.state != "running" }          // done and stopped, none live
        let rows: [(String, [ChildRun])] = [("working", working), ("allDone", allDone), ("stopped", stopped), ("none", []),
                                            ("news", allDone)]
        try await Preview.renderMatrix("subagent-list-status", size: CGSize(width: 600, height: 44 * CGFloat(rows.count))) { Strips(rows: rows) }
    }
}
