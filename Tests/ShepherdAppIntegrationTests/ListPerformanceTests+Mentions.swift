import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// The composer's @ picker (MentionPicker): a board of 300 elements builds only the rows on
/// screen, and a highlight moving redraws only the rows it leaves and lands on.
extension ListPerformanceTests {
    @MainActor @Observable
    final class MentionHighlight {
        var id: String?
    }

    private struct MentionPickerHost: View {
        let content: MentionPickerContent
        let highlight: MentionHighlight

        var body: some View {
            NWMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: highlight.id,
                            maxHeight: 600, choose: { _ in }, drill: { _ in })
                .frame(width: 820)
        }
    }

    /// A board of `count` elements, inside it as the picker lists it.
    private static func boardOfElements(_ count: Int) -> MentionPickerContent {
        let design = DesignID(rawValue: "checkout")
        let board = DesignReference(designID: design, board: DesignPath("A.dc.html")!)!
        let designItem = DesignMentionItem(kind: .design, reference: DesignReference(designID: design, board: nil)!, title: "Checkout",
                                           breadcrumb: [], boardCount: 1)
        let boardItem = DesignMentionItem(kind: .board, reference: board, title: "A · Funnel first", breadcrumb: ["Checkout"],
                                          width: 1280, height: 800, elementCount: count)
        let elements = (0..<count).map { index in
            DesignMentionItem(kind: .element,
                              reference: DesignReference(designID: design, board: board.board,
                                                         element: DesignElementID(board: "A.dc.html", tid: index + 3, path: [1, index / 50, index % 50])!)!,
                              title: "card “Step \(index)”", breadcrumb: ["Checkout", "A · Funnel first"], tag: "div", inside: 3)
        }
        let catalog = DesignMentionCatalog(designs: [designItem], boards: [design: [boardItem]], elements: [board.string: elements])
        return MentionPickerContent.make(catalog: catalog, scope: .board(board, design: "Checkout", board: "A · Funnel first"), filter: "")
    }

    @Test func openingThePickerOverABoardOfThreeHundredElementsBuildsOnlyTheRowsOnScreen() throws {
        let content = Self.boardOfElements(DesignMentionCatalog.maxElementsPerBoard)
        #expect(content.rows.count == DesignMentionCatalog.maxElementsPerBoard + 1)
        let highlight = MentionHighlight()
        highlight.id = content.rows.first?.id
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true, MentionPickerHost(content: content, highlight: highlight))
            ListPerf.settle(window)
        }
        defer { window.close() }
        // At most eight rows show; each may be built twice while the list settles.
        #expect(rows["mention.row", default: 0] <= 2 * (NWMentionMetrics.maxRows + 2), "\(rows)")
    }

    @Test func movingThePickersHighlightRedrawsOnlyTheRowsItLeavesAndLandsOn() throws {
        let content = Self.boardOfElements(DesignMentionCatalog.maxElementsPerBoard)
        let highlight = MentionHighlight()
        let ids = content.rows.map(\.id)
        highlight.id = ids[0]
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true, MentionPickerHost(content: content, highlight: highlight))
        defer { window.close() }
        ListPerf.settle(window)

        let rows = ListPerf.counting {
            for index in 1...20 { _ = ListPerf.time(window) { highlight.id = ids[index] } }
        }
        // Two rows per move, plus the rows the highlight scrolls into view.
        #expect(rows["mention.row", default: 0] <= 20 * 2 + NWMentionMetrics.maxRows + 20, "\(rows)")
    }
}
