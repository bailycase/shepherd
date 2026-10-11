import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Logical projects wire")
struct LogicalProjectsWireTests {
    static let id = ProjectID(rawValue: "11111111-1111-4111-8111-111111111111")
    static let memory = ProjectMemoryID(rawValue: "22222222-2222-4222-8222-222222222222")
    static let space = SpaceID(rawValue: "33333333-3333-4333-8333-333333333333")
    static let requests: [LogicalProjectsRequest] = [
        .list, .get(projectID: id), .files(projectID: id, path: ""), .read(projectID: id, path: "reports/result.txt"), .create(projectID: id, name: "Project", goal: "Goal", linkedSpaceIDs: [space]),
        .edit(projectID: id, expectedRevision: 4, name: "Renamed", goal: "New goal"),
        .settings(projectID: id, expectedRevision: 4, settings: .init(conversationModel: "provider/a", threadModel: "provider/b", canRequestSpaceLinks: false)),
        .setPaused(projectID: id, expectedRevision: 4, paused: true),
        .addMemory(projectID: id, expectedRevision: 4, memoryID: memory, text: "Fact", source: "user"),
        .forgetMemory(projectID: id, expectedRevision: 4, memoryID: memory),
        .linkSpace(projectID: id, expectedRevision: 4, spaceID: space),
        .unlinkSpace(projectID: id, expectedRevision: 4, spaceID: space),
        .linkSpace(projectID: id, expectedRevision: 4, spaceID: space, host: .remote(hostID: UUID(), bindingID: UUID())),
        .unlinkSpace(projectID: id, expectedRevision: 4, spaceID: space, host: .remote(hostID: UUID(), bindingID: UUID())),
        .delete(projectID: id, expectedRevision: 4),
    ]

    @Test func oldSpaceAndAssignmentRequestsRemainOwnerLocal() throws {
        let link = Data("{\"linkSpace\":{\"projectID\":\"\(Self.id)\",\"expectedRevision\":4,\"spaceID\":\"\(Self.space)\"}}".utf8)
        #expect(try JSONDecoder().decode(LogicalProjectsRequest.self, from: link) == .linkSpace(projectID: Self.id, expectedRevision: 4, spaceID: Self.space))
        let op = UUID()
        let assign = Data("{\"assign\":{\"operationID\":\"\(op)\",\"spaceID\":\"\(Self.space)\",\"title\":\"Task\",\"prompt\":\"Work\"}}".utf8)
        #expect(try JSONDecoder().decode(ProjectRuntimeRequest.self, from: assign) == .assign(operationID: op, spaceID: Self.space, title: "Task", prompt: "Work"))
        let remote = ProjectRuntimeRequest.assign(operationID: op, spaceID: Self.space, title: "Task", prompt: "Work", host: .remote(hostID: UUID(), bindingID: UUID()))
        #expect(try Wire.roundTrip(remote) == remote)
    }

    @Test(arguments: requests)
    func everyRequestRoundTripsAndPreservesItsFence(_ request: LogicalProjectsRequest) throws {
        let wire = RemoteRequest.logicalProjects(id: 19, request: request)
        #expect(try Wire.roundTrip(wire) == wire)
        #expect(try Wire.object(wire)["type"] as? String == "logicalProjects")
        switch request {
        case .list: #expect(request.projectID == nil)
        case .get, .create, .files, .read: #expect(request.projectID == Self.id && request.expectedRevision == nil)
        default: #expect(request.projectID == Self.id && request.expectedRevision == 4)
        }
    }

    @Test func oldArtifactEntryWithoutProvenanceDefaultsToNil() throws {
        let entry = try JSONDecoder().decode(LogicalProjectFileEntry.self, from: Data(#"{"name":"a","relativePath":"a","kind":"file","size":1,"modifiedAt":1000}"#.utf8))
        #expect(entry.taskID == nil)
    }

    @Test(arguments: [LogicalProjectsResult.projects([Project(id: id, name: "Project")]),
                      .project(Project(id: id, name: "Project")), .deleted(projectID: id),
                      .files(.init(projectID: id, path: "reports", entries: [.init(name: "a.txt", relativePath: "reports/a.txt", kind: .file, size: 7, modifiedAt: 1000)], truncated: true)),
                      .file(.init(projectID: id, relativePath: "a.txt", mimeType: "text/plain; charset=utf-8", data: Data("hello".utf8)))])
    func everyReplyRoundTrips(_ result: LogicalProjectsResult) throws {
        let wire = RemoteReply.logicalProjects(id: 19, result: result)
        #expect(try Wire.roundTrip(wire) == wire)
    }
}
