import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Subagents tab inside the real workspace (SubagentList board): a row opens its run in the inspector over
/// the pane, and the inspector's Close puts the pane back on the tab it was on, pressed as VoiceOver presses
/// them (`ControlPress`) in a process of its own.
@Suite("Subagent list in the workspace", .mainActorExclusive)
@MainActor
struct SubagentListFlowTests {
    @Test func aRowOpensTheInspectorAndCloseReturnsToTheSubagentsTab() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.openingAndClosing() }
        }
        expectScenarioCompleted(result)
    }

    private static let worker = ChildRun(
        runID: "native-worker", label: "worker: restyle", state: "running", startedAt: 1_000, currentTool: "edit", role: "worker",
        lastActivity: ChildActivity(kind: ChildActivity.runningKind, tool: "edit", preview: "Sources/Thread.swift", at: 2_000),
        task: "Restyle the thread view.")
    private static let done = ChildRun(
        runID: "native-tests", label: "tests: run", state: "complete", startedAt: 1_000, endedAt: 241_000, role: "tests",
        result: ChildResultSummary(files: 2, added: 96, removed: 3, tools: 4, tokens: 5), task: "Run the tests.", output: "Added 6 tests.")

    static func openingAndClosing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("parent", in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let id = agent.agent.id
        let runs = [worker, done]
        let store = NativeThreadStore()
        vm.threadStores.install(store, for: id)
        let polling = Task {
            await store.run { request in
                if case .subagentTranscript(_, let runID, _) = request {
                    return .transcript(value: NativeSubagentTranscript(runID: runID, messages: []))
                }
                return .snapshot(value: NativeThreadSnapshot(
                    piSessionID: "s", generation: "g", revision: 1, running: true, supportedActions: ["send", "subagents"],
                    dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, subagents: runs))
            }
        }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to carry its runs") { store.ready && store.subagents.count == 2 }

        vm.selectAgent(id)
        let window = OffscreenWindow(size: CGSize(width: 1500, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let owner = SidePaneOwner.local(id)

        // The strip carries the tab once the thread has a run; pressing it shows the list.
        vm.showSidePane(owner)
        try await eventuallyOnMain("the strip to draw the Subagents tab") { window.controls().contains { $0.label == "Subagents" } }
        let tab = try window.press("Subagents")
        #expect(tab.value == "2, Running", "its count and its status, blue while the worker works: \(String(describing: tab.value))")
        #expect(vm.subagentInspector.tab(for: owner) == .subagents, "pressing the tab shows it")
        try await eventuallyOnMain("the list to draw its rows") { window.controls().contains { $0.label?.contains("tests") == true } }
        #expect(vm.subagentInspector.run(for: owner) == nil)

        // Open the running worker. The thread's own tray draws a row for it too, so the list's is the one in the pane:
        // 600pt wide and as tall as the board's 52pt.
        func listRows() -> [Control] {
            window.controls().filter { $0.label?.contains("Opens the run") != true && abs($0.frame.height - SHSubagentListMetrics.rowHeight) < 1.5
                && abs($0.frame.width - 600) < 1.5 && $0.label?.contains("worker") == true }
        }
        let rows = listRows()
        #expect(rows.count == 1, "one list row for the worker: \(window.controls())")
        let row = try #require(rows.first)
        #expect(row.node.press(), "the row takes the press")
        #expect(vm.subagentInspector.run(for: owner) == "native-worker", "the row opened its run alone")
        try await eventuallyOnMain("the inspector to replace the list") { window.controls().contains { $0.label == "Close inspector" } }
        #expect(listRows().isEmpty, "the list is covered while the run is inspected")

        // Close returns to the list, on the same tab, with the same rows.
        try window.press("Close inspector")
        #expect(vm.subagentInspector.run(for: owner) == nil, "the inspector is closed")
        #expect(vm.subagentInspector.tab(for: owner) == .subagents && vm.subagentInspector.open.contains(owner), "the pane is back on Subagents")
        #expect(window.controls().first { $0.label == "Subagents" }?.value == "2, Running", "viewing the tab, opening a run and closing it left the status")
        try await eventuallyOnMain("the list to come back") { listRows().count == 1 }
        #expect(window.controls().contains { $0.label?.contains("tests") == true }, "both runs are listed again")
    }
}
