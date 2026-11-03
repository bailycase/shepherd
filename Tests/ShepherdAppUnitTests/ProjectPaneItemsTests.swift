import Foundation
import Testing
import ShepherdCore
import ShepherdRemote
@testable import ShepherdApp

/// The Project pane's task list: one flattened lazy list, derived once per change of its inputs.
@Suite("Project pane items")
@MainActor
struct ProjectPaneItemsTests {
    private func presentation(_ count: Int) -> ProjectPagePresentation {
        var project = Project(name: "Release")
        let phases: [ProjectTask.Phase] = [.waiting, .running, .settled]
        project.tasks = (0..<count).map { ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "Task \($0)", prompt: "p", phase: phases[$0 % 3]) }
        return ProjectPagePresentation(project)
    }

    @Test func groupsFlattenInOrderAndFoldingKeepsTheHeader() {
        let page = presentation(1_000)
        let items = page.paneItems(query: "", groups: [], folded: [])
        #expect(items.count == page.rows.count + Set(page.rows.map(\.group)).count)
        let headers = items.compactMap { if case .header(let group, _, _) = $0 { group } else { nil } }
        #expect(headers == ProjectTaskGroup.allCases.filter { group in page.rows.contains { $0.group == group } })
        let folded = page.paneItems(query: "", groups: [], folded: [headers[0]])
        #expect(folded.count == items.count - page.rows(in: headers[0]).count)
        #expect(folded.first == .header(headers[0], count: page.rows(in: headers[0]).count, open: false))
        #expect(page.paneItems(query: "task 999", groups: [], folded: []).count == 2)
    }

    @Test func derivedOncePerChangeOfItsInputs() {
        let cache = ProjectPaneItemsCache()
        let page = presentation(50)
        _ = cache.items(page, query: "", groups: [], folded: [])
        // Renders for other reasons (a worker's activity, a clock) reuse the list.
        for _ in 0..<10 { _ = cache.items(page, query: "", groups: [], folded: []) }
        #expect(cache.derivations == 1)
        _ = cache.items(page, query: "task 1", groups: [], folded: [])
        #expect(cache.derivations == 2)
    }
}
