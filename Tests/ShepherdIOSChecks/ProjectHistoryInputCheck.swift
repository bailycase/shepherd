import Foundation
import ShepherdCore
import ShepherdRemote

@main
struct ProjectHistoryInputCheck {
    static func main() {
        let space = SpaceID()
        func task(_ title: String, _ phase: ProjectTask.Phase) -> ProjectTask {
            ProjectTask(operationID: UUID(), spaceID: space, title: title, prompt: title, phase: phase)
        }
        let singleton = task("Ship release", .settled)
        let first = task("Build release", .running)
        let middle = task("Review release", .running)
        let last = task("Test release", .running)
        let unrelated = task("Update dependencies", .running)
        var project = Project(name: "Release checks", goal: "Ship the native client")
        project.tasks = [singleton, first, unrelated, middle, last]
        let rows = ProjectPagePresentation(project).rows
        let working = rows.filter { $0.group == .working && $0.id != unrelated.id }
        let stopped = rows.first { $0.id == singleton.id }!
        let items = ProjectHistoryInput(rows: rows, query: "release").items()
        precondition(items == [
            .header(.working, count: 3),
            .row(working[0], first: true, last: false),
            .row(working[1], first: false, last: false),
            .row(working[2], first: false, last: true),
            .header(.stopped, count: 1),
            .row(stopped, first: true, last: true),
        ], "History headers count matches, and only the card's endpoints get corners")
        precondition(ProjectHistoryInput(rows: rows, query: "no match").items().isEmpty)
        print("PASS: Project task history counts and card endpoints")
    }
}
