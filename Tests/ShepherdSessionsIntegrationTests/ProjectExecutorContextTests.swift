import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

@Suite("Executor context response grants", .integrationTimeLimit)
struct ProjectExecutorContextTests {
    @Test(arguments: ["current", "unrelated", "restore"])
    func theOriginalExecutorContextSurvivesOnlyItsOwnUnchangedRoute(_ change: String) async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        var assignment = try await rig.assignment("ask")
        assignment.memory = "Private whole owner fact [source: owner receipt]"
        assignment.memoryFacts = [.init(text: "Private whole owner fact", source: "owner receipt", createdAt: 1)]
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("executor waiting") { rig.receipt(assignment)?.phase == .waiting }
        let entered = Locked(false), release = Locked(false)
        defer { release.withValue { $0 = true } }
        try await rig.host.server.enqueue {
            rig.host.server.projectReplyWriteHeld = { entered.withValue { $0 = true }; return !release.current }
        }
        let reply = Task { [socketPath = rig.host.socketPath, workerID = assignment.reservedWorkerID, projectID = assignment.key.projectID] in
            let client = try ExtensionClient(path: socketPath)
            defer { client.closeConnection() }
            try client.send(.projectRuntime(id: 73, agentID: workerID,
                projectID: projectID, expectedRevision: 0, request: .read))
            return try client.readReply()
        }
        try await eventually("executor context queued before first write") { entered.current }
        if change == "restore" {
            var space = try #require(rig.host.server.state.spaces.first { $0.id == assignment.executorSpaceID })
            space.hidden = true; try await rig.host.server.updateSpace(space)
            space.hidden = false; try await rig.host.server.updateSpace(space)
        } else if change == "unrelated" {
            try await rig.host.server.addSpace(.init(name: "Unrelated", path: rig.host.dir.appendingPathComponent("other").path))
        }
        release.withValue { $0 = true }
        try await rig.host.server.enqueue {
            rig.host.server.projectReplyWriteHeld = nil
            rig.host.server.resumeProjectReplies()
        }
        switch try await reply.value {
        case .projectRuntime(_, let context, _, _):
            #expect(change != "restore")
            #expect(context.id == assignment.key.projectID)
            #expect(Project.briefMemory(context.memory).contains("Private whole owner fact"))
        case .error(_, let code, _):
            #expect(change == "restore")
            #expect(code == "project_scope")
        default: Issue.record("Missing executor context or precise route refusal")
        }
    }
}
