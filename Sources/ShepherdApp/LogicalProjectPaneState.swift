import Foundation
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

extension ProjectPagePresentation {
    /// The rows the pane shows: the person's text filter over title, question and detail, then the chosen groups.
    func visibleRows(query: String, groups: Set<ProjectTaskGroup>) -> [ProjectTaskRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return rows.filter { row in
            (groups.isEmpty || groups.contains(row.group))
                && words.allSatisfy { word in
                    [row.title, row.detail ?? "", row.lead ?? ""].contains { $0.lowercased().contains(word) }
                }
        }
    }
}
