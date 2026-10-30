import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
enum SidebarActivitySection: String, CaseIterable, Hashable {
    case done, pinned, needsYou, working, recents, designs
    /// Active automations (This Mac's and each host's), one row each, with their run threads folded under them.
    case automations
    /// The new Projects (ProjectLead boards). Its rows are `SidebarLogicalProject`s, not thread rows.
    case projects
    /// Missions, one row each. A mission's planner, worker and validator threads are its own and
    /// never appear in the thread groups.
    case missions

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .recents: "Recents"
        case .designs: "Designs"
        case .automations: "Automations"
        case .projects: "Projects"
        case .missions: "Missions"
        }
    }
}

/// A flat, stable-id lazy list. Folding removes rows, never the section's count.
enum SidebarActivityItem: Identifiable, Equatable {
    case header(SidebarActivitySection, count: Int, collapsed: Bool)
    case row(SidebarListRow)
    /// An active automation in Automations; `expanded` is nil while it has no runs to fold.
    case automation(SidebarAutomation, expanded: Bool?)
    case project(SidebarLogicalProject)
    case mission(SidebarMission)

    var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): AnyHashable(row.id)
        case .automation(let automation, _): AnyHashable(automation.key)
        case .project(let project): AnyHashable(project.ref)
        case .mission(let mission): AnyHashable(mission.id)
        }
    }
}

/// A mission's sidebar row: its name, state dot and what it is doing or waiting on.
struct SidebarMission: Equatable, Identifiable {
    let id: MissionID
    let title: String
    let state: AgentState
    let word: String
    let needsYou: Bool
    var selected = false

