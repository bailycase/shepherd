import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// The Projects model carries the revision it was shown on every edit, never overwrites on a stale
/// answer, and treats the owner's pushed state as the truth. A scripted owner stands in for the
/// server; the real server and the real controls are in `LogicalProjectControlTests`.
@Suite("Logical projects model")
@MainActor
struct LogicalProjectsModelTests {
    /// An owner that answers from a list and records every request it was sent.
    @MainActor private final class Owner {
        var projects: [Project]
        var requests: [LogicalProjectsRequest] = []
        var failure: Error?
        init(_ projects: [Project]) { self.projects = projects }

        func send(_ home: LogicalProjectHome, _ request: LogicalProjectsRequest) async throws -> LogicalProjectsResult {
            requests.append(request)
            if let failure { throw failure }
            switch request {
            case .list: return .projects(projects)
            case .edit(let id, let revision, let name, let goal):
                guard let index = projects.firstIndex(where: { $0.id == id }) else { throw LogicalProjectsError("no_such_project", "gone") }
                guard projects[index].revision == revision else { throw LogicalProjectsError("stale_project", "This project changed on its host.") }
                projects[index].name = name; projects[index].goal = goal; projects[index].revision += 1
                return .project(projects[index])
            case .delete(let id, _):
                projects.removeAll { $0.id == id }
                return .deleted(projectID: id)
            default: throw LogicalProjectsError("unsupported", "not scripted")
            }
        }
    }

    private func model(_ owner: Owner, pushed: @escaping @MainActor () -> [Project]) -> LogicalProjectsModel {
        LogicalProjectsModel(send: { try await owner.send($0, $1) }, pushed: { _ in pushed() })
    }

    @Test func imageOnlySubmissionsKeepTheirIdentityAcrossUnknownRepliesButNotChangedImagesOrOwners() async {
        let project = Project(name: "Gamecards")
        let local = LogicalProjectRef(home: .local, id: project.id)
        let remote = LogicalProjectRef(home: .host(UUID()), id: project.id)
        let first = NativeImage(mimeType: "image/png", data: Data("first".utf8))
        let changed = NativeImage(mimeType: "image/png", data: Data("second".utf8))
        var accepted = false
        var requests: [(LogicalProjectRef, UUID, String, [NativeImage])] = []
        let model = LogicalProjectsModel(send: { _, _ in .projects([project]) }, pushed: { _ in [project] }, runtime: { ref, _, command in
            guard case .message(let operation, let text, let images) = command else {
                Issue.record("Unexpected command"); throw LogicalProjectsError("test", "Unexpected command")
            }
            requests.append((ref, operation, text, images ?? []))
            if !accepted { throw RemoteHostClientError.outcomeUnknown(message: "Reply lost") }
            return project
        })
        #expect(await model.sendMessage(local, text: "", images: [first]) == false)
        #expect(requests.count == 1 && requests[0].2.isEmpty && requests[0].3 == [first])
        #expect(await model.sendMessage(local, text: "", images: [first]) == false)
        #expect(requests[0].1 == requests[1].1)
        #expect(await model.sendMessage(local, text: "", images: [changed]) == false)
        #expect(requests[2].1 != requests[0].1)
        accepted = true
        #expect(await model.sendMessage(remote, text: "", images: [changed]))
        #expect(requests[3].0 == remote && requests[3].1 != requests[2].1)
        #expect(await model.sendMessage(local, text: "", images: [changed]))
        #expect(requests[4].1 == requests[2].1, "Another owner's receipt must not clear this owner's ambiguous operation")
        #expect(await model.sendMessage(local, text: "", images: [changed]))
        #expect(requests[5].1 != requests[4].1, "A new send after acknowledgement is a new user action")
        #expect(await model.sendMessage(local, text: "  ", images: []) == false)
        #expect(requests.count == 6)
    }

    @Test func everyEditCarriesTheRevisionTheViewShowed() async {
        let project = Project(name: "Gamecards", revision: 4)
        let owner = Owner([project])
        let model = model(owner, pushed: { owner.projects })
        let ref = LogicalProjectRef(home: .local, id: project.id)
        #expect(await model.edit(ref, name: "Gamecards 2", goal: "Goal"))
        #expect(owner.requests == [.edit(projectID: project.id, expectedRevision: 4, name: "Gamecards 2", goal: "Goal")])
        #expect(model.project(ref)?.revision == 5)
        // The next edit carries the answer's revision, not the first one.
        #expect(await model.edit(ref, name: "Gamecards 3", goal: ""))
        #expect(owner.requests.last == .edit(projectID: project.id, expectedRevision: 5, name: "Gamecards 3", goal: ""))
    }

