import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Projects presentation", .mainActorExclusive)
@MainActor
struct ProjectsModelTests {
    @Test func hostAndPathIdentifyProjectsAndFiltersDoNotEditThem() async throws {
        let project = ProjectSummary(directory: "/repo", name: "repo", displayPath: "~/repo", summary: "AGENTS.md only")
        var calls: [String] = []
        let model = ProjectsModel { host, request in
            calls.append(host.id)
            return .listing(ProjectListing(projects: [project]))
        }
        let local = ProjectsHost(id: "local", name: "This Mac", known: [])
        let remote = ProjectsHost(id: "remote", name: "build-01", known: [])
        await model.load([local, remote])
        #expect(model.rows.count == 2)
        #expect(Set(model.rows.map(\.id)).count == 2)
        model.host = "remote"
        #expect(model.visible.map(\.host.name) == ["build-01"])
        model.filter = "  ~/REPO  "
        #expect(model.visible.count == 1)
        model.filter = "missing"
        #expect(model.visible.isEmpty)
        #expect(calls == ["local", "remote"])
        await model.load([local, remote])
        #expect(calls.count == 2, "A render does not reread project files")
    }

    @Test func dirtyNavigationAsksBeforeDiscardingAndSaveUsesTheSelectedDirectory() async {
        let file = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)
        let project = ProjectSummary(directory: "/one", name: "one", displayPath: "/one", summary: "AGENTS.md only")
        let host = ProjectsHost(id: "host", name: "build-01", known: [])
        var requests: [RemoteProjectsRequest] = []
        let model = ProjectsModel { host, request in
            #expect(host.id == "host")
            requests.append(request)
            switch request {
            case .files: return .files([file])
            case .read: return .text(ProjectFileText(file: file, text: "old"))
            case .save(_, _, let text, _): return .text(ProjectFileText(file: file, text: text))
            case .list: return .listing(ProjectListing(projects: [project]))
            case .context: return .context(ProjectContext())
            case .open: return .opened
            }
        }
        await model.open(ProjectsRow(host: host, project: project))
        model.draft = "changed"
        await model.navigate(.close)
        #expect(model.pending == .close)
        #expect(model.selected != nil)
        #expect(!requests.contains { if case .save = $0 { true } else { false } })
        model.pending = nil
        await model.save()
        #expect(requests.contains(.save(directory: "/one", file: "AGENTS.md", text: "changed", expected: "old")))
        #expect(!model.dirty)
        model.draft = "discard me"
        await model.navigate(.close)
        await model.discard()
        #expect(model.selected == nil)
    }

    @Test func aLateInventoryReplyCannotOverwriteTheReopenedEditorsDraft() async {
        var inventoryCalls = 0
        var oldReply: CheckedContinuation<RemoteProjectsResult, Never>?
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let file = ProjectFile(path: "AGENTS.md", category: .instructions, exists: true)
        let model = ProjectsModel { _, request in
            switch request {
            case .list: return .listing(ProjectListing(projects: [ProjectSummary(directory: "/repo", name: "repo", displayPath: "/repo", summary: "AGENTS.md only")]))
            case .files:
                inventoryCalls += 1
                if inventoryCalls == 1 {
                    return await withCheckedContinuation { oldReply = $0; started.continuation.yield(()) }
                }
                return .files([file])
            case .read: return .text(ProjectFileText(file: file, text: "original"))
            case .save: return .text(ProjectFileText(file: file, text: "saved"))
            case .context: return .context(ProjectContext())
            case .open: return .opened
            }
        }
        await model.load([ProjectsHost(id: "local", name: "This Mac", known: [])])
        let row = model.visible[0]
        let old = Task { await model.open(row) }
        for await _ in started.stream { break }
        await model.navigate(.close)
        await model.open(row)
        model.draft = "unsaved new text"
        oldReply?.resume(returning: .files([file]))
        await old.value
        started.continuation.finish()
        #expect(model.draft == "unsaved new text")
        #expect(model.dirty)
    }

    @Test func changingAHostEndpointPreservesTheDraftButDisablesSaving() async {
        let file = ProjectFile(path: "AGENTS.md", category: .instructions, exists: false)
        let project = ProjectSummary(directory: "/repo", name: "repo", displayPath: "/repo", summary: "no project settings")
        var old = ProjectsHost(id: "same-entry", name: "build-01", endpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"), known: [])
        var saves = 0
        let model = ProjectsModel { _, request in
            switch request {
            case .list: return .listing(ProjectListing(projects: [project]))
            case .files: return .files([file])
            case .read: return .text(ProjectFileText(file: file, text: nil))
            case .save: saves += 1; return .text(ProjectFileText(file: file, text: "wrong host"))
            case .context: return .context(ProjectContext())
            case .open: return .opened
            }
        }
        await model.load([old])
        await model.open(model.rows[0])
        model.draft = "Keep this on the original host"
        old.endpointID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        await model.load([old])
        await model.save()
        #expect(model.dirty)
        #expect(model.selected?.unavailable != nil)
        #expect(saves == 0)
    }

    @Test func offlineHostsKeepTheirProjectRowsButNeverSendAWrite() async {
        let project = ProjectSummary(directory: "/repo", name: "repo", displayPath: "/repo", summary: "unavailable")
        var calls = 0
        let model = ProjectsModel { _, _ in calls += 1; return .listing(ProjectListing(projects: [])) }
        let offline = ProjectsHost(id: "offline", name: "build-01", unavailable: "Host offline", known: [project])
        await model.load([offline])
        #expect(model.visible.count == 1)
        await model.open(model.visible[0])
        #expect(model.selected == nil)
        #expect(model.error == "Host offline")
        #expect(calls == 0)
    }
}
