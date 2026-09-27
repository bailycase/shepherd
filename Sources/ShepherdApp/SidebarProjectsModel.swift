import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The sidebar organized by project (Sidebar — Projects: SidebarTree, SidebarProjects,
// SidebarProjectsHosts) as plain values: a folder per project with its threads inside, derived
// once per change from the same source as Needs you and Recents, never in a view's body.

/// A project in the tree.
enum SidebarProjectID: Hashable {
    /// One of This Mac's spaces; a connected host's threads in a project of the same name join
    /// it while the tree isn't grouped by host.
    case local(SpaceID)
    /// A host's space, in its host's section (Group by host).
    case remote(hostID: UUID, SpaceID)
    /// A project only hosts have, by name (every host's threads in it), while not grouped.
    case named(String)

    /// The key its collapsed state is remembered under.
    var key: String {
        switch self {
        case .local(let space): "local:\(space.rawValue)"
        case .remote(let host, let space): "\(host.uuidString):\(space.rawValue)"
        case .named(let name): "name:\(name)"
        }
    }
}

/// A project with its threads, newest activity first.
struct SidebarProject: Identifiable, Equatable {
    let id: SidebarProjectID
    let name: String
    /// Where it is: This Mac's path for a local project (Reveal in Finder, Open in Terminal,
    /// Copy path), the host's for a remote one.
    let path: String
    /// Where a new thread in it starts: each host's space for it, This Mac's under nil.
    var places: [UUID?: SpaceID]
    var rows: [SidebarListRow] = []
    /// Every host it lives on is offline (a remote project).
    var dimmed = false
    var rollup: NWProjectRollup = .quiet

    /// This Mac's space: it can be hidden and dragged.
    var space: SpaceID? {
        if case .local(let id) = id { return id }
        return nil
    }

    /// The host a new thread in it starts on (nil: This Mac), and the space there: the host of
    /// its most recently active thread where the project lives there too, else This Mac, else
    /// the first host that has it.
    func newThreadPlace(connected: Set<UUID>) -> (host: UUID?, space: SpaceID)? {
        if case .remote(let ref)? = rows.first?.id, connected.contains(ref.hostID), let space = places[ref.hostID] {
            return (ref.hostID, space)
        }
        if let local = places[nil] { return (nil, local) }
        let remote = places.compactMap { host, space -> (UUID, SpaceID)? in
            guard let host, connected.contains(host) else { return nil }
            return (host, space)
        }
        return remote.min { $0.0.uuidString < $1.0.uuidString }.map { (host: $0.0, space: $0.1) }
    }
}

/// A section of the tree: Projects, or a host's (This Mac first) while grouped by host.
struct SidebarTreeSection: Identifiable, Equatable {
    enum Header: Equatable {
        /// "Projects", with its + (add a project, or bring back a hidden one).
        case projects
        /// A host's name; nil `id` is This Mac.
        case host(name: String, id: UUID?, unreachable: Bool)

        var id: String {
            switch self {
            case .projects: "header.projects"
            case .host(_, let id, _): "header.host.\(id?.uuidString ?? "local")"
            }
        }
    }

    let header: Header
    var projects: [SidebarProject]

    var id: String { header.id }
}

/// The whole tree, before collapsing, selection and ⌘-digits are applied.
struct SidebarTree: Equatable {
    var sections: [SidebarTreeSection] = []
    /// This Mac's projects hidden from the sidebar, for the + beside Projects.
    var hiddenProjects: [Space] = []

    /// The thread rows shown with `collapsed` projects closed, in order: what ⌘↑/↓ walk and
    /// ⌘1–9 reach.
    func visibleRows(collapsed: Set<String>) -> [SidebarListRow] {
        sections.flatMap { section in
            section.projects.flatMap { collapsed.contains($0.id.key) ? [] : $0.rows }
        }
    }

    /// The project holding a row.
    func project(holding row: SidebarRowID) -> SidebarProject? {
        for section in sections {
            if let project = section.projects.first(where: { $0.rows.contains { $0.id == row } }) { return project }
        }
        return nil
    }

    /// Every project, in order.
    var projects: [SidebarProject] { sections.flatMap(\.projects) }

    /// The tree as the lazy list draws it: each section's header, each project's row, and the
    /// threads of the open ones, the row on screen marked and the first nine visible threads
    /// wearing their ⌘-digit while ⌘ is held.
    func items(collapsed: Set<String>, selected: SidebarRowID?, shortcuts: Bool, connected: Set<UUID>) -> [SidebarTreeItem] {
        var items: [SidebarTreeItem] = []
        var digit = 0
        for (sectionIndex, section) in sections.enumerated() {
            items.append(.header(section.header))
            for project in section.projects {
                let expanded = !collapsed.contains(project.id.key)
                let place = project.newThreadPlace(connected: connected)
                items.append(.project(SidebarProjectRow(
                    id: project.id, name: project.name, path: project.path, count: project.rows.count, expanded: expanded,
                    rollup: project.rollup, dimmed: project.dimmed, newThreadHost: place?.host, newThreadSpace: place?.space,
                    movable: sectionIndex == 0 && project.space != nil)))
                guard expanded else { continue }
                for var row in project.rows {
                    if row.id == selected { row.selected = true }
                    if shortcuts, digit < 9 {
                        digit += 1
                        row.accessory = .shortcut("⌘\(digit)")
                    }
                    items.append(.row(row))
                }
            }
        }
        return items
    }
}

/// A project's row as the tree draws it and its menu needs it.
struct SidebarProjectRow: Equatable {
    let id: SidebarProjectID
    let name: String
    let path: String
    let count: Int
    let expanded: Bool
    let rollup: NWProjectRollup
    let dimmed: Bool
    /// Where + and New thread in <project> start one; nil space: nowhere reachable.
    let newThreadHost: UUID?
    let newThreadSpace: SpaceID?
    /// This Mac's project in the first section: it can be dragged.
    let movable: Bool

    var space: SpaceID? {
        if case .local(let id) = id { return id }
        return nil
    }
}

/// One element of the tree's lazy list.
enum SidebarTreeItem: Identifiable, Equatable {
    case header(SidebarTreeSection.Header)
    case project(SidebarProjectRow)
    case row(SidebarListRow)

    var id: AnyHashable {
        switch self {
        case .header(let header): AnyHashable(header.id)
        case .project(let project): AnyHashable(project.id)
        case .row(let row): AnyHashable(row.id)
        }
    }
}

/// What the tree reads beyond the source: Settings ▸ Appearance ▸ Sidebar.
struct SidebarTreeOptions: Equatable {
    var groupByHost = false
    /// Idle and finished threads last active before this (ms since 1970) leave the tree; nil
    /// keeps them all.
    var idleCutoff: Double?

    /// Keep idle threads' cutoff for `days` before `now`, to the hour so the tree derives again
    /// at most hourly for it; nil for Forever (0).
    static func idleCutoff(days: Int, now: Date) -> Double? {
        guard days > 0 else { return nil }
        let hour = (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        return (hour - Double(days) * 86_400) * 1000
    }
}

extension SidebarDerivation {
    /// The project tree. Pure: the same source and options always give the same tree. The
    /// reserved spaces (automation runs', designs') are never projects: an automation's run sits
    /// in the project its folder is in (or nowhere, when no project holds it), and designs are
    /// not in the tree at all (the user's decision, 2026-09-26: they stay under Designs and ⌘K).
    @MainActor static func tree(_ source: SidebarSource, options: SidebarTreeOptions) -> SidebarTree {
        NWRenderProbe.tick("sidebar.tree")
        var builder = TreeBuilder(options: options)
        builder.addLocal(source)
        for (hostIndex, host) in source.hosts.enumerated() {
            builder.addHost(host, index: hostIndex + 1, local: source.local)
        }
        return builder.finish(source)
    }

    /// The deepest of `spaces` whose folder holds `path`.
    static func space(holding path: String, in spaces: [Space], expandTilde: Bool) -> Space? {
        func normalized(_ path: String) -> String {
            let expanded = expandTilde ? (path as NSString).expandingTildeInPath : path
            let standard = (expanded as NSString).standardizingPath
            return standard.hasSuffix("/") && standard.count > 1 ? String(standard.dropLast()) : standard
        }
        let target = normalized(path)
        return spaces
            .map { (space: $0, path: normalized($0.path)) }
            .filter { target == $0.path || target.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
            .max { $0.path.count < $1.path.count }?.space
    }
}

/// One pass over the agents, grouping as it goes.
private struct TreeBuilder {
    struct Entry {
        let row: SidebarListRow
        let waiting: Bool
        let running: Bool
        let key: Double
        let host: Int
        let index: Int
    }

    let options: SidebarTreeOptions
    /// Projects in order, and their entries.
    var order: [SidebarProjectID] = []
    var projects: [SidebarProjectID: SidebarProject] = [:]
    var entries: [SidebarProjectID: [Entry]] = [:]
    /// Hosts whose projects dim: every place a named project lives is offline.
    var onlineHosts: [SidebarProjectID: Bool] = [:]
    /// This Mac's projects by name, hidden ones included: a host's project of the same name
    /// joins it (and hides with it) while not grouped.
    var localByName: [String: SpaceID] = [:]
    var hiddenLocal: Set<SpaceID> = []

    init(options: SidebarTreeOptions) { self.options = options }

    mutating func declare(_ id: SidebarProjectID, name: String, path: String, host: UUID?, space: SpaceID) {
        if projects[id] == nil {
            order.append(id)
            projects[id] = SidebarProject(id: id, name: name, path: path, places: [host: space])
        } else if projects[id]?.places[host] == nil {
            projects[id]?.places[host] = space
        }
    }

    /// Leaves an idle or finished thread out once it has been quiet longer than Keep idle
    /// threads; a running one or one waiting on you always stays, as does one no host has timed.
    func keeps(lastActive: Double?, waiting: Bool, running: Bool) -> Bool {
        guard let cutoff = options.idleCutoff, !waiting, !running, let lastActive else { return true }
        return lastActive >= cutoff
    }

    mutating func add(_ entry: Entry, to id: SidebarProjectID) {
        guard keeps(lastActive: entry.key < 0 ? nil : entry.key, waiting: entry.waiting, running: entry.running) else { return }
        entries[id, default: []].append(entry)
    }

    mutating func addLocal(_ source: SidebarSource) {
        let state = source.local
        let projectSpaces = state.spaces.filter { !$0.hidden }
        for space in projectSpaces {
            localByName[space.name] = localByName[space.name] ?? space.id
            if space.sidebarHidden {
                hiddenLocal.insert(space.id)
            }
            declare(.local(space.id), name: space.name, path: space.path, host: nil, space: space.id)
        }
        let visible = Set(projectSpaces.map(\.id))
        let runs = Dictionary(state.automations.compactMap { automation in automation.agentID.map { ($0, automation) } },
                              uniquingKeysWith: { first, _ in first })
        for (index, agent) in state.agents.enumerated() where agent.designID == nil {
            let automation = runs[agent.id]
            let project: SpaceID?
            if visible.contains(agent.spaceID) {
                project = agent.spaceID
            } else if let automation {
                project = SidebarDerivation.space(holding: automation.cwd, in: projectSpaces, expandTilde: true)?.id
            } else {
                project = nil
            }
            guard let project else { continue }
            let children = source.localChildren[agent.id] ?? []
            let notSignedIn = source.notSignedIn.contains(agent.id)
            let waiting = agent.status == .blocked || children.contains(where: \.needsAttention) || notSignedIn
            let run = automation.flatMap { source.openRuns[$0.id] }.flatMap { $0.agentID == agent.id ? $0 : nil }
            let live = automation != nil && AutomationRow.isLive(agent, run: run)
            let row = SidebarDerivation.localRow(agent, automation: automation, run: run, children: children, needsYou: waiting,
                                                 failed: source.failedTurns.contains(agent.id), cannotStart: source.cannotStart.contains(agent.id),
                                                 notSignedIn: notSignedIn, waiting: source.waiting.contains(agent.id),
                                                 since: source.statusSince[agent.id])
            add(Entry(row: row, waiting: waiting, running: agent.status == .working || live, key: agent.lastActiveAt ?? -1,
                      host: 0, index: index), to: .local(project))
        }
    }

    mutating func addHost(_ host: SidebarSource.Host, index hostIndex: Int, local: ShepherdState) {
        let state = host.state
        let projectSpaces = state.spaces.filter { !$0.hidden }
        var projectOf: [SpaceID: SidebarProjectID] = [:]
        for space in projectSpaces {
            let id: SidebarProjectID
            if options.groupByHost {
                guard !space.sidebarHidden else { continue }
                id = .remote(hostID: host.id, space.id)
            } else if let mine = localByName[space.name] {
                id = .local(mine)
            } else {
                guard !space.sidebarHidden else { continue }
                id = .named(space.name)
            }
            projectOf[space.id] = id
            declare(id, name: space.name, path: space.path, host: host.id, space: space.id)
            onlineHosts[id] = (onlineHosts[id] ?? false) || !host.offline
        }
        let runs = Dictionary(state.automations.compactMap { automation in automation.agentID.map { ($0, automation) } },
                              uniquingKeysWith: { first, _ in first })
        for (index, agent) in state.agents.enumerated() where !state.isDesignAgent(agent) && agent.designID == nil {
            let automation = runs[agent.id]
            var project = projectOf[agent.spaceID]
            if project == nil, let automation,
               let space = SidebarDerivation.space(holding: automation.cwd, in: projectSpaces, expandTilde: false) {
                project = projectOf[space.id]
            }
            guard let project else { continue }
            let children = host.offline ? [] : host.children[agent.id] ?? []
            let waiting = !host.offline && (agent.status == .blocked || children.contains(where: \.needsAttention))
            var row = SidebarDerivation.remoteRow(agent, host: host, automation: automation != nil, children: children,
                                                  needsYou: waiting)
            // Grouped, the section says which host: the row carries no tag.
            if options.groupByHost, case .tag = row.accessory { row.accessory = .none }
            add(Entry(row: row, waiting: waiting, running: !host.offline && agent.status == .working, key: agent.lastActiveAt ?? -1,
                      host: hostIndex, index: index), to: project)
        }
    }

    mutating func finish(_ source: SidebarSource) -> SidebarTree {
        var built: [SidebarProjectID: SidebarProject] = [:]
        for id in order {
            guard var project = projects[id] else { continue }
            var rows = entries[id] ?? []
            // Newest activity first; untimed threads follow, newest created first; ties keep This
            // Mac first, then the hosts in order.
            rows.sort { a, b in
                if a.key != b.key { return a.key > b.key }
                if a.host != b.host { return a.host < b.host }
                return a.index > b.index
            }
            project.rows = rows.map(\.row)
            project.rollup = rows.contains(where: \.waiting) ? .waiting : rows.contains(where: \.running) ? .running : .quiet
            if case .local = id {} else { project.dimmed = onlineHosts[id] == false }
            built[id] = project
        }
        var tree = SidebarTree()
        tree.hiddenProjects = source.local.spaces.filter { hiddenLocal.contains($0.id) }
        let shown = order.filter { id in
            if case .local(let space) = id { return !hiddenLocal.contains(space) }
            return true
        }
        if options.groupByHost {
            tree.sections.append(SidebarTreeSection(
                header: .host(name: "This Mac", id: nil, unreachable: false),
                projects: shown.compactMap { if case .local = $0 { built[$0] } else { nil } }))
            for host in source.hosts {
                tree.sections.append(SidebarTreeSection(
                    header: .host(name: host.name, id: host.id, unreachable: host.offline),
                    projects: shown.compactMap { id in
                        if case .remote(let owner, _) = id, owner == host.id { built[id] } else { nil }
                    }))
            }
        } else {
            tree.sections = [SidebarTreeSection(header: .projects, projects: shown.compactMap { built[$0] })]
        }
        return tree
    }
}
