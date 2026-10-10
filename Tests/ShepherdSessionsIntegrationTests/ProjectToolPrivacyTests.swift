import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project tool output privacy", .integrationTimeLimit)
struct ProjectToolPrivacyTests {
    typealias Rig = ProjectRuntimeTests.Rig

    @Test func memorySourceLabelsAreRedactedBeforeTheyReachModelFacingData() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create()
        let sent = try await rig.perform(project.id, .message(operationID: UUID(), text: "hello"))
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator ready") { rig.agents.current[coordinator] != nil }
        _ = try await #require(rig.agents.current[coordinator]).snapshot("initial prompt settled") { !$0.running && $0.messages.count > 2 }
        try await eventually("initial Project delivery receipt committed") { rig.host.server.state.projects.first?.messages.first?.phase == .delivered }
        let source = "password=very-secret-memory-label"
        let current = try #require(rig.host.server.state.projects.first)
        _ = try await rig.host.server.logicalProjects(.addMemory(projectID: project.id, expectedRevision: current.revision,
            memoryID: .init(), text: "Use the current API version.", source: source))
        let result = try await rig.host.server.projectTool(agentID: coordinator, projectID: project.id,
            expectedRevision: try #require(rig.host.server.state.projects.first).revision, request: .read)
        #expect(result.memory.first?.text == "Use the current API version.")
        #expect(result.memory.first?.source == NativeRedaction.projectData(source))
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("very-secret-memory-label"))
        #expect(rig.host.server.state.projects.first?.memory.first?.source == source,
                "The local editable record is retained; only provider-bound data is redacted.")
    }

    @Test func forgettingMemoryRemovesItFromFreshToolResultsWithoutChangingRetryPayloads() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create()
        let sent = try await rig.perform(project.id, .message(operationID: UUID(), text: "hello"))
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator ready") { rig.agents.current[coordinator] != nil }
        _ = try await #require(rig.agents.current[coordinator]).snapshot("initial prompt settled") { !$0.running && $0.messages.count > 2 }
        try await eventually("initial Project delivery receipt committed") { rig.host.server.state.projects.first?.messages.first?.phase == .delivered }
        let marker = "forgotten-memory-boundary-marker"
        let memory = ProjectMemory(text: marker, source: "A decision", createdAt: 1)
        let destination = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        var task = ProjectTask(operationID: UUID(), spaceID: .init(), title: "Remote task", prompt: "Check the API", phase: .reserved,
                               host: destination)
        // Use the actual placement context producer, then retain the same immutable assignment
        // in both owner task state and its executor receipt, as transport does at reservation.
        var context = try #require(rig.host.server.state.projects.first)
        context.memory = [memory]
        let assignment = try rig.host.server.projectAssignment(context, task: task, defaultModel: "test/model")
        let receipt = ProjectExecutionReceipt(key: assignment.key, assignment: assignment, phase: .reserved)
        task.executionAssignment = assignment
        task.executionReceipt = receipt
        let reservedTask = task
        let reserved = try await rig.host.server.updateRuntimeProject(project.id) {
            $0.memory = [memory]
            $0.tasks.append(reservedTask)
        }
        _ = try await rig.host.server.logicalProjects(.forgetMemory(projectID: project.id, expectedRevision: reserved.revision, memoryID: memory.id))
        let stored = try #require(rig.host.server.state.projects.first)
        for request in [ProjectRuntimeRequest.read, .inspect(taskID: task.id)] {
            let result = try await rig.host.server.projectTool(agentID: coordinator, projectID: project.id,
                expectedRevision: stored.revision, request: request)
            #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(marker))
            let projected = try #require(result.tasks.first)
            #expect(projected.id == task.id && projected.operationID == task.operationID && projected.phase == .reserved)
            #expect(projected.executionAssignment == nil && projected.executionReceipt?.assignment == nil)
            #expect(projected.executionReceipt?.key == receipt.key && projected.executionReceipt?.phase == receipt.phase)
        }
        let durable = try #require(rig.host.server.state.projects.first)
        #expect(durable.memory.isEmpty)
        #expect(durable.tasks.first?.executionAssignment == assignment)
        #expect(durable.tasks.first?.executionReceipt == receipt)
    }
}
