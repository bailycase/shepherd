import AppKit
import Observation
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdUI

/// The rendered sizing contract in docs/design/thread.md, not the choice of SwiftUI containers.
/// Accessibility supplies the card's actual frame; AppKit supplies its scrollable extent.
@Suite("Table sizing", .mainActorExclusive)
@MainActor
struct TableSizingTests {
    @Test func resizingKeepsWideTablesFittedAndNarrowTablesHorizontallyReachable() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.resizing() }
        }
        expectScenarioCompleted(result)
    }

    @Test func retainedTablesRemeasureContentAndProseSizeAndStillHugShortContent() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.changingContent() }
        }
        expectScenarioCompleted(result)
    }

    private static func resizing() async throws {
        AccessibilityNode.enable()
        let model = TableSizingModel(table: longTable)
        let window = OffscreenWindow(size: CGSize(width: 900, height: 600), dark: false, TableSizingView(model: model))
        defer { window.close() }
        let wide = try await geometry(window, matching: "wide columns to fit the offer") {
            $0.card.width > 850 && $0.card.width <= 901 && $0.overflow <= 1
        }
        window.window.setContentSize(CGSize(width: 180, height: 600))
        let narrow = try await geometry(window, matching: "narrow columns to retain a horizontal scroll extent") {
            $0.card.width > 0 && $0.card.width <= 181 && $0.overflow > 300
        }
        #expect(narrow.card.height > 0 && narrow.card.height < 600, "all rows keep their content height")
        let scroll = try #require(ListPerf.scrollView(in: window))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.width > scroll.contentView.bounds.width + 300)
        #expect(document.bounds.height > 0 && narrow.card.height >= document.bounds.height - 1,
                "horizontal overflow must not clip the table's rows vertically")
        let clip = scroll.contentView
        let before = clip.bounds.origin.x
        clip.scroll(to: clip.constrainBoundsRect(NSRect(
            origin: CGPoint(x: document.bounds.maxX, y: clip.bounds.origin.y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        window.layout()
        #expect(clip.bounds.origin.x > before + 100, "the hidden columns are actually reachable, not just oversized")

        window.window.setContentSize(CGSize(width: 900, height: 600))
        _ = try await geometry(window, matching: "the same table to fit again after widening") {
            abs($0.card.width - wide.card.width) <= 1 && abs($0.card.height - wide.card.height) <= 1 && $0.overflow <= 1
        }
        if let scroll = ListPerf.scrollView(in: window) {
            #expect(abs(scroll.contentView.bounds.origin.x) <= 1, "a fitted table must not retain the old horizontal offset")
        }
    }

    private static func changingContent() async throws {
        AccessibilityNode.enable()
        let words = table(["alphabetical", "considerable", "demonstration"])
        let model = TableSizingModel(table: words)
        let window = OffscreenWindow(size: CGSize(width: 900, height: 600), dark: true, TableSizingView(model: model))
        defer { window.close() }
        let regular = try await geometry(window, matching: "short content to hug its width") {
            $0.card.width > 100 && $0.card.width < 700 && $0.overflow <= 1
        }
        // Mutate one retained view model: never replace the hosting root or rekey the table.
        model.size = .small
        let small = try await geometry(window, matching: "the smaller prose size to remeasure the card") {
            $0.card.width < regular.card.width - 1 && $0.overflow <= 1
        }
        #expect(small.card.height <= regular.card.height)
        model.size = .regular
        _ = try await geometry(window, matching: "regular prose sizing to return") {
            abs($0.card.width - regular.card.width) <= 1 && abs($0.card.height - regular.card.height) <= 1 && $0.overflow <= 1
        }
        model.table = longTable
        _ = try await geometry(window, matching: "new content to grow and wrap within the offer") {
            $0.card.width > regular.card.width + 100 && $0.card.width <= 901
                && $0.card.height > regular.card.height + 10 && $0.overflow <= 1
        }
        model.table = words
        _ = try await geometry(window, matching: "short content to shrink again without stale measurements") {
            abs($0.card.width - regular.card.width) <= 1 && abs($0.card.height - regular.card.height) <= 1 && $0.overflow <= 1
        }
    }

    private static var longTable: SHProseTable {
        table(Array(repeating: String(repeating: "alpha beta gamma delta ", count: 6), count: 3))
    }

    private static func table(_ cells: [String]) -> SHProseTable {
        SHProseTable(alignments: [.leading, .center, .trailing], header: ["A", "B", "C"],
                     rows: [cells.map { AttributedString($0) }, cells.map { AttributedString($0) }], markdown: "")
    }

    private struct Geometry: Equatable {
        let card: CGRect
        let document: CGSize
        let viewport: CGSize
        var overflow: CGFloat { max(0, document.width - viewport.width) }
    }

    private static func geometry(_ window: OffscreenWindow, matching description: String,
                                 _ matches: (Geometry) -> Bool) async throws -> Geometry {
        var last: Geometry?
        var stable = 0
        try await eventuallyOnMain(description) {
            window.layout()
            guard let card = window.element("Table, 2 rows")?.frame, card.width > 0, card.height > 0 else { return false }
            let scroll = ListPerf.scrollView(in: window)
            let value = Geometry(card: card, document: scroll?.documentView?.bounds.size ?? card.size,
                                 viewport: scroll?.contentView.bounds.size ?? card.size)
            stable = matches(value) && value == last ? stable + 1 : 0
            last = value
            return stable >= 3
        }
        return try #require(last)
    }
}

@MainActor @Observable
fileprivate final class TableSizingModel {
    var table: SHProseTable
    var size = SHProseSize.regular
    init(table: SHProseTable) { self.table = table }
}

@MainActor
fileprivate struct TableSizingView: View {
    let model: TableSizingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHProseTableView(table: model.table)
                .equatable()
                .environment(\.shProseSize, model.size)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
