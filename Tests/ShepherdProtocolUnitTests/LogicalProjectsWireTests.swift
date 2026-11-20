import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

enum LogicalProjectsSamples {
    static let id = ProjectID(rawValue: "11111111-1111-4111-8111-111111111111")
    static let memory = ProjectMemoryID(rawValue: "22222222-2222-4222-8222-222222222222")
    static let space = SpaceID(rawValue: "33333333-3333-4333-8333-333333333333")
    private static let host = ProjectHostReference.remote(
        hostID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        bindingID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
    private static let requests: [LogicalProjectsRequest] = [
        .list, .get(projectID: id), .files(projectID: id, path: ""), .read(projectID: id, path: "reports/result.txt"), .create(projectID: id, name: "Project", goal: "Goal", linkedSpaceIDs: [space]),
        .edit(projectID: id, expectedRevision: 4, name: "Renamed", goal: "New goal"),
        .settings(projectID: id, expectedRevision: 4, settings: .init(conversationModel: "provider/a", threadModel: "provider/b", canRequestSpaceLinks: false)),
        .setPaused(projectID: id, expectedRevision: 4, paused: true),
        .addMemory(projectID: id, expectedRevision: 4, memoryID: memory, text: "Fact", source: "user"),
        .forgetMemory(projectID: id, expectedRevision: 4, memoryID: memory),
        .linkSpace(projectID: id, expectedRevision: 4, spaceID: space),
        .unlinkSpace(projectID: id, expectedRevision: 4, spaceID: space),
        .linkSpace(projectID: id, expectedRevision: 4, spaceID: space, host: host),
        .unlinkSpace(projectID: id, expectedRevision: 4, spaceID: space, host: host),
        .delete(projectID: id, expectedRevision: 4),
    ]

    private static let project: Project = {
        var project = Project(id: id, name: "Project")
        project.ownerID = Wire.projectKey.ownerID
        return project
    }()
    private static let results: [LogicalProjectsResult] = [
        .projects([project]),
        .project(project), .deleted(projectID: id),
        .files(.init(projectID: id, path: "reports", entries: [.init(name: "a.txt", relativePath: "reports/a.txt", kind: .file, size: 7, modifiedAt: 1000)], truncated: true)),
        .file(.init(projectID: id, relativePath: "a.txt", mimeType: "text/plain; charset=utf-8", data: Data("hello".utf8))),
    ]

    static let wireRequests = requests.map { RemoteRequest.logicalProjects(id: 19, request: $0) }
        + ProjectAutomationWireTests.wireRequests
    static let wireReplies = results.map { RemoteReply.logicalProjects(id: 19, result: $0) }
}

@Suite("Logical projects wire")
struct LogicalProjectsWireTests {
    typealias S = LogicalProjectsSamples

    @Test func oldSpaceAndAssignmentRequestsRemainOwnerLocal() throws {
        let link = Data("{\"linkSpace\":{\"projectID\":\"\(S.id)\",\"expectedRevision\":4,\"spaceID\":\"\(S.space)\"}}".utf8)
        #expect(try JSONDecoder().decode(LogicalProjectsRequest.self, from: link) == .linkSpace(projectID: S.id, expectedRevision: 4, spaceID: S.space))
        let op = UUID()
        let assign = Data("{\"assign\":{\"operationID\":\"\(op)\",\"spaceID\":\"\(S.space)\",\"title\":\"Task\",\"prompt\":\"Work\"}}".utf8)
        #expect(try JSONDecoder().decode(ProjectRuntimeRequest.self, from: assign) == .assign(operationID: op, spaceID: S.space, title: "Task", prompt: "Work"))
        let remote = ProjectRuntimeRequest.assign(operationID: op, spaceID: S.space, title: "Task", prompt: "Work", host: .remote(hostID: UUID(), bindingID: UUID()))
        #expect(try Wire.roundTrip(remote) == remote)
    }

    @Test(arguments: S.wireRequests)
    func everyRequestRoundTripsAndPreservesItsFence(_ wire: RemoteRequest) throws {
        #expect(try Wire.roundTrip(wire) == wire)
        #expect(try Wire.object(wire)["type"] as? String == "logicalProjects")
        guard case .logicalProjects(_, let request) = wire else {
            Issue.record("Expected a logicalProjects request")
            return
        }
        switch request {
        case .list: #expect(request.projectID == nil)
        case .get, .create, .files, .read: #expect(request.projectID == S.id && request.expectedRevision == nil)
        case .automation: #expect(request.projectID == S.id && request.expectedRevision == 7)
        default: #expect(request.projectID == S.id && request.expectedRevision == 4)
        }
    }

    @Test func oldArtifactEntryWithoutProvenanceDefaultsToNil() throws {
        let entry = try JSONDecoder().decode(LogicalProjectFileEntry.self, from: Data(#"{"name":"a","relativePath":"a","kind":"file","size":1,"modifiedAt":1000}"#.utf8))
        #expect(entry.taskID == nil)
    }

    @Test(arguments: S.wireReplies)
    func everyReplyRoundTrips(_ reply: RemoteReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }
}
