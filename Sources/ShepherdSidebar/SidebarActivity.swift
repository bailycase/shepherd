import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Activity groups are view state, not part of the host's workspace or wire protocol.
public enum SidebarActivitySection: String, CaseIterable, Hashable, Sendable {
    case done, pinned, needsYou, working, recents, designs
    /// Active automations (This Mac's and each host's), one row each, with their run threads folded under them.
    case automations
    /// The new Projects (ProjectLead boards). Its rows are `SidebarLogicalProject`s, not thread rows.
    case projects

    public var title: String {
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

/// The identity of a sent thread's row under its sender: the thread's row in Needs you has the same thread id.
public struct SentRowID: Hashable { let row: SidebarRowID }

/// A flat, stable-id lazy list. Folding removes rows, never the section's count.
public enum SidebarActivityItem: Identifiable, Equatable {
    case header(SidebarActivitySection, count: Int, collapsed: Bool)
    case row(SidebarListRow)
    /// An active automation in Automations; `expanded` is nil while it has no runs to fold.
    case automation(SidebarAutomation, expanded: Bool?)
    case project(SidebarLogicalProject)
    /// A pull request or issue pinned from Issues & PRs, in Pinned (PRSidebarPinned).
    case forgePin(SidebarForgePin)
    /// Why Pinned can't show its pull requests and issues (their file on the host is damaged).
    case forgePinsProblem(String)

    public var id: AnyHashable {
        switch self {
        case .header(let section, _, _): AnyHashable("header.\(section.rawValue)")
        case .row(let row): row.fleetNested ? AnyHashable(SentRowID(row: row.id)) : AnyHashable(row.id)
        case .automation(let automation, _): AnyHashable(automation.key)
        case .project(let project): AnyHashable(project.ref)
        case .forgePin(let pin): AnyHashable(pin.ref)
        case .forgePinsProblem: AnyHashable("forgePinsProblem")
        }
    }
}

extension SidebarLists {
    /// The user's order: Designs, Projects, Automations, Needs you, Working, Done, Pinned, Recents.
    /// Pinned is opt-in and follows Done. Projects are not thread rows; `items` places them right after
    /// Designs, so thread status, attention and pins never move them. Automations' rows are its run threads, which
    /// `items` folds under `automationRows`.
    public var sections: [(section: SidebarActivitySection, rows: [SidebarListRow])] {
        [(.designs, designs), (.automations, automations), (.needsYou, needsYou), (.working, working), (.done, done), (.pinned, pinned), (.recents, recents)]
    }

    /// `openRunGroups` holds the open automations' keys (`runGroupKey`); a closed one's runs aren't visible.
    public func visibleRows(collapsed: Set<SidebarActivitySection>, openRunGroups: Set<String> = []) -> [SidebarListRow] {
        sections.flatMap { collapsed.contains($0.section) ? [] : $0.rows.foldingSent(open: openRunGroups) }
            .filter { row in row.foldedUnder.map { openRunGroups.contains(Self.runGroupKey($0)) } ?? true }
    }

    /// An Activity automation's open key, remembered beside the space tree's (`SidebarRunGroupRow.key`).
    public static func runGroupKey(_ automation: AutomationKey) -> String {
        "runs.open:activity:\(automation.host.uuidString):\(automation.automation.rawValue)"
    }

    /// `selectedAutomation`: the automation the Automations page shows, marked on its row.
    public func items(collapsed: Set<SidebarActivitySection>, openRunGroups: Set<String> = [], projects: [SidebarLogicalProject] = [],
               showsProjects: Bool = true,
               selectedAutomation: AutomationKey? = nil, forgePins: [SidebarForgePin] = [], forgePinsProblem: String? = nil) -> [SidebarActivityItem] {
        func block(_ section: SidebarActivitySection, _ rows: [SidebarListRow]) -> [SidebarActivityItem] {
            guard !rows.isEmpty else { return [] }
            let folded = collapsed.contains(section)
            // A thread under its sender is counted with the sender.
            return [.header(section, count: rows.count { !$0.fleetNested }, collapsed: folded)] + (folded ? [] : rows.map(SidebarActivityItem.row))
        }
        var items: [SidebarActivityItem] = []
        for (section, rows) in sections {
            if section == .automations {
                items += automationBlock(collapsed: collapsed, openRunGroups: openRunGroups, selected: selectedAutomation)
                continue
            }
            // Pinned threads, then pinned pull requests and issues (or why they can't show), under one header.
            if section == .pinned, !forgePins.isEmpty || forgePinsProblem != nil {
                let folded = collapsed.contains(.pinned)
                items.append(.header(.pinned, count: rows.count + forgePins.count, collapsed: folded))
                if !folded {
                    items += rows.map(SidebarActivityItem.row) + forgePins.map(SidebarActivityItem.forgePin)
                    items += forgePinsProblem.map { [SidebarActivityItem.forgePinsProblem($0)] } ?? []
                }
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

