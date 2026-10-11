import SwiftUI
import ShepherdCore
import ShepherdUI

/// A Project's row in the sidebar. Activity (ProjectLead-Activity) draws the summary row; the Spaces mode
/// (ProjectLead-AddsSpace, -Paused, -Question) draws the count row, with a lantern dot while something waits. A click opens
/// the Project page.
struct LogicalProjectSidebarRow: View {
    var vm: ShepherdViewModel
    let project: SidebarLogicalProject
    /// The Spaces mode's row.
    var spaces = false

    var body: some View {
        Group {
            if spaces {
                NWLeadSpaceProjectRow(project.name, selected: project.selected, count: project.count, needsYou: project.needsYou)
                    .equatable()
            } else {
                NWLeadProjectRow(project.name, selected: project.selected, summary: project.summary, needsYou: project.needsYou)
                    .equatable()
            }
        }
        .help(project.hostName.map { "\(project.name) on \($0)" } ?? project.name)
        .sidebarTapRow { vm.openLogicalProject(project.ref) }
        // The tap row makes its own accessibility element, so the label is set after it, as every row's is.
        .accessibilityLabel([project.name, "project", project.summary ?? (spaces ? "\(project.count) threads" : nil)]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(project.selected ? .isSelected : [])
        .contextMenu {
            Button("Open Project Settings") { vm.openLogicalProjectSettings(project.ref) }
        }
    }
}

/// A task thread under its Project in the Spaces mode (ProjectLead-Paused, -Question): a state dot, the title, and a word
/// ("answer") in mono 10.5 `lanternText` while it waits on you. 26pt in from the left (a Project's child), 8 from the right.
struct LogicalProjectTaskRow: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let task: ProjectTaskRow

    var body: some View {
        NWLeadTaskRow(title: task.title, attention: task.group == .waiting, word: task.group == .waiting ? "answer" : nil)
            .equatable()
            .sidebarTapRow {
                vm.openLogicalProject(ref)
                vm.logicalProjectPaneTask = task.id
            }
            .accessibilityLabel([task.title, task.group == .waiting ? "answer" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}
