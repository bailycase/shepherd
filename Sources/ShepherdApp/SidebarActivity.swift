import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
enum SidebarActivitySection: String, CaseIterable, Hashable {
    case done, pinned, needsYou, working, recents, designs
    /// Active automations (This Mac's and each host's), one row each, with their run threads folded under them.
    case automations
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
        case .automations: "Automations"
        case .projects: "Projects"
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
    /// A pull request or issue pinned from Issues & PRs, in Pinned (PRSidebarPinned).
    case forgePin(SidebarForgePin)

    var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): AnyHashable(row.id)
        case .automation(let automation, _): AnyHashable(automation.key)
        case .project(let project): AnyHashable(project.ref)
        case .forgePin(let pin): AnyHashable(pin.ref)
        }
    }
}

extension SidebarLists {
    /// The user's order: Designs, Projects, Automations, Needs you, Working, Done, Pinned, Recents.
    /// Pinned is opt-in and follows Done. Projects are not thread rows; `items` places them right after
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
               showsProjects: Bool = true,
               selectedAutomation: AutomationKey? = nil, forgePins: [SidebarForgePin] = []) -> [SidebarActivityItem] {
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
            // Pinned threads, then pinned pull requests and issues, under one header.
            if section == .pinned, !forgePins.isEmpty {
                let folded = collapsed.contains(.pinned)
                items.append(.header(.pinned, count: rows.count + forgePins.count, collapsed: folded))
                if !folded { items += rows.map(SidebarActivityItem.row) + forgePins.map(SidebarActivityItem.forgePin) }
                continue
            }
            items += block(section, rows)
            // Projects follow Designs and sit above every thread group, whether or not there are any: the header and its
            // New project chip are the way to make the first one.
            if section == .designs, showsProjects { items += projectBlock(projects, collapsed: collapsed) }
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

    private func projectBlock(_ projects: [SidebarLogicalProject], collapsed: Set<SidebarActivitySection>) -> [SidebarActivityItem] {
        let folded = collapsed.contains(.projects)
        return [.header(.projects, count: projects.count, collapsed: folded)] + (folded ? [] : projects.map(SidebarActivityItem.project))
    }
}

/// When each agent's sparkline may next be published: at most every `interval`, the first sample at once, and a
/// sample that comes early held until the interval is up so the newest always lands. It keeps no clock: the times
/// are the events' own (`ShepherdViewModel.recordSidebarActivity`), so a burst of tool finishes draws a row a few
/// times a second, not once per tool.
struct ActivityPacing {
    static let interval: TimeInterval = 0.25
    /// How long past its deadline a flush waits, so the agents whose deadlines fall a few milliseconds apart publish
    /// in one pass of the sidebar, not one pass each.
    static let coalescing: TimeInterval = 0.025

    private var published: [AgentID: Date] = [:]
    private var held: [AgentID: [Double]] = [:]

    /// The samples to publish now, or nil while they wait for `due`.
    mutating func record(_ id: AgentID, samples: [Double], at now: Date) -> [Double]? {
        if let last = published[id], now.timeIntervalSince(last) < Self.interval {
            held[id] = samples
            return nil
        }
        published[id] = now
        held[id] = nil
        return samples
    }

    /// The held samples whose interval is up at `now`, now published, and when the next held ones are due.
    mutating func due(at now: Date) -> (publish: [AgentID: [Double]], next: Date?) {
        var publish: [AgentID: [Double]] = [:]
        for (id, samples) in held {
            guard let last = published[id], now.timeIntervalSince(last) >= Self.interval else { continue }
            publish[id] = samples
        }
        for id in publish.keys {
            held[id] = nil
            published[id] = now
        }
        return (publish, nextDue)
    }

    /// When the earliest held samples are due, or nil with none held.
    var nextDue: Date? {
        held.keys.compactMap { published[$0]?.addingTimeInterval(Self.interval) }.min()
    }

    /// Starts the agent over: its next sample is its first.
    mutating func forget(_ id: AgentID) {
        published[id] = nil
        held[id] = nil
    }
}

@MainActor
extension ShepherdViewModel {
    var sidebarActivityItems: [SidebarActivityItem] {
        presentedSidebarLists.items(collapsed: collapsedActivitySections, openRunGroups: collapsedProjects,
                                    projects: sidebarLogicalProjects, showsProjects: projectsEnabled,
                                    selectedAutomation: shownDestination == .automations ? automationsPageSelection : nil,
                                    forgePins: sidebarForgePins)
    }

