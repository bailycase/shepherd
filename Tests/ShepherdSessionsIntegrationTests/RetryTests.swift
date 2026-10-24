import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

private func failedCheckpoint(_ h: PiAgent) async throws -> NativeThreadSnapshot {
    let ready = try await h.ready()
    #expect(try await h.send("flaky", from: ready).wasAccepted)
    _ = try await h.snapshot { !$0.running && $0.checkpointRecovery?.checkpoint != nil }
    try await eventually("the failed turn's capture to finish") {
        try await h.server.enqueue { h.server.rpcThread(forAgent: h.agent.id)?.canRecoverCheckpoint(operationID: UUID()) == true }
    }
    return try await h.snapshot()
}

private func recoveryRequest(_ s: NativeThreadSnapshot, operation: UUID = UUID(), checkpoint: NativeRecoveryCheckpoint? = nil,
                             entry: String? = nil) throws -> NativeThreadRequest {
    .retry(expectedSessionID: s.piSessionID, generation: s.generation, operationID: operation,
           entryID: try entry ?? #require(s.messages.last { $0.role == "user" }?.entryID),
           checkpoint: checkpoint ?? s.checkpointRecovery?.checkpoint)
}

@Suite("Message-free checkpoint recovery", .integrationTimeLimit)
struct RetryTests {
    @Test(arguments: ["native", "engine"])
    func aDefiniteBusyRefusalAllowsOnlyANewExplicitOperation(boundary: String) async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host, env: boundary == "engine" ? ["STUB_PI_RECOVERY_BUSY_ONCE": "1"] : [:])
        let s = try await failedCheckpoint(h)
        let gate = RecoveryGate()
        if boundary == "native" {
            try await h.server.enqueue { h.server.rpcThread(forAgent: h.agent.id)?.beforePrompt = { gate.pending = $0 } }
        }
        let firstRequest = try recoveryRequest(s)
        let first = Task { try await h.request(firstRequest) }
        if boundary == "native" {
            try await eventually("recovery preparation") { try await h.server.enqueue { gate.pending != nil } }
            try await h.server.enqueue {
                h.server.rpcThread(forAgent: h.agent.id)?.inputActive = true
                gate.pending?(); gate.pending = nil
            }
        }
        #expect(try await first.value.failureCode == "busy")
        #expect(try await h.request(firstRequest).failureCode == "busy", "exact replay remains the same refusal")
        #expect(h.stdin("recover_checkpoint").count == (boundary == "engine" ? 1 : 0))
        try await h.server.enqueue {
            h.server.rpcThread(forAgent: h.agent.id)?.inputActive = false
            h.server.rpcThread(forAgent: h.agent.id)?.beforePrompt = nil
        }
        #expect(try await h.request(recoveryRequest(s)).wasAccepted, "a new explicit operation may follow a recorded, definite non-acceptance")
        _ = try await h.snapshot { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: flaky" }
        #expect(h.stdin("recover_checkpoint").count == (boundary == "engine" ? 2 : 1))
        #expect(h.stdin("prompt").count == 1)
    }

    @Test func preservesUsersAndOriginalFailureAndReplaysWithoutDispatch() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        let s = try await failedCheckpoint(h)
        let users = s.messages.filter { $0.role == "user" }
        let failed = try #require(s.messages.last { $0.status == "error" })
        let operation = UUID()
        let request = try recoveryRequest(s, operation: operation)
        #expect(try await h.request(request) == .accepted(operationID: operation))
        let done = try await h.snapshot { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: flaky" }
        #expect(done.messages.filter { $0.role == "user" } == users)
        #expect(done.messages.contains(failed))
        #expect(try await h.request(request) == .accepted(operationID: operation))
        #expect(h.stdin("recover_checkpoint").count == 1)
        #expect(h.stdin("prompt").count == 1, "only the fixture's original human message")
        #expect(!h.stdin().contains { ($0["message"] as? String)?.contains("shepherd-retry") == true })
        #expect(try await h.request(recoveryRequest(s)).failureCode == "recovery_reserved")
        #expect(h.stdin("recover_checkpoint").count == 1)
    }

    @Test func staleWrongTurnBusyAndUnsupportedRefuseBeforeAnyDelivery() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        let s = try await failedCheckpoint(h)
        let checkpoint = try #require(s.checkpointRecovery?.checkpoint)
        #expect(try await h.request(.retry(expectedSessionID: s.piSessionID, generation: "stale", operationID: UUID(),
                                          entryID: "wrong", checkpoint: checkpoint)).failureCode == "stale_session")
        #expect(try await h.request(recoveryRequest(s, entry: "wrong")).failureCode == "not_latest")
        #expect(try await h.request(recoveryRequest(s, checkpoint: NativeRecoveryCheckpoint(token: "stale", failedEntryID: checkpoint.failedEntryID))).failureCode == "recovery_stale")
        #expect(try await h.request(.retry(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                          entryID: "legacy")).failureCode == "recovery_unsupported")
        #expect(try await h.send("slow", from: s).wasAccepted)
        _ = try await h.snapshot { $0.running }
        #expect(try await h.request(recoveryRequest(s)).failureCode == "busy")
        #expect(h.stdin("recover_checkpoint").isEmpty && h.stdin("prompt").count == 2)
        #expect(h.stdin("prompt").last?["message"] as? String == "slow")
        #expect(try await h.request(.abort(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID())).wasAccepted)
    }

    @Test(arguments: [false, true])
    func resolvedAssignmentsRefuseOriginalInputEvenAfterTaskRetirement(retired: Bool) async throws {
        let host = try ScratchServer(); defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        let failed = try await failedCheckpoint(h)
        let entry = try #require(failed.messages.last { $0.role == "user" }?.entryID)
        let input = UUID()
        // Supply the Project/native delivery association at the same seam used by consumed-input metadata.
        try await host.server.enqueue { host.server.rpcThread(forAgent: h.agent.id)?.operationsByEntry[entry] = input }
        host.server.setProjectsEnabled(true)
        guard case .project(let project) = try await host.server.logicalProjects(.create(projectID: .init(), name: "Terminal fixture", goal: "", linkedSpaceIDs: [h.agent.spaceID])) else {
            Issue.record("Project fixture was not created"); return
        }
        let task = ProjectTask(operationID: input, workerAgentID: h.agent.id, spaceID: h.agent.spaceID, title: "Resolved", prompt: "flaky", phase: .resolved)
        _ = try await host.server.updateRuntimeProject(project.id) { p in
            p.tasks = [task]
            if retired {
                p.tasks += (0..<16).map { ProjectTask(operationID: UUID(), spaceID: h.agent.spaceID, title: "Other \($0)", prompt: "done", phase: .resolved) }
            }
        }
        _ = try await host.server.updateRuntimeProject(project.id) { $0.name = "Committed terminal fixture" }
        #expect(host.server.state.projects[0].tasks.contains { $0.id == task.id } == !retired)
        #expect(try await h.request(recoveryRequest(failed)).failureCode == "task_resolved")
        #expect(h.stdin("recover_checkpoint").isEmpty && h.stdin("prompt").count == 1)
        #expect(try await h.snapshot().messages == failed.messages)
    }

    @Test func oldEngineOffersNoCapabilityAndDoesNotInjectInput() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host, env: ["STUB_PI_RECOVERY_UNSUPPORTED": "1"])
        let initial = try await h.ready()
        #expect(try await h.send("flaky", from: initial).wasAccepted)
        let failed = try await h.snapshot { !$0.running && $0.messages.last?.status == "error" }
        #expect(!failed.supportedActions.contains("checkpointRecovery"))
        #expect(failed.supportedActions.contains("retry"), "old clients must route to the refusing endpoint, not resend")
        #expect(try await h.request(.retry(expectedSessionID: failed.piSessionID, generation: failed.generation,
                                          operationID: UUID(), entryID: "legacy")).failureCode == "recovery_unsupported")
        let checkpoint = NativeRecoveryCheckpoint(token: "unknown", failedEntryID: "unknown")
        #expect(try await h.request(recoveryRequest(failed, checkpoint: checkpoint)).failureCode == "recovery_unsupported")
        #expect(h.stdin("recover_checkpoint").isEmpty && h.stdin("prompt").count == 1)
    }

    @Test func unknownReceiptIsReadByExactOperationAndNeverDispatched() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        let s = try await failedCheckpoint(h)
        let checkpoint = try #require(s.checkpointRecovery?.checkpoint)
        let operation = UUID()
        let entry = try #require(s.messages.last { $0.role == "user" }?.entryID)
        try await host.server.enqueue {
            let thread = try #require(host.server.rpcThread(forAgent: h.agent.id))
            let directory = try #require(thread.originStore?.directory)
            try CheckpointRecoveryIntent(sessionID: s.piSessionID, entryID: entry, checkpoint: checkpoint, operationID: operation,
                binding: CheckpointRecoveryBinding(agentID: h.agent.id, spaceID: h.agent.spaceID, tabID: h.agent.tabID, paneID: try #require(h.agent.paneID)),
                nativeGeneration: s.generation).reserve(in: directory)
        }
        #expect(try await h.request(recoveryRequest(s, operation: operation)).failureCode == "outcome_unknown")
        #expect(h.stdin("recover_checkpoint").isEmpty)
        let reads = h.stdin("get_recovery_operation")
        #expect(reads.count == 1 && reads[0]["operationID"] as? String == operation.uuidString)
        #expect(try await h.request(recoveryRequest(s)).failureCode == "recovery_reserved")
        #expect(try await h.snapshot().messages == s.messages)
    }

    @Test(arguments: ["current", "missing-capability", "disconnected"])
    func remoteRecoveryIsBoundToItsExactClientAndCapability(boundary: String) async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let h = try await PiAgent.launch(on: remote.host)
        let s = try await failedCheckpoint(h)
        let request = try recoveryRequest(s)
        if boundary == "missing-capability" {
            let client = try await remote.raw(authenticated: false)
            _ = try await client.hello(token: remote.token, capabilities: [RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeRetryCapability])
            try client.send(.nativeThread(id: 9, agentID: h.agent.id, request: request))
            guard case .nativeThread(9, .failure("recovery_unsupported", let message)) = try await client.next() else {
                Issue.record("an old client must be refused"); return
            }
            #expect(message.contains("message-free") && h.stdin("recover_checkpoint").isEmpty)
        } else {
            let client = try await remote.typed()
            defer { client.disconnect() }
            let gate = RecoveryGate()
            try await remote.server.enqueue { remote.server.rpcThread(forAgent: h.agent.id)?.beforePrompt = { gate.pending = $0 } }
            let action = Task { try await client.nativeThread(agentID: h.agent.id, request: request) }
            try await eventually("the remote recovery preparation") { try await remote.server.enqueue { gate.pending != nil } }
            if boundary == "disconnected" { remote.server.stopRemoteListener() }
            try await remote.server.enqueue { gate.pending?(); gate.pending = nil }
            if boundary == "disconnected" {
                do {
                    _ = try await action.value
                    Issue.record("a disconnected recovery cannot have a known transport outcome")
                } catch RemoteHostClientError.outcomeUnknown { }
                try await eventually("the disconnected preparation to finish") {
                    try await remote.server.enqueue { remote.server.rpcThread(forAgent: h.agent.id)?.recoveryPending == nil }
                }
                #expect(h.stdin("recover_checkpoint").isEmpty)
            } else {
                #expect(try await action.value.wasAccepted)
                _ = try await h.snapshot { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: flaky" }
                #expect(h.stdin("recover_checkpoint").count == 1)
            }
        }
        #expect(h.stdin("prompt").count == 1)
    }

    @Test(arguments: ["stop", "new-session", "revoked", "project-assignment", "binding-restored", "ownership-restored", "dialog", "unrelated-space", "renamed"])
    func acceptanceIsRecheckedAfterAsynchronousPreparation(boundary: String) async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let h = try await PiAgent.launch(on: host)
        let s = try await failedCheckpoint(h)
        let request = try recoveryRequest(s)
        let gate = RecoveryGate()
        try await host.server.enqueue {
            host.server.rpcThread(forAgent: h.agent.id)?.beforePrompt = { ready in gate.pending = ready }
        }
        let action = Task { try await h.request(request) }
        try await eventually("recovery's context preparation") { try await host.server.enqueue { gate.pending != nil } }
        let busy = try await h.snapshot()
        #expect(busy.running, "preparation and delivery uncertainty are visible as busy")
        switch boundary {
        case "dialog":
            let question = try JSONDecoder().decode(RPCExtensionUIRequest.self, from: Data(#"{"id":"fixture-approval","method":"confirm","title":"Approve FAKE work?"}"#.utf8))
            try await host.server.enqueue { host.server.rpcThread(forAgent: h.agent.id)?.handle(.extensionUIRequest(question)) }
        case "stop":
            #expect(try await h.request(.abort(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID())).wasAccepted)
        case "new-session":
            try await host.server.enqueue { host.server.rpcThread(forAgent: h.agent.id)?.session.send(.newSession) }
            _ = try await h.snapshot { $0.generation != s.generation }
        case "project-assignment":
            var assigned = h.agent
            assigned.executionFor = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
            try await host.server.updateAgent(assigned)
        case "binding-restored":
            var moved = h.agent
            moved.worktreePath = host.dir.appendingPathComponent("alternate").path
            try await host.server.updateAgent(moved)
            try await host.server.updateAgent(h.agent)
        case "ownership-restored":
            var assigned = h.agent
            assigned.executionFor = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
            try await host.server.updateAgent(assigned)
            try await host.server.updateAgent(h.agent)
        case "renamed":
            var renamed = h.agent
            renamed.name = "renamed fixture"
            try await host.server.updateAgent(renamed)
        case "revoked":
            let space = try #require(host.server.state.spaces.first { $0.id == h.agent.spaceID })
            var hidden = space
            hidden.hidden = true
            try await host.server.updateSpace(hidden)
            try await host.server.updateSpace(space)
        default:
            try await host.server.addSpace(Space(name: "unrelated", path: host.dir.appendingPathComponent("unrelated").path))
        }
        try await host.server.enqueue { gate.pending?(); gate.pending = nil }
        let result = try await action.value
        if boundary == "unrelated-space" || boundary == "renamed" {
            #expect(result.wasAccepted)
            _ = try await h.snapshot { !$0.running && $0.messages.last?.blocks.first?.text == "Recovered: flaky" }
            #expect(h.stdin("recover_checkpoint").count == 1)
        } else {
            #expect(!result.wasAccepted)
            #expect(h.stdin("recover_checkpoint").isEmpty)
        }
        #expect(h.stdin("prompt").count == 1)
        if boundary == "dialog" {
            #expect(h.stdin("extension_ui_response").isEmpty, "recovery cannot answer an approval dialog")
            #expect(try await h.snapshot().dialogs.map(\.id) == ["fixture-approval"])
        }
    }
}

