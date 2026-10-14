import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Subagents tab's controls (SubagentList board), pressed as VoiceOver presses them
/// (`ControlPress`): the tab in the strip, and a row. The board draws nothing else: a row is one button
/// that opens its run, whose controls are in the inspector. Each scenario runs in a process of its own,
/// since SwiftUI draws the accessibility tree only for a process an assistive client is attached to.
@Suite("Subagent list controls", .mainActorExclusive)
@MainActor
struct SubagentListControlTests {
    @Test func theTabIsPressedAndSaysItsCount() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressingTheTab() }
        }
        expectScenarioCompleted(result)
    }

    @Test func eachRowIsOneButtonThatOpensItsRunAloneAndTheListDrawsNothingElse() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressingRows() }
        }
        expectScenarioCompleted(result)
    }

    // MARK: Runs

    private static let worker = ChildRun(
        runID: "native-worker", label: "worker: restyle", state: "running", startedAt: 1_000, currentTool: "edit", role: "worker",
        lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/Thread.swift", at: 2_000),
        task: "Restyle the thread view.")
    private static let asked = ChildRun(
        runID: "native-reviewer", label: "reviewer: check", state: "running", startedAt: 1_000, needsAttention: true, role: "reviewer",
        lastActivity: ChildActivity(tool: "shepherd_parent_message", at: 2_000),
        question: ChildQuestion(text: "Rename the new token names, or replace the old ones everywhere?", options: []), task: "Check the work.")
    private static let done = ChildRun(
        runID: "native-tests", label: "tests: run", state: "complete", startedAt: 1_000, endedAt: 241_000, role: "tests",
        result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 4, tokens: 5), task: "Run the tests.", output: "Added 6 tests.")
    private static let stopped = ChildRun(
        runID: "native-docs", label: "docs: read", state: "stopped", startedAt: 1_000, endedAt: 99_000, role: "docs", task: "Read the docs.")

    /// A store serving `runs`.
    @MainActor
    private final class Thread {
        let store = NativeThreadStore()
        private var task: Task<Void, Never>?
        let runs: [ChildRun]

        init(runs: [ChildRun]) { self.runs = runs }

        func start() async throws {
            task = Task { [store, runs] in
                await store.run { _ in
                    .snapshot(value: NativeThreadSnapshot(
                        piSessionID: "s", generation: "g", revision: 1, running: true, supportedActions: ["send", "subagents"],
                        dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, subagents: runs))
                }
            }
            try await eventuallyOnMain("the thread to connect") { store.ready && store.subagents.count == runs.count }
        }

        func stop() {
            task?.cancel()
            store.stop()
        }
    }

    // MARK: The tab

    /// The Subagents tab sits after the Browser, selects itself when pressed, has a desktop hit area, and is not in the
    /// strip while the thread has no run. Its dot is a status the user decided on (blue still working, green done, red
    /// failed or stopped), read aloud with the count; pressing the tab leaves it, since it is not news; Changes and
    /// the Browser carry no status.
    @MainActor
    static func pressingTheTab() async throws {
        AccessibilityNode.enable()
        var selected: [String] = []
        func strip(_ subagents: (count: Int, status: AgentState)?) -> OffscreenWindow {
            OffscreenWindow(size: CGSize(width: 600, height: 60), dark: true, NWSidePaneTabs(
                SidePaneTabs.items(news: [], changedFiles: 5, subagents: subagents), selection: SidePaneTab.changes.rawValue,
                select: { selected.append($0) }, closeShortcut: "⇧⌘B", close: {}) {})
        }

        for (state, word) in [(AgentState.running, "Running"), (.done, "Done"), (.failed, "Failed")] {
            let window = strip((5, state))
            defer { window.close() }
            window.layout()
            let tab = try window.press("Subagents")
            #expect(tab.value == "5, \(word)", "its count and its status word are read aloud: \(String(describing: tab.value))")
            #expect(ControlPress.undersized([tab], minimum: .desktop).isEmpty, "the tab has a desktop hit area: \(tab)")
            #expect(window.controls().map(\.label).compactMap { $0 }.prefix(3) == ["Changes", "Browser", "Subagents"], "after the Browser")
            #expect(try window.press("Subagents").value == "5, \(word)", "pressing it again leaves the status as it was")
            #expect(window.controls().first { $0.label == "Changes" }?.value == "5", "Changes carries no status")
        }
        #expect(selected.count == 6 && selected.allSatisfy { $0 == SidePaneTab.subagents.rawValue }, "each press selects the tab: \(selected)")

        let none = strip(nil)
        defer { none.close() }
        none.layout()
        #expect(!none.controls().contains { $0.label == "Subagents" }, "no runs, no tab and no dot")
    }

    // MARK: Rows

    /// Every run is one button as tall as the board's 52pt, pressing it opens that run alone, and the list offers no
    /// other control: no Steer, Reply, Pause, Stop or Re-run, in the tree or as an action on a row.
    @MainActor
    static func pressingRows() async throws {
        AccessibilityNode.enable()
        let runs = [worker, asked, done, stopped]
        let thread = Thread(runs: runs)
        try await thread.start()
        defer { thread.stop() }
        var opened: [String] = []
        let window = OffscreenWindow(size: CGSize(width: 600, height: 520), dark: true,
                                     SubagentListTab(store: thread.store, inspect: { opened.append($0.runID) }))
        defer { window.close() }
        try await eventuallyOnMain("the list to draw its rows") { window.controls().contains { $0.label?.contains("worker") == true } }

        let rows = window.controls()
        #expect(rows.count == 4, "one button per run, and nothing else: \(rows)")
        #expect(ControlPress.undersized(rows, minimum: .desktop).isEmpty, "every row has a desktop hit area: \(rows)")
        #expect(rows.allSatisfy { $0.frame.height >= NWSubagentListMetrics.rowHeight - 1 }, "and is as tall as the board's: \(rows.map(\.frame))")

        for run in runs {
            let label = try #require(rows.first { $0.label?.contains(nativeRunNames(run).name) == true }?.label, "a row for \(run.runID): \(rows)")
            try window.press(label)
            #expect(opened.last == run.runID, "pressing \(run.runID)'s row opens it alone: \(opened)")
        }
        #expect(opened == runs.map(\.runID))

        for word in ["worker", "reviewer", "tests", "docs"] {
            #expect(ControlPress.actions(onLabelContaining: word, under: window.host).isEmpty, "\(word)'s row has no custom action")
        }
    }
}
