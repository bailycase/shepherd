import Foundation
import ShepherdCore
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
enum SidebarActivitySection: String, CaseIterable, Hashable {
    case done, pinned, needsYou, working, recents, designs
    /// Runs of automations (This Mac's and each host's) that are not waiting on the user: they never mix with threads.
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
    case project(SidebarLogicalProject)
    case mission(SidebarMission)

    var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): AnyHashable(row.id)
        case .project(let project): AnyHashable(project.ref)
        case .mission(let mission): AnyHashable(mission.id)
        }
    }
}

/// A mission's sidebar row: its name, state dot and what it is doing or waiting on.
struct SidebarMission: Equatable, Identifiable {
    let mission: MissionID
    let title: String
    let state: AgentState
    let word: String
    let needsYou: Bool
    var selected = false
    /// The connected host it runs on; nil is This Mac.
    var host: UUID? = nil
    var id: String { "\(host?.uuidString ?? "local")/\(mission.rawValue)" }

    /// Waiting on you first, then working, then the rest; newest first within each. A host's
    /// missions name it after their word.
    static func rows(_ missions: [Mission], selected: MissionID?, host: (id: UUID, name: String)? = nil) -> [SidebarMission] {
        let rows = missions.reversed().map { mission in
            let pill = mission.pill
            let word = String(pill.label.lowercased().split(separator: " · ").first ?? "")
            return SidebarMission(mission: mission.id, title: mission.draft.title.isEmpty ? mission.draft.goal : mission.draft.title,
                                  // One short word, like a design's board count: amber already says it needs you.
                                  state: pill.state, word: host.map { "\(word) · \($0.name)" } ?? word,
                                  needsYou: pill.state == .attention,
                                  selected: mission.id == selected, host: host?.id)
        }
        func rank(_ row: SidebarMission) -> Int { row.needsYou ? 0 : row.state == .running ? 1 : 2 }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

extension SidebarLists {
    /// The user's order: Automations, Designs, Projects, Needs you, Working, Done, Pinned, Recents.
    /// Pinned is opt-in and follows Done. Projects are not thread rows; `items(collapsed:projects:)`
    /// places their group right after Designs, so thread status, attention and pins never move it.
    var sections: [(section: SidebarActivitySection, rows: [SidebarListRow])] {
        [(.automations, automations), (.designs, designs), (.needsYou, needsYou), (.working, working), (.done, done), (.pinned, pinned), (.recents, recents)]
    }

    func visibleRows(collapsed: Set<SidebarActivitySection>) -> [SidebarListRow] {
        sections.flatMap { collapsed.contains($0.section) ? [] : $0.rows }
    }

    func items(collapsed: Set<SidebarActivitySection>, projects: [SidebarLogicalProject] = [], showsProjects: Bool = true,
               missions: [SidebarMission] = [], showsMissions: Bool = false) -> [SidebarActivityItem] {
        func block(_ section: SidebarActivitySection, _ rows: [SidebarListRow]) -> [SidebarActivityItem] {
            guard !rows.isEmpty else { return [] }
            let folded = collapsed.contains(section)
            return [.header(section, count: rows.count, collapsed: folded)] + (folded ? [] : rows.map(SidebarActivityItem.row))
        }
        var items: [SidebarActivityItem] = []
        for (section, rows) in sections {
            items += block(section, rows)
            // Projects follow Designs and sit above every thread group, whether or not there are any: the header and its
            // New project chip are the way to make the first one.
            if section == .designs, showsProjects { items += projectBlock(projects, collapsed: collapsed) }
            if section == .designs, showsMissions { items += missionBlock(missions, collapsed: collapsed) }
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
        presentedSidebarLists.items(collapsed: collapsedActivitySections, projects: sidebarLogicalProjects, showsProjects: projectsEnabled,
                                    missions: sidebarMissions, showsMissions: settings.missionsEnabled)
    }

    /// The Missions section's rows, shared by every sidebar style.
    var sidebarMissions: [SidebarMission] {
        // Hidden with the experiment; the missions and their receipts stay.
        guard settings.missionsEnabled else { return [] }
        let shown = shownDestination == .missions
        let local = SidebarMission.rows(state.missions, selected: shown && missionsHost == nil ? missions.selectedID : nil)
        // Each connected host's missions (`missions.v1`), in configured order, after This Mac's.
        return local + remoteHosts.connections.flatMap { connection in
            SidebarMission.rows(connection.missions.records,
                                selected: shown && missionsHost == connection.id ? remoteMissionDrivers[connection.id]?.selectedID : nil,
                                host: (connection.id, connection.config.name))
        }
    }

    /// A host's missions behind the Missions page, made on first use; nil for a host that is gone.
    func missionDriver(for host: UUID) -> RemoteMissionDriver? {
        if let driver = remoteMissionDrivers[host] { return driver }
        guard let connection = remoteHosts.connections.first(where: { $0.id == host }) else { return nil }
        let driver = RemoteMissionDriver(connection: connection, vm: self)
        remoteMissionDrivers[host] = driver
        return driver
    }

    /// A mission's sidebar row: the Missions page on that mission, on This Mac or `host`.
    func openMission(_ id: MissionID, host: UUID? = nil) {
        guard settings.missionsEnabled else { return }
        if let host {
            guard let driver = missionDriver(for: host) else { return }
            driver.selectedID = id
        } else {
            missions.selectedID = id
        }
        missionsHost = host
        openDestination(.missions)
    }

    /// The Missions section's "New mission": the Missions page's start page, on This Mac.
    func openNewMission() {
        guard settings.missionsEnabled else { return }
        missions.selectedID = nil
        missionsHost = nil
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