    @Test func aStaleRefusalRereadsTheOwnerKeepsItsMessageAndNeverReplaysTheEdit() async {
        let shown = Project(name: "Gamecards", revision: 1)
        var moved = shown; moved.name = "Renamed elsewhere"; moved.revision = 3
        let owner = Owner([moved])
        let model = model(owner, pushed: { [shown] })
        let ref = LogicalProjectRef(home: .local, id: shown.id)
        #expect(await model.edit(ref, name: "Overwrite", goal: "") == false)
        #expect(model.failure == LogicalProjectFailure(message: "This project changed on its host.", stale: true))
        let edits = owner.requests.filter { if case .edit = $0 { true } else { false } }
        #expect(edits.count == 1, "the refused edit is not sent again with the new revision")
        #expect(owner.requests.contains(.list), "the refusal re-read the owner")
        #expect(model.project(ref)?.revision == 3 && model.project(ref)?.name == "Renamed elsewhere")
        #expect(owner.projects[0].name == "Renamed elsewhere")
    }

    @Test func anOlderAnswerNeverReplacesANewerRecordAndThePushedStateWinsAtTheSameRevision() async {
        let id = ProjectID()
        let newer = Project(id: id, name: "Newer", revision: 5)
        let older = Project(id: id, name: "Older", revision: 2)
        let owner = Owner([newer])
        var pushedList = [older]
        let model = model(owner, pushed: { pushedList })
        let ref = LogicalProjectRef(home: .local, id: id)
        await model.refresh(.local)
        #expect(model.project(ref)?.name == "Newer", "the owner's newer answer beats an older push")
        pushedList = [Project(id: id, name: "Pushed", revision: 7)]
        #expect(model.project(ref)?.name == "Pushed", "a newer push beats the remembered answer")
    }

    @Test func aBlankNameIsNeverSentToCreate() async {
        let owner = Owner([])
        let model = model(owner, pushed: { [] })
        let created = await model.create(home: .local, id: ProjectID(), name: "   ", goal: "", spaces: [])
        #expect(created == nil && owner.requests.isEmpty)
    }

    @Test func deleteHidesTheProjectAtOnceAndAFailureKeepsItVisible() async {
        let project = Project(name: "Gamecards")
        let owner = Owner([project])
        let model = model(owner, pushed: { owner.projects.isEmpty ? [project] : owner.projects })
        let ref = LogicalProjectRef(home: .local, id: project.id)
        owner.failure = LogicalProjectsError("project_failed", "Could not delete")
        #expect(await model.delete(ref) == false)
        #expect(model.project(ref) != nil && model.failure?.message == "Could not delete")
        owner.failure = nil
        #expect(await model.delete(ref))
        #expect(model.project(ref) == nil, "the deleted record is gone before the owner's push lands")
    }

    @Test func aRemoteOlderHostRefusalReadsAsItsOwnMessage() {
        let error = RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host.")
        #expect(LogicalProjectsModel.message(error) == "Update Shepherd on the host.")
        #expect(LogicalProjectsModel.isStale(RemoteHostClientError.rejected(code: "stale_project", message: "x")))
        #expect(!LogicalProjectsModel.isStale(error))
    }

    @Test func theNewProjectDraftNeedsANameAndKeepsOneIDForRetries() {
        var draft = NewLogicalProjectDraft()
        let id = draft.id
        #expect(!draft.canCreate)
        draft.name = "  Gamecards  "
        #expect(draft.canCreate && draft.id == id)
        draft.creating = true
        #expect(!draft.canCreate, "no second create while one is in flight")
    }

    @Test func newProjectsDefaultToReadyWithThreeThreadsAndTheStorageLimitsAreTheContractsOwn() {
        let project = Project(name: "New")
        #expect(!project.paused && project.settings.maxConcurrentWorkers == 3)
        #expect((1...6).contains(project.settings.maxConcurrentWorkers))
        #expect(Project.maximumInstructionsLength == 16_000, "the Memory counter reads this, not a copy")
    }
}