private final class RecoveryGate: @unchecked Sendable {
    // Owned by the scratch server's serial queue.
    var pending: (() -> Void)?
}

@Suite("Recovery intent persistence", .integrationTimeLimit)
struct RecoveryIntentTests {
    @Test func onlyAnExactDurableBusyProofPermitsTheNextExclusiveSlot() throws {
        let dir = try makeScratchDirectory("recovery-busy-intent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binding = CheckpointRecoveryBinding(agentID: AgentID(), spaceID: SpaceID(), tabID: TabID(), paneID: PaneID())
        let first = CheckpointRecoveryIntent(sessionID: "session", entryID: "user",
            checkpoint: NativeRecoveryCheckpoint(token: "token", failedEntryID: "failure"), operationID: UUID(), binding: binding, nativeGeneration: "g")
        var second = first; second.operationID = UUID(); second.checkpoint.token = "new-leaf-token"
        try first.reserve(in: dir)
        let original = try Data(contentsOf: first.url(in: dir))
        #expect(throws: (any Error).self) { try second.reserve(in: dir) }
        try first.recordBusy(in: dir)
        #expect(try second.existing(in: dir) == nil)
        try second.reserve(in: dir)
        #expect(try second.existing(in: dir) == second)
        #expect(try first.existing(in: dir) == first)
        #expect(try Data(contentsOf: first.url(in: dir)) == original)
        var third = second; third.operationID = UUID()
        #expect(throws: (any Error).self) { try third.reserve(in: dir) }
        #expect(try third.existing(in: dir) == second, "an unknown second delivery still blocks every new operation")
    }

    @Test func creationIsExclusiveConflictsRemainInspectableAndStableOperationIdentitySurvivesReopen() throws {
        let dir = try makeScratchDirectory("recovery-intent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = NativeRecoveryCheckpoint(token: "token", failedEntryID: "entry")
        let operation = checkpoint.operationID(sessionID: "session")
        #expect(operation == NativeRecoveryCheckpoint(token: "new-process-token", failedEntryID: "entry").operationID(sessionID: "session"))
        #expect(operation != checkpoint.operationID(sessionID: "other-session"))
        #expect(operation != checkpoint.operationID(sessionID: "session", refusal: 1))
        let binding = CheckpointRecoveryBinding(agentID: AgentID(), spaceID: SpaceID(), tabID: TabID(), paneID: PaneID())
        let first = CheckpointRecoveryIntent(sessionID: "session", entryID: "user", checkpoint: checkpoint, operationID: operation,
                                             binding: binding, nativeGeneration: "g")
        try first.reserve(in: dir)
        #expect(throws: (any Error).self) { try first.reserve(in: dir) }
        #expect(try first.existing(in: dir) == first)
        let second = CheckpointRecoveryIntent(sessionID: "session", entryID: "user", checkpoint: checkpoint, operationID: UUID(),
                                              binding: binding, nativeGeneration: "g")
        #expect(throws: (any Error).self) { try second.reserve(in: dir) }
        #expect(try second.existing(in: dir) == first)
    }
}

private extension NativeThreadResult {
    var wasAccepted: Bool { if case .accepted = self { true } else { false } }
}
