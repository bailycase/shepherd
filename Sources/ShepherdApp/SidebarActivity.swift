import Foundation
import ShepherdCore
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
enum SidebarActivitySection: String, CaseIterable, Hashable {
    case pinned, needsYou, working, done, recents, designs

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .recents: "Recents"
        case .designs: "Designs"
        }
    }
}

/// A flat, stable-id lazy list. Folding removes rows, never the section's count.
enum SidebarActivityItem: Identifiable, Equatable {
    case header(SidebarActivitySection, count: Int, collapsed: Bool)
    case row(SidebarListRow)

    var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): AnyHashable(row.id)
        }
    }
}

extension SidebarLists {
    var sections: [(section: SidebarActivitySection, rows: [SidebarListRow])] {
        [(.pinned, pinned), (.needsYou, needsYou), (.working, working), (.done, done), (.recents, recents), (.designs, designs)]
    }

    func visibleRows(collapsed: Set<SidebarActivitySection>) -> [SidebarListRow] {
        sections.flatMap { collapsed.contains($0.section) ? [] : $0.rows }
    }

    func items(collapsed: Set<SidebarActivitySection>) -> [SidebarActivityItem] {
        sections.flatMap { section, rows -> [SidebarActivityItem] in
            guard !rows.isEmpty else { return [] }
            let folded = collapsed.contains(section)
            return [.header(section, count: rows.count, collapsed: folded)]
                + (folded ? [] : rows.map(SidebarActivityItem.row))
        }
    }
}

@MainActor
extension ShepherdViewModel {
    var sidebarActivityItems: [SidebarActivityItem] {
        presentedSidebarLists.items(collapsed: collapsedActivitySections)
    }

    func toggleActivitySection(_ section: SidebarActivitySection) {
        if collapsedActivitySections.contains(section) {
            collapsedActivitySections.remove(section)
        } else {
            collapsedActivitySections.insert(section)
        }
    }

    func openActivitySectionHoldingSelection() {
        guard sidebarStyle == .activity, let selected = selectedSidebarRow,
              let section = sidebarLists.sections.first(where: { $0.rows.contains { $0.id == selected } })?.section else { return }
        collapsedActivitySections.remove(section)
    }

    func recordSidebarActivity(_ id: AgentID, at now: Date = Date()) {
        let previous = sidebarActivityLast[id] ?? statusSince[id]
        sidebarActivityLast[id] = now
        guard let previous, now > previous else { return }
        sidebarActivitySamples[id] = Array(((sidebarActivitySamples[id] ?? [])
            + [1 / now.timeIntervalSince(previous)]).suffix(10))
    }

    /// Leaving for a page does not clear Done. Only opening another thread marks the current
    /// completion read; a later completion has a different generation.
    func willOpenSidebarThread(_ row: SidebarRowID) {
        let previous = sidebarReadingThread ?? selectedSidebarRow
        if let previous, previous != row, let completion = sidebarReadingCompletion {
            sidebarSeenCompletions[previous] = completion
        }
        sidebarReadingThread = row
        sidebarReadingCompletion = sidebarLists.all.first(where: { $0.id == row })?.completion
    }

    func markAllSidebarDoneSeen() {
        for row in sidebarLists.done {
            if let completion = row.completion { sidebarSeenCompletions[row.id] = completion }
        }
    }
}
