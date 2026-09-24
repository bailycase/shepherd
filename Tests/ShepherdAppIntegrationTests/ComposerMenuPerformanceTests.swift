import AppKit
import Foundation
import QuartzCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's menus stay cheap over a full catalog (`ModelCatalogFixture`: hundreds of
/// models) and pi's full command list. Budgets are counted in rows drawn
/// (`NWMenuDiagnostics`, debug builds), which no machine's speed changes; the one timed budget
/// takes the best of several runs, so a busy machine only adds headroom.
@Suite("Composer menu performance", .serialized, .mainActorExclusive)
@MainActor
struct ComposerMenuPerformanceTests {
    /// The most rows the picker's list shows at once: its 360pt, all in 24pt headers.
    static let screenful = Int(NWComposerMetrics.modelPickerMaxHeight / NWComposerMetrics.menuHeaderHeight) + 1
    /// A lazy list builds what is on screen and a little beyond it.
    static let rowBudget = 2 * screenful

    @Test func openingTheModelPickerDrawsOnlyTheRowsOnScreen() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        NWMenuDiagnostics.rowBodies = 0

        thread.openModelPicker()
        try await thread.settle()

        #expect(NWMenuDiagnostics.rowBodies > 0, "the picker opened")
        #expect(NWMenuDiagnostics.rowBodies <= Self.rowBudget,
                "\(NWMenuDiagnostics.rowBodies) rows drawn for \(ModelCatalogFixture.entries.count) models")
    }

    /// Each keystroke in the search field draws the rows its results put on screen, not the
    /// catalog.
    @Test func filteringTheModelPickerDrawsOnlyTheRowsOnScreen() async throws {
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.openModelPicker()
        try await thread.settle()
        try #require(thread.focusedEditor != nil, "the search field has focus")

        var drawn: [Int] = []
        for step in ["g", "p", "t", "-", "5", "⌫", "⌫", "⌫", "⌫", "⌫", "q", "w", "⌫", "⌫"] {
            NWMenuDiagnostics.rowBodies = 0
            if step == "⌫" { thread.deleteBackward() } else { thread.type(step) }
            try await thread.settle()
            drawn.append(NWMenuDiagnostics.rowBodies)
        }

        #expect(drawn.contains { $0 > 0 }, "the results changed")
        #expect(drawn.allSatisfy { $0 <= Self.rowBudget }, "rows drawn per keystroke: \(drawn)")
    }

    /// Opening and closing the picker over a long thread take a few frames, not a few hundred
    /// milliseconds. Timed without motion, so the first frame is all of the work; the best of
    /// three, after a first open that warms up.
    @Test func openingAndClosingTheModelPickerTakeLittleTime() async throws {
        let thread = ComposerThread(animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let picker = CGRect(x: thread.columnLeading, y: 0, width: NWComposerMetrics.modelPickerWidth + 20, height: thread.cardTop)
        var opens: [Double] = [], closes: [Double] = []
        for _ in 0..<4 {
            let open = await FrameTimer.measure(thread.window, region: picker, stillFrames: 5) { thread.openModelPicker() }
            let close = await FrameTimer.measure(thread.window, region: picker, stillFrames: 5) { thread.openModelPicker() }
            opens.append(open.firstFrame ?? .infinity)
            closes.append(close.firstFrame ?? .infinity)
        }

        let bestOpen = opens.dropFirst().min() ?? .infinity, bestClose = closes.dropFirst().min() ?? .infinity
        #expect(bestOpen < Self.frameBudget, "open → first frame: \(opens.millisecondSummary)")
        #expect(bestClose < Self.frameBudget, "close → first frame: \(closes.millisecondSummary)")
    }

    /// Well over what the picker needs on a slow machine (about 15ms in a debug build here), and
    /// well under what a list that builds every row took (250ms and more).
    static let frameBudget = 0.12

    /// Scrolling the whole list under a still pointer: each row that passes under it takes the
    /// highlight (as `onHover` does). Only the rows scrolling in, and the two the highlight moves
    /// between, redraw; and the highlight never scrolls the list against the reader.
    @Test func scrollingUnderAStillPointerRedrawsOnlyWhatChanges() async throws {
        let model = HighlightModel()
        let window = OffscreenWindow(size: PickerHost.size, dark: false, PickerHost(model: model, sections: Self.sections))
        defer { window.close() }
        try await eventuallyOnMain("the list to load") { window.layout(); return Self.menuScroll(in: window) != nil }
        let scroll = try #require(Self.menuScroll(in: window))
        let clip = scroll.contentView
        let end = try #require(scroll.documentView).bounds.height - clip.bounds.height
        let step = 3 * NWComposerMetrics.menuRowHeight

        var drawn: [Int] = []
        var fought: [CGFloat] = []
        var y: CGFloat = 0
        while y <= end {
            NWMenuDiagnostics.rowBodies = 0
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            window.layout()
            // The pointer rests 100pt down the list: the model there takes the highlight.
            model.selection = Self.option(at: y + 100)
            window.layout()
            try? await Task.sleep(for: .milliseconds(1))
            window.layout()
            drawn.append(NWMenuDiagnostics.rowBodies)
            if abs(clip.bounds.origin.y - y) > 0.5 { fought.append(clip.bounds.origin.y - y) }
            y += step
        }

        #expect(drawn.count > 100, "scrolled through \(drawn.count) steps")
        #expect(drawn.allSatisfy { $0 <= 2 + 2 * Int(step / NWComposerMetrics.menuHeaderHeight) + 2 },
                "rows drawn per step: max \(drawn.max() ?? 0), total \(drawn.reduce(0, +))")
        #expect(fought.isEmpty, "the highlight moved the list \(fought.count) times")
    }

    /// A highlight moving in the slash menu (the pointer, ↑↓) redraws the two rows it moves
    /// between; ↑↓ past the visible rows still scroll the highlight into view.
    @Test func movingTheSlashMenusHighlightRedrawsTwoRows() async throws {
        let model = HighlightModel()
        let commands = ModelCatalogFixture.commands.map { NWSlashCommand(name: $0.name, description: $0.description, tag: $0.source) }
        let window = OffscreenWindow(size: CGSize(width: 520, height: 360), dark: false, SlashHost(model: model, commands: commands))
        defer { window.close() }
        try await eventuallyOnMain("the menu to load") { window.layout(); return Self.menuScroll(in: window) != nil }
        let clip = try #require(Self.menuScroll(in: window)).contentView

        var drawn: [Int] = []
        for index in 1...6 {
            NWMenuDiagnostics.rowBodies = 0
            model.selection = index
            window.layout()
            drawn.append(NWMenuDiagnostics.rowBodies)
        }
        #expect(drawn.allSatisfy { $0 <= 2 }, "rows drawn per move: \(drawn)")

        model.selection = 40
        try await eventuallyOnMain("↑↓ to scroll the highlight into view") {
            window.layout()
            return clip.bounds.origin.y >= 40 * NWComposerMetrics.menuRowHeight - clip.bounds.height
        }
    }

    // MARK: Fixtures

    /// The catalog as the picker lists it: one section per provider.
    static let sections: [NWModelSection] = {
        var order: [String] = []
        var byProvider: [String: [NWModelOption]] = [:]
        for entry in ModelCatalogFixture.entries {
            if byProvider[entry.provider] == nil { order.append(entry.provider) }
            byProvider[entry.provider, default: []].append(NWModelOption(id: entry.id, title: nativeModelShortName(entry.id), note: entry.context))
        }
        return order.map { NWModelSection(title: $0, options: byProvider[$0] ?? []) }
    }()

    /// The model at `y` down the list.
    static func option(at y: CGFloat) -> Int {
        var top: CGFloat = 0, position = 0
        for section in sections {
            top += NWComposerMetrics.menuHeaderHeight
            if y < top { return position }
            for _ in section.options {
                top += NWComposerMetrics.menuRowHeight
                if y < top { return position }
                position += 1
            }
        }
        return position - 1
    }

    static func menuScroll(in window: OffscreenWindow) -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)
    }
}

@MainActor @Observable
private final class HighlightModel {
    var query = ""
    var selection = 0
}

private struct PickerHost: View {
    static let size = CGSize(width: 340, height: 480)
    @Bindable var model: HighlightModel
    let sections: [NWModelSection]

    var body: some View {
        NWModelPicker(query: $model.query, sections: sections, selection: $model.selection, onChoose: { _ in }, onClose: {})
            .frame(width: Self.size.width, height: Self.size.height)
    }
}

private struct SlashHost: View {
    @Bindable var model: HighlightModel
    let commands: [NWSlashCommand]

    var body: some View {
        NWSlashMenu(commands: commands, total: commands.count, query: "", selection: $model.selection) { _ in }
            .frame(width: 520, height: 360)
    }
}
