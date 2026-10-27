import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import Testing
import ShepherdTestSupport
import ShepherdUI
@testable import ShepherdApp

extension ListPerformanceTests {
    /// The side pane's Subagents tab (SubagentList) with three hundred runs builds only the rows on screen,
    /// and a poll that changes one run redraws that row alone, not the list.
    @Test func theSubagentsTabBuildsOnlyTheRowsOnScreen() async throws {
        var runs: [ChildRun] = []
        for index in 0..<300 {
            runs.append(ChildRun(runID: "native-r\(index)", label: "worker-\(index): task", state: index < 3 ? "running" : "complete",
                                 startedAt: Double(1_000 + index), endedAt: index < 3 ? nil : Double(60_000 + index), role: "worker-\(index)",
                                 task: "Task number \(index) of the migration", output: "Did task \(index)."))
        }
        let store = NativeThreadStore()
        let snapshot = NativeThreadSnapshot(
            piSessionID: "s", generation: "g", revision: 1, running: false, supportedActions: ["send", "subagents"], dialogsSupported: true,
            dialogs: [], messages: [], provisional: [], clipped: false, subagents: runs)
        let task = Task { await store.run { _ in .snapshot(value: snapshot) } }
        let size = CGSize(width: 600, height: 520)
        let window = OffscreenWindow(size: size, dark: true, SubagentListTab(store: store, inspect: { _ in }))
        defer {
            task.cancel()
            store.stop()
            window.close()
        }
        // Counted from the empty list through the load: the rows exist only once the runs have arrived.
        SHRenderProbe.start()
        try await eventuallyOnMain("the thread to load") { store.ready && store.subagents.count == 300 }
        ListPerf.settle(window)
        let loaded = SHRenderProbe.stop()
        let onScreen = Int(size.height / SHSubagentListMetrics.rowHeight) + 1
        #expect(loaded["subagents.listRow", default: 0] > 0, "the rows drew: \(loaded)")
        #expect(loaded["subagents.listRow", default: 0] <= 2 * onScreen, "300 runs build only the rows on screen: \(loaded)")
    }
}