    /// Issues & PRs' pins as Pinned draws them, newest first.
    var sidebarForgePins: [SidebarForgePin] {
        guard let sidebar = forgeStore.sidebar else { return [] }
        let viewer = forgeStore.lists.values.lazy.compactMap(\.viewer).first
        return sidebar.pins.map { SidebarForgePin($0, viewer: viewer) }
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
            guard case .snapshot(let snapshot) = try? await nativeThread(id, request: .snapshot()),
                  !snapshot.piSessionID.isEmpty, !snapshot.running,
                  !snapshot.messages.contains(where: { $0.status == "pending" }) else { return }
            sidebarOpeningTurns.remove(id)
        }
    }

    /// A tool finished. The rate since the last one joins the agent's tail at once; the box its row reads is
    /// written when `ActivityPacing` says, so a burst of tools redraws the row a few times a second.
    func recordSidebarActivity(_ id: AgentID, at now: Date = Date()) {
        let previous = sidebarActivityLast[id] ?? statusSince[id]
        sidebarActivityLast[id] = now
        guard let previous, now > previous else { return }
        let tail = Array((sidebarActivityTail[id, default: []] + [1 / now.timeIntervalSince(previous)]).suffix(10))
        sidebarActivityTail[id] = tail
        if let samples = sidebarActivityPacing.record(id, samples: tail, at: now) {
            agentLive(id).samples = samples
        } else {
            armSidebarActivityFlush(after: now)
        }
    }

    /// One short-lived wait for the earliest held samples, on the events' own clock: it sleeps what is left of
    /// their interval and a little more (`ActivityPacing.coalescing`), then publishes every sample due by then.
    private func armSidebarActivityFlush(after now: Date) {
        guard let next = sidebarActivityPacing.nextDue else { return }
        let at = next.addingTimeInterval(ActivityPacing.coalescing)
        if let armed = sidebarActivityFlush, armed.due <= at { return }
        sidebarActivityFlush?.task.cancel()
        let wait = min(max(at.timeIntervalSince(now), 0), ActivityPacing.interval + ActivityPacing.coalescing)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.flushSidebarActivity(at: at)
        }
        sidebarActivityFlush = (task, at)
    }

    func flushSidebarActivity(at now: Date) {
        sidebarActivityFlush?.task.cancel()
        sidebarActivityFlush = nil
        let due = sidebarActivityPacing.due(at: now)
        for (id, samples) in due.publish { agentLives[id]?.samples = samples }
        if due.next != nil { armSidebarActivityFlush(after: now) }
    }

    /// A turn starting begins the sparkline again: no samples, and none held to land after it.
    func resetSidebarActivity(_ id: AgentID) {
        agentLives[id]?.samples = []
        sidebarActivityLast[id] = Date()
        forgetSidebarActivity(id)
    }

    /// Drops the agent's tail and its pacing; the wait ends when nothing is left to publish.
    func forgetSidebarActivity(_ id: AgentID) {
        sidebarActivityTail[id] = nil
        sidebarActivityPacing.forget(id)
        if sidebarActivityPacing.nextDue == nil {
            sidebarActivityFlush?.task.cancel()
            sidebarActivityFlush = nil
        }
    }

    /// Leaving for a page does not clear Done. Only opening another thread marks the current
    /// completion read; a later completion has a different generation.
    func willOpenSidebarThread(_ row: SidebarRowID) {
        let previous = sidebarReadingThread ?? selectedSidebarRow
        if let previous, previous != row, let completion = sidebarReadingCompletion {
            markSidebarSeen(previous, completion)
        }
        sidebarReadingThread = row
        sidebarReadingCompletion = sidebarLists.all.first(where: { $0.id == row })?.completion
    }

    func markAllSidebarDoneSeen() {
        for row in sidebarLists.done {
            if let completion = row.completion { markSidebarSeen(row.id, completion) }
        }
    }

    /// Seen here at once, and told to the thread's host when the completion is the host's own
    /// (`Agent.completedAt`), so Done clears on every device. An older host refuses; this device
    /// still remembers.
    private func markSidebarSeen(_ row: SidebarRowID, _ completion: Int) {
        sidebarSeenCompletions[row] = completion
        let ref: RemoteAgentRef?, agent: Agent?
        switch row {
        case .local(let id): ref = localRef(id); agent = state.agents.first { $0.id == id }
        case .remote(let remote):
            ref = remote
            agent = remoteHosts.connections.first { $0.id == remote.hostID }?.state.agents.first { $0.id == remote.agentID }
        case .design, .remoteDesign: return
        }
        guard let agent, let stamp = agent.completedAt, Int(stamp) == completion, agent.completionSeen == false else { return }
        Task {
            if let ref { try? await remoteHosts.agentAction(ref, action: .markSeen(upTo: stamp)) }
        }
    }
}
