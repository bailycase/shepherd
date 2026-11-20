import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

extension ShepherdViewModel {
    var supervisionQueues: SupervisionQueues<SidebarRowID> {
        let lists = sidebarLists
        typealias Entry = SupervisionQueues<SidebarRowID>.Entry
        let localAgents = Dictionary(state.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteAgents = Dictionary(uniqueKeysWithValues: remoteHosts.connections.filter { $0.phase == .connected }.map { host in
            (host.id, Dictionary(host.state.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        })
        func entry(_ row: SidebarListRow, blocked: Bool) -> Entry? {
            guard !row.offline, let id = row.id.agentID else { return nil }
            let agent: Agent?
            let since: Double?
            switch row.id {
            case .local:
                agent = localAgents[id]
                since = statusSince[id].map { $0.timeIntervalSince1970 * 1000 }
            case .remote(let ref):
                agent = remoteAgents[ref.hostID]?[ref.agentID]
                since = nil
            default: return nil
            }
            guard let agent else { return nil }
            return Entry(row.id, since: (blocked ? since : agent.completedAt) ?? agent.lastActiveAt,
                         changedFiles: agent.checkout?.changedFiles ?? 0)
        }
        let blocked = lists.needsYou.compactMap { entry($0, blocked: true) }
        let done = lists.done.compactMap { entry($0, blocked: false) }
        if let cached = supervisionCache, cached.blocked == blocked, cached.done == done { return cached.queues }
        let queues = SupervisionQueues(blocked: blocked, unseenDone: done)
        supervisionCache = (blocked, done, queues)
        return queues
    }

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
