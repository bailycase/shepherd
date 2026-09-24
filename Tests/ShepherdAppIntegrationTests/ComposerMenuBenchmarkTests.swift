import AppKit
import Foundation
import QuartzCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Prints what the composer's menus cost with a full catalog over a long thread: opening and
/// closing the model picker, each keystroke in its search, scrolling its whole list, a hover,
/// and the slash menu, with motion on and off. Opt-in, since it measures rather than checks
/// (`ComposerMenuPerformanceTests` holds the budgets):
///
///     SHEPHERD_BENCHMARK=1 swift test --filter ComposerMenuBenchmarkTests
@Suite("Composer menu benchmark", .serialized, .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_BENCHMARK"] != nil, "set SHEPHERD_BENCHMARK to measure"))
@MainActor
struct ComposerMenuBenchmarkTests {
    @Test(arguments: [true, false]) func report(animated: Bool) async throws {
        let thread = ComposerThread(animated: animated)
        print("BENCH ---- motion \(animated ? "on" : "off")")
        defer { thread.close() }
        try await thread.waitUntilReady()
        print("BENCH catalog \(ModelCatalogFixture.entries.count) models, \(ModelCatalogFixture.commands.count) commands")
        // Where the picker draws, fixed before it opens.
        let picker = CGRect(x: thread.columnLeading, y: 0, width: 280, height: thread.cardTop)
        var idle: [Double] = []
        for _ in 0..<10 { idle.append(FrameTimer.time(thread.window, region: picker) {}) }
        print("BENCH idle frame (layout + draw, no change): \(idle.millisecondSummary)")

        for round in 0..<2 {
            NWMenuDiagnostics.rowBodies = 0
            let insetBefore = thread.composerInset
            let open = await FrameTimer.measure(thread.window, region: picker) { thread.openModelPicker() }
            print("BENCH[\(round)] picker open: \(open) · rows drawn \(NWMenuDiagnostics.rowBodies) · inset \(insetBefore) → \(thread.composerInset)")

            var keystrokes: [Double] = []
            var rows: [Int] = []
            for letter in ["c", "l", "a", "u", "d", "e"] {
                NWMenuDiagnostics.rowBodies = 0
                let result = await FrameTimer.measure(thread.window, region: picker, stillFrames: 3, timeout: 2) { thread.type(letter) }
                keystrokes.append(result.firstFrame ?? .nan)
                rows.append(NWMenuDiagnostics.rowBodies)
            }
            for _ in 0..<6 {
                NWMenuDiagnostics.rowBodies = 0
                let result = await FrameTimer.measure(thread.window, region: picker, stillFrames: 3, timeout: 2) { thread.deleteBackward() }
                keystrokes.append(result.firstFrame ?? .nan)
                rows.append(NWMenuDiagnostics.rowBodies)
            }
            print("BENCH[\(round)] picker keystroke → frame: \(keystrokes.millisecondSummary) · rows drawn \(rows)")

            if let scroll = thread.menuScroll, let document = scroll.documentView {
                let clip = scroll.contentView
                let end = document.bounds.height - clip.bounds.height
                var steps: [Double] = []
                NWMenuDiagnostics.rowBodies = 0
                var y: CGFloat = 0
                while y <= end {
                    steps.append(FrameTimer.time(thread.window, region: picker) {
                        clip.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(clip)
                    })
                    try? await Task.sleep(for: .milliseconds(1))
                    y += 3 * NWComposerMetrics.menuRowHeight
                }
                print("BENCH[\(round)] picker scroll step (\(Int(end))pt): \(steps.millisecondSummary) · rows drawn \(NWMenuDiagnostics.rowBodies)")
            }

            let close = await FrameTimer.measure(thread.window, region: picker) { thread.openModelPicker() }
            print("BENCH[\(round)] picker close: \(close)")
            try await thread.settle()
        }

        // Slash menu.
        let slashRegion = CGRect(x: thread.columnLeading, y: 0, width: 460, height: thread.cardTop)
        NWMenuDiagnostics.rowBodies = 0
        let slash = await FrameTimer.measure(thread.window, region: slashRegion) { thread.openSlashMenu() }
        print("BENCH slash open: \(slash) · rows drawn \(NWMenuDiagnostics.rowBodies)")
        var slashKeys: [Double] = []
        var slashRows: [Int] = []
        for draft in ["/r", "/re", "/rev", "/revi", "/revie", "/review", "/revie", "/revi", "/rev", "/re", "/r", "/"] {
            NWMenuDiagnostics.rowBodies = 0
            let result = await FrameTimer.measure(thread.window, region: slashRegion, stillFrames: 3, timeout: 2) { thread.store.draft = draft }
            slashKeys.append(result.firstFrame ?? .nan)
            slashRows.append(NWMenuDiagnostics.rowBodies)
        }
        print("BENCH slash keystroke → frame: \(slashKeys.millisecondSummary) · rows drawn \(slashRows)")
        let slashClose = await FrameTimer.measure(thread.window, region: slashRegion) { thread.store.draft = "" }
        print("BENCH slash close: \(slashClose)")
    }

    /// What a hover costs: the pointer moving onto another row sets the highlight.
    @Test func hover() async throws {
        let options = ModelCatalogFixture.entries.map { NWModelOption(id: $0.id, title: $0.id, note: $0.context) }
        let sections = Dictionary(grouping: options) { String($0.id.prefix { $0 != "/" }) }.sorted { $0.key < $1.key }
            .map { NWModelSection(title: $0.key, options: $0.value) }
        let model = PickerModel()
        let window = OffscreenWindow(size: CGSize(width: 400, height: 520), dark: false, PickerHost(model: model, sections: sections))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        var times: [Double] = []
        var rows: [Int] = []
        for index in 1...12 {
            NWMenuDiagnostics.rowBodies = 0
            times.append(FrameTimer.time(window, region: CGRect(x: 0, y: 0, width: 400, height: 520)) { model.selection = index })
            rows.append(NWMenuDiagnostics.rowBodies)
            try? await Task.sleep(for: .milliseconds(1))
        }
        print("BENCH hover → frame: \(times.millisecondSummary) · rows drawn \(rows)")
    }
}

@MainActor @Observable private final class PickerModel {
    var query = ""
    var selection = 0
}

private struct PickerHost: View {
    @Bindable var model: PickerModel
    let sections: [NWModelSection]
    var body: some View {
        NWModelPicker(query: $model.query, sections: sections, selection: $model.selection, onChoose: { _ in }, onClose: {})
            .padding(40)
            .frame(width: 400, height: 520)
    }
}
