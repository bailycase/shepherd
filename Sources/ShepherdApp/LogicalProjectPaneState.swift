import Foundation
import ShepherdRemote
import ShepherdCore

/// The pane's tabs, in the boards' order (ProjectLead-Started): Threads, Files, Automations.
enum LogicalProjectPaneTab: String, CaseIterable, Identifiable {
    case threads = "Threads", files = "Files", automations = "Automations"
    var id: Self { self }
}

/// A new task for a Project: a title, what to do, and one of the Project's own Spaces. One operation identity, so a retry never
/// assigns it twice.
struct AssignProjectTaskDraft: Identifiable, Equatable {
    let id = UUID()
    var title = ""
    var prompt = ""
    var space: SpaceID?
    /// Where it runs, one of the hosts the Project allows (owner-relative). nil is the owner itself.
    var host: ProjectHostReference?
    var assigning = false
    var failure: String?

    var canAssign: Bool {
        !assigning && space != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One line of the pane's task list, flattened so the list is one lazy stack: a group's header, or a task under an open one.
enum ProjectPaneItem: Identifiable, Equatable {
    case header(ProjectTaskGroup, count: Int, open: Bool)
    case row(ProjectTaskRow)

    enum ID: Hashable {
        case header(ProjectTaskGroup)
        case row(ProjectTaskID)
    }

    var id: ID {
        switch self {
        case .header(let group, _, _): .header(group)
        case .row(let row): .row(row.id)
        }
    }
}

extension ProjectPagePresentation {
    /// The visible rows in group order, each non-empty group led by its header; a folded group keeps only its header.
    func paneItems(query: String, groups: Set<ProjectTaskGroup>, folded: Set<ProjectTaskGroup>) -> [ProjectPaneItem] {
        ProjectTaskHistory(rows: rows, query: query, groups: groups).sections.flatMap { section -> [ProjectPaneItem] in
            let open = !folded.contains(section.group)
            return [.header(section.group, count: section.rows.count, open: open)] + (open ? section.rows.map(ProjectPaneItem.row) : [])
        }
    }
}

/// The pane's list, derived once per change of what it is derived from, not per render (a worker's update re-renders only its row).
@MainActor
final class ProjectPaneItemsCache {
    private struct Key: Equatable {
        var rows: [ProjectTaskRow]
        var query: String
        var groups: Set<ProjectTaskGroup>
        var folded: Set<ProjectTaskGroup>
    }
    private var key: Key?
    private(set) var items: [ProjectPaneItem] = []
    /// Derivations (tests).
    private(set) var derivations = 0

    func items(_ presentation: ProjectPagePresentation, query: String, groups: Set<ProjectTaskGroup>,
               folded: Set<ProjectTaskGroup>) -> [ProjectPaneItem] {
        let next = Key(rows: presentation.rows, query: query, groups: groups, folded: folded)
        if next != key {
            key = next
            items = presentation.paneItems(query: query, groups: groups, folded: folded)
            derivations += 1
        }
        return items
    }
}
