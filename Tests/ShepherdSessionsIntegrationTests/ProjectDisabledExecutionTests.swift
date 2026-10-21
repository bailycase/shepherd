import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Disabled Project executor contracts", .serialized, .integrationTimeLimit)
struct ProjectDisabledExecutionTests {
    @Test func cancellationAndPauseProofSurviveColdHistoryAndRestartWhileDisabled() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        remote.server.onProjectExecutionLaunch = { _, _ in Issue.record("Disabled cancellation must never launch") }
        let client = try await remote.typed(); defer { client.disconnect() }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
        let cancelled = try await client.projectExecution(.cancel(key: key)).receipt
        #expect(cancelled.key == key && cancelled.phase == .cancelled && cancelled.assignment == nil)
        // A different operation's pause-before-execute must also leave cancellation proof, not start work.
        let pausedKey = ProjectExecutionKey(ownerID: key.ownerID, projectID: key.projectID, operationID: UUID())
        #expect(try await client.projectExecution(.pause(key: pausedKey)).receipt.phase == .cancelled)
        for _ in 0..<24 {
            let other = ProjectExecutionKey(ownerID: key.ownerID, projectID: key.projectID, operationID: UUID())
            _ = try await client.projectExecution(.cancel(key: other))
        }
        #expect(!remote.server.state.projectExecutions.contains { $0.key == key })
        #expect(try await client.projectExecution(.snapshot(key: key, watch: false)).receipt.phase == .cancelled)
        #expect(try await client.projectExecution(.cancel(key: key)).receipt.phase == .cancelled)
        #expect(try await client.projectExecution(.pause(key: key)).receipt.phase == .cancelled)
        #expect(remote.server.state.agents.isEmpty)
        let dir = remote.host.dir
        client.disconnect(); remote.host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: dir); defer { restarted.stop() }
        #expect(!restarted.server.projectsEnabled)
        #expect(try await restarted.server.projectExecution(.snapshot(key: key, watch: false)).receipt.phase == .cancelled)
        #expect(try await restarted.server.projectExecution(.snapshot(key: pausedKey, watch: false)).receipt.phase == .cancelled)
        #expect(try await restarted.server.projectExecution(.cancel(key: key)).receipt.phase == .cancelled)
        restarted.server.setProjectsEnabled(true)
        _ = try await restarted.server.logicalProjects(.list)
        let assignment = ProjectExecutionAssignment(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: SpaceID(), title: "Delayed", prompt: "tools:0")
        restarted.server.onProjectExecutionLaunch = { _, _ in Issue.record("A delayed execute must not bypass the cancellation tombstone") }
        #expect(try await restarted.server.projectExecution(.execute(assignment)).receipt.phase == .cancelled)
        #expect(restarted.server.state.agents.isEmpty)
    }

    @Test func disabledAdmissionAndContentRemainUnsupportedButStatusIsExactlyScoped() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        remote.server.onProjectExecutionLaunch = { _, _ in Issue.record("Disabled executor must never launch") }
        let client = try await remote.typed(); defer { client.disconnect() }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
        let assignment = ProjectExecutionAssignment(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: SpaceID(), title: "Disabled", prompt: "tools:0")
        let requests: [ProjectExecutionRequest] = [.execute(assignment), .resume(key: key), .result(key: key, offset: 0, sha256: nil), .worker(key: key)]
        for request in requests {
            do { _ = try await client.projectExecution(request); Issue.record("Disabled executor admitted a command or content read") }
            catch RemoteHostClientError.rejected(let code, let message) { #expect(code == "unsupported" && message.contains("Settings > Experiments")) }
        }
        _ = try await client.projectExecution(.cancel(key: key))
        let forged = ProjectExecutionKey(ownerID: UUID(), projectID: key.projectID, operationID: key.operationID)
        do { _ = try await client.projectExecution(.snapshot(key: forged, watch: false)); Issue.record("Another owner obtained the retained receipt") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == "no_such_execution") }
        let invalid = ProjectExecutionKey(ownerID: key.ownerID, projectID: ProjectID(rawValue: "../escape"), operationID: UUID())
        for request in [ProjectExecutionRequest.cancel(key: invalid), .pause(key: invalid), .snapshot(key: invalid, watch: false)] {
            do { _ = try await client.projectExecution(request); Issue.record("Invalid scope bypassed validation") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == "invalid_execution") }
        }
        #expect(remote.server.state.projectExecutions.count == 1 && remote.server.state.projectExecutions[0].key == key)
    }

    @Test func disabledCancellationCanCrossExperimentTransitionsButContentCannot() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
        let gate = DispatchSemaphore(value: 0), entered = Locked(false), scheduled = Locked(false)
        defer { gate.signal() }
        remote.server.projectHistoryReads.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("disabled executor history held") { entered.current }
        let cancel = Task { try await withCheckedThrowingContinuation { (c: CheckedContinuation<ProjectExecutionResult, Error>) in
            remote.server.queue.async {
                remote.server.projectExecutionOnQueue(.cancel(key: key)) { c.resume(with: $0) }
                scheduled.withValue { $0 = true }
            }
        } }
        try await eventually("uncached cancellation crossed the real dispatcher") { scheduled.current }
        remote.server.setProjectsEnabled(true); _ = try await remote.server.logicalProjects(.list)
        remote.server.setProjectsEnabled(false)
        try await eventually("executor disabled again") { !remote.server.projectsEnabled }
        gate.signal()
        #expect(try await cancel.value.receipt.phase == .cancelled)
        #expect(try await remote.server.projectExecution(.snapshot(key: key, watch: false)).receipt.phase == .cancelled)
        do { _ = try await remote.server.projectExecution(.result(key: key, offset: 0, sha256: nil)); Issue.record("Status exemption leaked into content reads") }
        catch let error as LogicalProjectsError { #expect(error.code == "unsupported") }
    }
}
