import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Project detail presentation", .mainActorExclusive)
@MainActor struct ProjectDetailPresentationTests {
    @Test func navigationDuringContextReadCannotLoadTheOldProjectsFile() async {
        let project = ProjectSummary(directory: "/repo", name: "repo", displayPath: "~/repo", summary: "AGENTS.md")
        let file = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)
        let started = AsyncStream.makeStream(of: Void.self)
        var contextRead: CheckedContinuation<RemoteProjectsResult, Never>?
        var reads = 0
        let model = ProjectsModel { _, request in
            switch request {
            case .list: return .listing(ProjectListing(projects: [project]))
            case .files: return .files([file])
            case .context: return await withCheckedContinuation { contextRead = $0; started.continuation.yield() }
            case .read: reads += 1; return .text(ProjectFileText(file: file, text: "old project"))
            case .save: return .text(ProjectFileText(file: file, text: "saved"))
            case .open: return .opened
            case .mcp: return .mcp(.init())
            }
        }
        await model.load([ProjectsHost(id: "local", name: "This Mac", known: [])])
        let task = Task { await model.open(model.rows[0]) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await model.navigate(.close)
        contextRead?.resume(returning: .context(ProjectContext()))
        await task.value
        #expect(model.selected == nil)
        #expect(model.selectedFile == nil)
        #expect(reads == 0)
    }
}