    /// Waiting on you first, then working, then the rest; newest first within each.
    static func rows(_ missions: [Mission], selected: MissionID?) -> [SidebarMission] {
        let rows = missions.reversed().map { mission in
            let pill = mission.pill
            return SidebarMission(id: mission.id, title: mission.draft.title.isEmpty ? mission.draft.goal : mission.draft.title,
                                  // One short word, like a design's board count: amber already says it needs you.
                                  state: pill.state, word: String(pill.label.lowercased().split(separator: " · ").first ?? ""),
                                  needsYou: pill.state == .attention,
                                  selected: mission.id == selected)
        }
        func rank(_ row: SidebarMission) -> Int { row.needsYou ? 0 : row.state == .running ? 1 : 2 }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

extension SidebarLists {
    /// The user's order: Designs, Projects (and Missions), Automations, Needs you, Working, Done, Pinned, Recents.
    /// Pinned is opt-in and follows Done. Projects and Missions are not thread rows; `items` places them right after
    /// Designs, so thread status, attention and pins never move them. Automations' rows are its run threads, which
    /// `items` folds under `automationRows`.
    var sections: [(section: SidebarActivitySection, rows: [SidebarListRow])] {
        [(.designs, designs), (.automations, automations), (.needsYou, needsYou), (.working, working), (.done, done), (.pinned, pinned), (.recents, recents)]
    }

    /// `openRunGroups` holds the open automations' keys (`runGroupKey`); a closed one's runs aren't visible.
    func visibleRows(collapsed: Set<SidebarActivitySection>, openRunGroups: Set<String> = []) -> [SidebarListRow] {
        sections.flatMap { collapsed.contains($0.section) ? [] : $0.rows }
            .filter { row in row.foldedUnder.map { openRunGroups.contains(Self.runGroupKey($0)) } ?? true }
    }

    /// An Activity automation's open key, remembered beside the space tree's (`SidebarRunGroupRow.key`).
    static func runGroupKey(_ automation: AutomationKey) -> String {
        "runs.open:activity:\(automation.host.uuidString):\(automation.automation.rawValue)"
    }

    /// `selectedAutomation`: the automation the Automations page shows, marked on its row.
    func items(collapsed: Set<SidebarActivitySection>, openRunGroups: Set<String> = [], projects: [SidebarLogicalProject] = [],
               showsProjects: Bool = true, missions: [SidebarMission] = [], showsMissions: Bool = false,
               selectedAutomation: AutomationKey? = nil) -> [SidebarActivityItem] {
        func block(_ section: SidebarActivitySection, _ rows: [SidebarListRow]) -> [SidebarActivityItem] {
            guard !rows.isEmpty else { return [] }
            let folded = collapsed.contains(section)
            return [.header(section, count: rows.count, collapsed: folded)] + (folded ? [] : rows.map(SidebarActivityItem.row))
        }
        var items: [SidebarActivityItem] = []
        for (section, rows) in sections {
            if section == .automations {
                items += automationBlock(collapsed: collapsed, openRunGroups: openRunGroups, selected: selectedAutomation)
                continue
            }
            items += block(section, rows)
            // Projects follow Designs and sit above every thread group, whether or not there are any: the header and its
            // New project chip are the way to make the first one.
            if section == .designs, showsProjects { items += projectBlock(projects, collapsed: collapsed) }
            if section == .designs, showsMissions { items += missionBlock(missions, collapsed: collapsed) }
        }
        return items
    }

    /// One row per active automation, its runs under it while open; omitted while none is active.
    private func automationBlock(collapsed: Set<SidebarActivitySection>, openRunGroups: Set<String>,
                                 selected: AutomationKey?) -> [SidebarActivityItem] {
        guard !automationRows.isEmpty else { return [] }
        let folded = collapsed.contains(.automations)
        var items: [SidebarActivityItem] = [.header(.automations, count: automationRows.count, collapsed: folded)]
        guard !folded else { return items }
        let runs = Dictionary(grouping: automations, by: \.foldedUnder)
        for var automation in automationRows {
            automation.selected = automation.key == selected
            let open = openRunGroups.contains(Self.runGroupKey(automation.key))
            items.append(.automation(automation, expanded: automation.runs > 0 ? open : nil))
            if open { items += (runs[automation.key] ?? []).map(SidebarActivityItem.row) }
        }
        return items
    }

    /// Missions sit with Projects, above every thread group: the header (and its New mission) even before
    /// the first one, as Projects'.
    private func missionBlock(_ missions: [SidebarMission], collapsed: Set<SidebarActivitySection>) -> [SidebarActivityItem] {
        let folded = collapsed.contains(.missions)
        return [.header(.missions, count: missions.count, collapsed: folded)] + (folded ? [] : missions.map(SidebarActivityItem.mission))
    }

    private func projectBlock(_ projects: [SidebarLogicalProject], collapsed: Set<SidebarActivitySection>) -> [SidebarActivityItem] {
        let folded = collapsed.contains(.projects)
        return [.header(.projects, count: projects.count, collapsed: folded)] + (folded ? [] : projects.map(SidebarActivityItem.project))
    }
}

@MainActor
extension ShepherdViewModel {
    var sidebarActivityItems: [SidebarActivityItem] {
        presentedSidebarLists.items(collapsed: collapsedActivitySections, openRunGroups: collapsedProjects,
                                    projects: sidebarLogicalProjects, showsProjects: projectsEnabled,
                                    missions: sidebarMissions, showsMissions: settings.missionsEnabled,
                                    selectedAutomation: shownDestination == .automations ? automationsPageSelection : nil)
    }

    /// The Missions section's rows, shared by every sidebar style.
    var sidebarMissions: [SidebarMission] {
        // Hidden with the experiment; the missions and their receipts stay.
        guard settings.missionsEnabled else { return [] }
        return SidebarMission.rows(state.missions, selected: shownDestination == .missions ? missions.selectedID : nil)
    }

    /// A mission's sidebar row: the Missions page on that mission.
    func openMission(_ id: MissionID) {
        guard settings.missionsEnabled else { return }
        missions.selectedID = id
        openDestination(.missions)
    }

    /// The Missions section's "New mission": the Missions page's start page.
    func openNewMission() {
        guard settings.missionsEnabled else { return }
        missions.selectedID = nil
        missionStartRequested = true
        openDestination(.missions)
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
        // Selecting a run opens its group.
        if let automation = sidebarLists.automations.first(where: { $0.id == selected })?.foldedUnder {
            let key = SidebarLists.runGroupKey(automation)
            if !collapsedProjects.contains(key) { collapsedProjects.insert(key) }
        }
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
        let box = sidebarActivityBox(id)
        box.samples = Array((box.samples + [1 / now.timeIntervalSince(previous)]).suffix(10))
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

/// One agent's activity samples (`ShepherdViewModel.sidebarActivityBoxes`): its row reads this
/// box's `samples`, never the dictionary of every agent's.
@MainActor @Observable
final class SidebarActivityBox {
    var samples: [Double] = []
}
