import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

extension ShepherdViewModel {
    var supervisionQueues: SupervisionQueues<SidebarRowID> { sidebarLists.supervisionQueues }

    var nextNeedingYouRow: SidebarRowID? { supervisionQueues.nextNeedingYou(after: selectedSidebarRow) }

    func supervisionPaletteItems(keys: KeybindingsStore) -> [PaletteItem] {
        let queues = supervisionQueues
        var items: [PaletteItem] = []
        if queues.nextNeedingYou(after: selectedSidebarRow) != nil {
            items.append(PaletteItem(id: "action.nextNeedingYou", kind: .action("nextNeedingYou"), section: .commands,
                                     title: "Next needing you", shortcut: keys.display(.nextNeedingYou), icon: SHGlyph.nextThread.symbolName))
        }
        let count = queues.review.count
        if count > 0 {
            items.append(PaletteItem(id: "action.reviewNext", kind: .action("reviewNext"), section: .commands,
                                     title: "Review next", subtitle: "\(count) to review",
                                     shortcut: keys.display(.reviewNext), icon: SHGlyph.reviewQueue.symbolName))
        }
        return items
    }

    func openNextNeedingYou() {
        guard let nextNeedingYouRow else { return }
        selectSidebarRow(nextNeedingYouRow)
    }

    var reviewQueueCount: Int { supervisionQueues.review.count }

    func openReviewNext(excluding finished: SidebarRowID? = nil) {
        let queues = supervisionQueues
        // An explicit shortcut may reopen the current review when it's the only item left.
        guard let next = queues.nextReview(excluding: finished ?? selectedSidebarRow)
            ?? (finished == nil ? queues.nextReview() : nil) else { return }
        selectSidebarRow(next)
        guard selectedSidebarRow == next else { return }
        openUserReview()
        if let owner = sidePaneOwner, rightPaneContent == .review, subagentInspector.tab(for: owner) == .changes {
            queuedReview = next
        }
    }

    func advanceQueuedReview(for owner: SidePaneOwner?) {
        guard let owner, let queuedReview, selectedSidebarRow == queuedReview, sidePaneOwner == owner,
              rightPaneContent == .review, subagentInspector.tab(for: owner) == .changes else { return }
        self.queuedReview = nil
        openReviewNext(excluding: queuedReview)
    }
}
