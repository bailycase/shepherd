import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project runtime admission revocation", .integrationTimeLimit)
struct ProjectRuntimeRevocationTests {
    typealias Rig = ProjectRuntimeTests.Rig

    @Test func pauseAheadOfReadyTransactionRevokesItsSendFenceWithoutPoisoningResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let worker = try await PiAgent.launch(on: rig.host)
        _ = try await worker.ready()
        let task = ProjectTask(operationID: UUID(), workerAgentID: worker.agent.id, spaceID: worker.agent.spaceID,
                               title: "Reserved worker", prompt: "hello after explicit Resume", phase: .reserved)
        _ = try await rig.host.server.updateRuntimeProject(p.id) { $0.tasks.append(task) }
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("file writer held") { entered.current }
        let write = Task { try await rig.host.server.updateRuntimeProject(p.id) { _ in } }
        try await eventually("runtime writer stages ahead of Pause") {
            try await rig.host.server.enqueue { rig.host.server.projectRuntimeWriterBusy && rig.host.server.logicalProjectSaveCount == 1 }
        }
        let pause = Task { try await rig.perform(p.id, .pause) }
        try await eventually("Pause queues ahead of ready transition") {
            try await rig.host.server.enqueue { rig.host.server.projectRuntimeWriters.count == 1 }
        }
        try await rig.host.server.enqueue {
            rig.host.server.projectRunStarts[p.id] = Date()
            rig.host.server.projectRuntimeReady(agentID: worker.agent.id)
        }
        try await eventually("ready transition holds its unsent operation behind Pause") {
            try await rig.host.server.enqueue {
                rig.host.server.projectRuntimeWriters.count == 2 && rig.host.server.projectPromptInFlight[worker.agent.id] == task.operationID
            }
        }
        gate.signal()
        _ = try await write.value; _ = try await pause.value
        try await eventually("revoked send clears without a persistence barrier") {
            try await rig.host.server.enqueue {
                let project = rig.host.server.store.state.projects.first
                return project?.paused == true && project?.interruptPending == false
                    && rig.host.server.projectPromptInFlight[worker.agent.id] == nil
                    && !rig.host.server.projectPersistenceFailed.contains(p.id)
            }
        }
        #expect(worker.stdin("prompt").isEmpty)
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase == .reserved)
        _ = try await rig.perform(p.id, .resume)
        try await eventually("explicit Resume delivers the original reservation once") {
            worker.stdin("prompt").count == 1 && rig.host.server.state.projects.first?.tasks.first?.phase == .settled
        }
        #expect(rig.host.server.state.projects.first?.tasks.first?.operationID == task.operationID)
    }

    @Test func coordinatorExitMakesAcceptedUnconsumedMessageUnknownAndNewMessageCanRunAfterResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        let sent = try await rig.perform(p.id, .message(operationID: operation, text: "tools:0 hold-start"))
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator launched") { rig.agents.current[coordinator] != nil }
        let old = try #require(rig.agents.current[coordinator])
        _ = try await old.snapshot("accepted without native user consumption") { $0.running }
        #expect(rig.host.server.state.projects.first?.messages.first?.phase == .delivering)
        try await rig.host.server.enqueue { #expect(!rig.host.server.projectStartedPrompts.contains(coordinator)) }
        await rig.host.server.stopKeepingAgent(sessionID: old.sessionID)
        try await rig.host.waitForExit(old.sessionID)
        try await eventually("coordinator exit preserves unknown delivery") {
            rig.host.server.state.projects.first?.paused == true && rig.host.server.state.projects.first?.messages.first?.phase == .unknown
        }
        #expect(rig.host.server.state.projects.first?.messages.first?.id == operation)
        _ = try await rig.perform(p.id, .resume)
        _ = try await rig.perform(p.id, .message(operationID: UUID(), text: "new assigned message"))
        try await eventually("new message delivered without replaying unknown input") {
            rig.host.server.state.projects.first?.messages.last?.phase == .delivered
        }
        #expect(rig.host.server.state.projects.first?.messages.first?.phase == .unknown)
        #expect(rig.agents.current[coordinator]?.stdin("prompt").compactMap { $0["message"] as? String } == ["tools:0 hold-start", "new assigned message"])
    }
}
