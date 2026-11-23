import Foundation
import ShepherdCore
import ShepherdRemote
import Testing

@Suite("Project task history")
struct ProjectTaskHistoryTests {
    @Test func groupsAndSearchesAThreeHundredTaskHistoryWithoutChangingRowOrder() {
        var project = Project(name: "Acme Web")
        let phases: [ProjectTask.Phase] = [.resolved, .waiting, .settled, .running]
        project.tasks = (0..<300).map { index in
            let phase = phases[index % phases.count]
            var task = ProjectTask(id: ProjectTaskID(rawValue: "task-\(index)"), operationID: UUID(), spaceID: SpaceID(),
                                   title: "Release check \(index)", prompt: "Check the release", phase: phase)
            if phase == .waiting { task.question = "Which API region?" }
            return task
        }
        let rows = ProjectPagePresentation(project).rows
        let all = ProjectTaskHistory(rows: rows, query: "  ")
        #expect(all.sections.map(\.group) == [.waiting, .working, .stopped, .resolved])
        #expect(all.sections.map { $0.rows.count } == [75, 75, 75, 75])
        #expect(Set(all.sections.flatMap(\.rows).map(\.id)).count == 300)
        for section in all.sections {
            #expect(section.rows == rows.filter { $0.group == section.group })
        }

        // A word in each of title, lead and detail; all must match, ignoring case and extra spaces.
        let found = ProjectTaskHistory(rows: rows, query: "  RELEASE    BLOcked REGION ")
        #expect(found.sections.map(\.group) == [.waiting])
        #expect(found.sections.first?.rows == all.sections.first?.rows)
        #expect(ProjectTaskHistory(rows: rows, query: "release missing").sections.isEmpty)
        #expect(ProjectTaskHistory(rows: rows, query: "blocked", groups: [.working]).sections.isEmpty)
        #expect(ProjectTaskHistory(rows: rows, query: "release", groups: [.working]).sections.map(\.group) == [.working])
    }
}
