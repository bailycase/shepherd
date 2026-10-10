import Foundation
import ShepherdCore
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
enum SidebarActivitySection: String, CaseIterable, Hashable {
    case done, pinned, needsYou, working, recents, designs
    /// The new Projects (ProjectLead boards). Its rows are `SidebarLogicalProject`s, not thread rows.
    case projects

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .recents: "Recents"
        case .designs: "Designs"
        case .projects: "Projects"
        }
    }
}

/// A flat, stable-id lazy list. Folding removes rows, never the section's count.
enum SidebarActivityItem: Identifiable, Equatable {
    case header(SidebarActivitySection, count: Int, collapsed: Bool)
    case row(SidebarListRow)
    case project(SidebarLogicalProject)

    var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): AnyHashable(row.id)
        case .project(let project): AnyHashable(project.ref)
        }
    }
}

extension SidebarLists {
    /// The board's order (ProjectLead-Activity with the user's override): Designs first, then Needs you,
    /// Working, Done, Projects, Recents. Pinned is not drawn by the board; it is a state the user
    /// opts into, so it follows Done and never displaces a drawn group. Projects are not thread rows;
    /// `items(collapsed:projects:)` places them after Done and Pinned, before Recents.
    var sections: [(section: SidebarActivitySection, rows: [SidebarListRow])] {
        [(.designs, designs), (.needsYou, needsYou), (.working, working), (.done, done), (.pinned, pinned), (.recents, recents)]
    }

    func visibleRows(collapsed: Set<SidebarActivitySection>) -> [SidebarListRow] {
        sections.flatMap { collapsed.contains($0.section) ? [] : $0.rows }
    }

    func items(collapsed: Set<SidebarActivitySection>, projects: [SidebarLogicalProject] = [], showsProjects: Bool = true) -> [SidebarActivityItem] {
        func block(_ section: SidebarActivitySection, _ rows: [SidebarListRow]) -> [SidebarActivityItem] {
            guard !rows.isEmpty else { return [] }
            let folded = collapsed.contains(section)
            return [.header(section, count: rows.count, collapsed: folded)] + (folded ? [] : rows.map(SidebarActivityItem.row))
        }
        var items: [SidebarActivityItem] = []
        for (section, rows) in sections {
            // Projects sit between Done (and Pinned) and Recents, whether or not there are any: the
            // header and its New project chip are the way to make the first one.
            if section == .recents, showsProjects { items += projectBlock(projects, collapsed: collapsed) }
            items += block(section, rows)
        }
        if showsProjects, !sections.contains(where: { $0.section == .recents }) { items += projectBlock(projects, collapsed: collapsed) }
        return items
    }

    private func projectBlock(_ projects: [SidebarLogicalProject], collapsed: Set<SidebarActivitySection>) -> [SidebarActivityItem] {
        let folded = collapsed.contains(.projects)
        return [.header(.projects, count: projects.count, collapsed: folded)] + (folded ? [] : projects.map(SidebarActivityItem.project))
    }
}

@MainActor
extension ShepherdViewModel {
    var sidebarActivityItems: [SidebarActivityItem] {
        presentedSidebarLists.items(collapsed: collapsedActivitySections, projects: sidebarLogicalProjects, showsProjects: projectsEnabled)
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

    /// A command or rejected opening send may never report a turn. Drop the startup marker
    /// once the host has no pending message, using revision pushes rather than a polling loop.
    func reconcileSidebarOpeningTurn(_ id: AgentID) {
        guard sidebarOpeningTurns.contains(id), !sidebarPreparingOpeningTurns.contains(id) else { return }
        Task {
            guard case .snapshot(let snapshot) = try? await server.nativeThread(agentID: id, request: .snapshot()),
                  !snapshot.piSessionID.isEmpty, !snapshot.running,
                  !snapshot.messages.contains(where: { $0.status == "pending" }) else { return }
            sidebarOpeningTurns.remove(id)
        }
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
