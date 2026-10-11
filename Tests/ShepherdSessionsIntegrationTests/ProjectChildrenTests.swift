import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project tool policy and legacy controller fences", .integrationTimeLimit)
struct ProjectChildrenTests {
    // Upgrade compatibility only: no production request may create this state anymore.
    // Seed a previously admitted controller to retain Stop/drain, takeover and epoch regressions.
    private func authorize(_ pi: PiAgent, on host: ScratchServer) async throws -> (ExtensionClient, ProjectChildScope) {
        let snapshot = try await pi.snapshot("native Project user turn") {
            let user = ($0.messages + $0.provisional).last { $0.role == "user" }
            return user?.operationID != nil && user?.status != "pending"
        }
        let client = try ExtensionClient(path: host.socketPath)
        try client.send(.helloChildren(agentID: pi.agent.id, projectScopes: true))
        try client.send(.childScope(id: 100, agentID: pi.agent.id, sessionID: snapshot.piSessionID,
                                   userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        let reply = try client.readReply()
        guard case .error(100, "project_scope", _) = reply else { throw WireError("Project admitted helpers: \(reply)") }
        let scope = try await host.server.enqueue {
            let scope = try #require(host.server.currentProjectChildScope[pi.agent.id])
            #expect(!host.server.projectChildAdmitted.contains(scope))
            host.server.projectChildAdmitted.insert(scope)
            host.server.projectChildDrained.remove(scope)
            return scope
        }
        #expect(scope.workerAgentID == pi.agent.id && scope.generation == snapshot.generation)
        return (client, scope)
    }

    private func expectDelegationRefused(_ pi: PiAgent) async throws {
        let snapshot = try await pi.ready()
        let client = try ExtensionClient(path: pi.host.socketPath)
        defer { client.closeConnection() }
        // Even a forged/stale scope request, before controller registration, fails by ownership.
        try client.send(.childScope(id: 1, agentID: pi.agent.id, sessionID: "stale", userTimestamp: nil))
        guard case .error(1, "project_scope", _) = try client.readReply() else { throw WireError("Unregistered Project helper admitted") }
        try client.send(.helloChildren(agentID: pi.agent.id, projectScopes: true))
        try client.send(.childScope(id: 2, agentID: pi.agent.id, sessionID: snapshot.piSessionID,
                                   userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(2, "project_scope", _) = try client.readReply() else { throw WireError("Project helper admitted") }
        try client.send(.spawnAgent(id: 3, agentID: pi.agent.id, cwd: pi.host.dir.path, prompt: "bypass"))
        guard case .error(3, "project_scope", _) = try client.readReply() else { throw WireError("Project peer admitted") }
        try client.send(.createAutomation(id: 4, name: "Bypass", prompt: "loop", cwd: pi.host.dir.path, enabled: true, start: true))
        guard case .error(4, "project_scope", _) = try client.readReply() else { throw WireError("Project automation admitted without speaksFor") }
        for action in [NativeSubagentAction.resume, .continue, .message] {
            await #expect(throws: RemoteHostClientError.self) {
                try await pi.request(.subagentCommand(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
                    operationID: UUID(), runID: "old-child", action: action, text: "continue"))
            }
        }
        try await pi.server.enqueue {
            #expect(pi.server.projectChildAdmitted.isEmpty, "Refusal never mutates activation admission")
        }
    }

    @Test func localWorkersCannotDelegateEvenAfterSettlementOrManualTakeover() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "tools:1"))
        try await eventually("worker consumed") { rig.agents.current.values.first?.stdin("prompt").count == 1 }
        let pi = try #require(rig.agents.current.values.first)
        try await expectDelegationRefused(pi)
        pi.finishTool(1)
        try await eventually("worker settled without helpers") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        try await expectDelegationRefused(pi)
        _ = try await pi.send("tools:2 manual", from: pi.ready())
        _ = try await pi.snapshot("manual turn") { $0.running }
        try await expectDelegationRefused(pi)
        #expect(pi.stdin("prompt").count == 2, "Manual coding work remains available")
    }

    @Test func executorMembershipRefusesDelegationOfflineAfterSettlementAndManualTakeover() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        let owner = try await rig.remote.typed()
        _ = try await owner.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        owner.disconnect()
        #expect(rig.host.server.state.projects.isEmpty, "Executor authority comes from its retained assignment")
        try await expectDelegationRefused(pi)
        pi.finishTool(1)
        try await eventually("executor settled without helpers") { rig.receipt(assignment)?.phase == .settled }
        try await expectDelegationRefused(pi)
        _ = try await pi.send("tools:2 manual", from: pi.ready())
        _ = try await pi.snapshot("manual executor turn") { $0.running }
        try await expectDelegationRefused(pi)
    }

    @Test func executorManualTurnKeepsMembershipWithoutOldPayloadOrActivationAuthority() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        var assignment = try await rig.assignment("tools:1")
        assignment.instructions = "private original instructions"; assignment.memory = "private original memory"
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let assigned = try await pi.snapshot("assigned native turn consumed before steering") {
            $0.running && ($0.messages + $0.provisional).last { $0.role == "user" }?.operationID == assignment.key.operationID
        }
        try await eventually("assigned execution evidence persisted") { rig.receipt(assignment)?.phase == .sent }
        _ = try await pi.send("tools:2 manual takeover", delivery: .steer, from: assigned)
        pi.finishTool(1)
        _ = try await pi.snapshot("manual user turn consumed") {
            $0.running && ($0.messages + $0.provisional).last { $0.role == "user" }?.blocks.contains { $0.text.contains("manual takeover") } == true
        }
        try await eventually("manual takeover invalidates original execution") { rig.receipt(assignment)?.phase == .unknown }
        try await expectDelegationRefused(pi)
        let context = try #require(rig.host.server.state.projectContext(for: pi.agent.id))
        #expect(context.tasks.first?.phase == .unknown && context.paused)
        #expect(context.settings.instructions.isEmpty && context.memory.isEmpty && context.tasks.first?.prompt.isEmpty == true)
        try await rig.host.server.enqueue { #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil) }
        #expect(try await pi.ready().running, "Manual coding still runs without Project execution authority")
    }

    @Test func unrelatedThreadsKeepChildAdmissionAndPeerTools() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        _ = try await rig.create()
        let pi = try await PiAgent.launch(on: rig.host)
        let snapshot = try await pi.ready()
        let client = try ExtensionClient(path: rig.host.socketPath)
        defer { client.closeConnection() }
        try client.send(.helloChildren(agentID: pi.agent.id, projectScopes: true))
        try client.send(.childScope(id: 1, agentID: pi.agent.id, sessionID: snapshot.piSessionID,
                                   userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .childScope(1, nil, nil) = try client.readReply() else { throw WireError("Ordinary thread restricted") }
        rig.host.server.setAgentMessagePolicy(.always)
        let requests = Locked<[AgentPeerRequest]>([])
        rig.host.server.onAgentPeerRequest = { request, reply in requests.withValue { $0.append(request) }; reply(.ok) }
        try client.send(.spawnAgent(id: 2, agentID: pi.agent.id, cwd: rig.host.dir.path, prompt: "ordinary work"))
        #expect(try await client.reply() == .ok(id: 2))
        #expect(requests.current == [.spawn(agentID: pi.agent.id, cwd: rig.host.dir.path, prompt: "ordinary work")])
    }

    @Test func deletingALocalProjectReleasesServerMembershipWithoutAPermanentWorkerFlag() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "hello"))
        try await eventually("worker settled") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let pi = try #require(rig.agents.current.values.first)
        try await expectDelegationRefused(pi)
        let paused = try await rig.perform(project.id, .pause)
        _ = try await rig.host.server.logicalProjects(.delete(projectID: project.id, expectedRevision: paused.revision))
        #expect(rig.host.server.state.projectContext(for: pi.agent.id) == nil, "A fresh ordinary launch has no Project marker")
        let snapshot = try await pi.ready(), client = try ExtensionClient(path: rig.host.socketPath)
        defer { client.closeConnection() }
        try client.send(.helloChildren(agentID: pi.agent.id, projectScopes: true))
        try client.send(.childScope(id: 1, agentID: pi.agent.id, sessionID: snapshot.piSessionID,
                                   userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .childScope(1, nil, nil) = try client.readReply() else { throw WireError("Deleted Project left a permanent server restriction") }
    }

    @Test func localSettlementRetainsItsSlotAndPauseWaitsForTheMatchingControllerACK() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "tools:1"))
        try await eventually("worker consumed") { rig.agents.current.values.first?.stdin("prompt").count == 1 }
        let pi = try #require(rig.agents.current.values.first)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        pi.finishTool(1)
        guard case .projectChildren(let drainID, scope, .drain) = try controller.readReply() else { throw WireError("Expected helper drain") }
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase == .running)
        _ = try await rig.perform(project.id, .pause)
        guard case .projectChildren(let stopID, scope, .stop) = try controller.readReply() else { throw WireError("Expected scoped stop") }
        #expect(pi.stdin("abort").isEmpty)
        #expect(rig.host.server.state.projects.first?.interruptPending == true)
        // An ACK on another connection cannot discharge this controller's command.
        let stranger = try ExtensionClient(path: rig.host.socketPath)
        try stranger.send(.childCommandResult(id: stopID, error: nil))
        try stranger.send(.childScope(id: 101, agentID: pi.agent.id, sessionID: scope.sessionID, userTimestamp: nil))
        guard case .error(101, "project_scope", _) = try stranger.readReply() else { throw WireError("Unregistered controller accepted") }
        #expect(pi.stdin("abort").isEmpty)
        try controller.send(.childCommandResult(id: drainID, error: nil))
        // Drain is not the cancellation ACK: Stop still owns the admission/process-exit fence.
        #expect(rig.host.server.state.projects.first?.interruptPending == true)
        try controller.send(.childCommandResult(id: stopID, error: nil))
        try await eventually("native stop after helpers exited") { !pi.stdin("abort").isEmpty }
        try await eventually("Project settled after helper ACK") {
            rig.host.server.state.projects.first?.tasks.first?.phase == .settled && rig.host.server.state.projects.first?.interruptPending == false
        }
        _ = try await pi.send("tools:1 manual", from: pi.ready())
        let manual = try await pi.snapshot("manual native turn") {
            let user = ($0.messages + $0.provisional).last { $0.role == "user" }
            return $0.running && user?.status != "pending" && user?.blocks.contains { $0.text.contains("manual") } == true
        }
        try controller.send(.childScope(id: 102, agentID: pi.agent.id, sessionID: scope.sessionID,
                                       userTimestamp: (manual.messages + manual.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(102, "project_scope", _) = try controller.readReply() else { throw WireError("Manual Project turn admitted helpers") }
    }

    @Test(arguments: [false, true])
    func customContinuationsKeepAuthorityButManualTakeoverAndScopedStopReleaseOnlyTheOldTask(drainBeforeTakeover: Bool) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Managed", prompt: "tools:1"))
        try await eventually("managed worker") { rig.agents.current.values.first?.stdin("prompt").count == 1 }
        let pi = try #require(rig.agents.current.values.first)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: pi.agent.id))
            let notice = RPCMessage(role: "custom", content: [.text("untrusted helper result")], customType: "shepherd-child", display: false)
            thread.handle(.messageStart(message: notice)); thread.handle(.messageEnd(message: notice))
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == scope)
            #expect(!rig.host.server.projectChildClosed.contains(scope))
        }
        var pendingDrain: Int?
        if drainBeforeTakeover {
            pi.finishTool(1)
            let reply = try controller.readReply()
            guard case .projectChildren(let id, scope, .drain) = reply else { throw WireError("Missing original-scope drain; received \(reply)") }
            pendingDrain = id
        }
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: pi.agent.id))
            // Raw Pi input is still a real user message, but has no host operation ID.
            #expect(thread.session.send(.prompt(message: "tools:2 HUMAN_RESULT_MUST_NOT_BECOME_PROJECT_RESULT", streamingBehavior: .steer)))
        }
        if !drainBeforeTakeover { pi.finishTool(1) }
        try await eventually("native manual takeover recorded") { rig.host.server.state.projects.first?.tasks.first?.phase == .unknown }
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: pi.agent.id))
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil)
            #expect(rig.host.server.projectChildTakenOver.contains(scope))
            thread.handle(.messageStart(message: .init(role: "custom", content: [.text("late original child result")], customType: "shepherd-child", display: false)))
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil, "Late notices never restore superseded authority")
        }
        _ = try await rig.perform(project.id, .pause)
        var stopReply = try controller.readReply()
        if case .projectChildren(let drain, scope, .drain) = stopReply {
            #expect(pendingDrain == nil, "At most one drain is in flight per exact scope")
            pendingDrain = drain
            stopReply = try controller.readReply()
        }
        guard case .projectChildren(let id, scope, .stop) = stopReply else { throw WireError("Missing original-scope stop; received \(stopReply)") }
        if let pendingDrain {
            try controller.send(.childCommandResult(id: pendingDrain, error: nil))
            try await eventually("earlier drain acknowledged without acknowledging Stop") {
                try await rig.host.server.enqueue { rig.host.server.projectChildDrained.contains(scope) }
            }
        }
        try await rig.host.server.enqueue {
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil)
            #expect(rig.host.server.projectChildClosed.contains(scope))
            #expect(!rig.host.server.projectChildStopped.contains(scope), "A drain ACK cannot substitute for Stop")
        }
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase == .unknown)
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase.occupiesSlot == true)
        #expect(pi.stdin("abort").isEmpty)
        try controller.send(.childCommandResult(id: id, error: nil))
        try await eventually("old activation safely released") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let stopped = try #require(rig.host.server.state.projects.first?.tasks.first)
        #expect(stopped.error?.contains("No manual result") == true)
        #expect(pi.stdin("abort").isEmpty)
        #expect(try await pi.ready().running)
        let resolved = try await rig.perform(project.id, .resolve(taskID: stopped.id))
        #expect(resolved.tasks.first?.phase == .resolved)
        #expect(!resolved.messages.contains { $0.text.contains("HUMAN_RESULT_MUST_NOT_BECOME_PROJECT_RESULT") })
    }

    @Test func localPauseRetainsTheNativeQuestionWhileStoppingItsHelpers() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("local question") { rig.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        let pi = try #require(rig.agents.current.values.first)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        let original = try await pi.snapshot("original question") { !$0.dialogs.isEmpty }
        _ = try await rig.perform(project.id, .pause)
        guard case .projectChildren(let id, scope, .stop) = try controller.readReply() else { throw WireError("Missing local question helper stop") }
        #expect(rig.host.server.state.projects.first?.interruptPending == true)
        try controller.send(.childCommandResult(id: id, error: nil))
        try await eventually("local helpers acknowledged") { rig.host.server.state.projects.first?.interruptPending == false }
        let retained = try await pi.snapshot("same native question") { !$0.dialogs.isEmpty }
        #expect(retained.dialogs.first?.id == original.dialogs.first?.id)
        #expect(pi.stdin("abort").isEmpty)
        #expect(chmod(rig.host.dir.path, 0o500) == 0)
        defer { _ = chmod(rig.host.dir.path, 0o700) }
        await #expect(throws: (any Error).self) { try await rig.perform(project.id, .resume) }
        try await rig.host.server.enqueue {
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == scope)
            #expect(rig.host.server.projectChildClosed.contains(scope))
        }
        #expect(rig.host.server.state.projects.first?.tasks.first?.childScopeEpoch == nil)
        #expect(chmod(rig.host.dir.path, 0o700) == 0)
        _ = try await rig.perform(project.id, .resume)
        let (freshController, fresh) = try await authorize(pi, on: rig.host)
        #expect(fresh.epoch == scope.epoch + 1 && fresh.key == scope.key)
        #expect(rig.host.server.state.projects.first?.tasks.first?.childScopeEpoch == fresh.epoch)
        _ = try await rig.perform(project.id, .resume)
        try await rig.host.server.enqueue {
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == fresh)
            #expect(!rig.host.server.projectChildClosed.contains(fresh), "Publisher may use only the new scope")
            #expect(rig.host.server.projectChildClosed.contains(scope), "Stale publishers remain fenced")
        }
        _ = try await rig.host.server.nativeThread(agentID: pi.agent.id,
            request: .answer(expectedSessionID: scope.sessionID, generation: scope.generation, operationID: UUID(),
                             dialogID: try #require(retained.dialogs.first?.id), answer: .confirm(value: true)))
        guard case .projectChildren(let drain, fresh, .drain) = try freshController.readReply() else { throw WireError("Resumed local work did not drain its fresh helpers") }
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase.occupiesSlot == true)
        try freshController.send(.childCommandResult(id: drain, error: nil))
        try await eventually("resumed question and helpers settle") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
    }

    @Test func executorPauseKeepsTheQuestionButDisconnectNeverClaimsHelpersStopped() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("ask")
        let owner = try await rig.remote.typed()
        _ = try await owner.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("executor question") { rig.receipt(assignment)?.phase == .waiting }
        owner.disconnect()
        let (controller, scope) = try await authorize(pi, on: rig.host) // Already assigned work needs no live owner.
        #expect(scope.key == assignment.key)
        let reconnected = try await rig.remote.typed(); defer { reconnected.disconnect() }
        let paused = Task { try await reconnected.projectExecution(.pause(key: assignment.key)) }
        guard case .projectChildren(_, scope, .stop) = try controller.readReply() else { throw WireError("Missing question helper stop") }
        #expect(rig.receipt(assignment)?.helpersStopped == false)
        controller.closeConnection()
        await #expect(throws: RemoteHostClientError.self) { try await paused.value }
        #expect(rig.receipt(assignment)?.phase == .waiting)
        #expect(rig.receipt(assignment)?.helpersStopped == false)
        #expect(pi.stdin("abort").isEmpty)
        await #expect(throws: RemoteHostClientError.self) { try await reconnected.projectExecution(.resume(key: assignment.key)) }
        let retry = try ExtensionClient(path: rig.host.socketPath)
        try retry.send(.helloChildren(agentID: pi.agent.id, projectScopes: true))
        let question = try await pi.snapshot("question survives helper disconnection") { !$0.dialogs.isEmpty }
        try retry.send(.childScope(id: 103, agentID: pi.agent.id, sessionID: scope.sessionID,
                                  userTimestamp: (question.messages + question.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(103, "project_scope", _) = try retry.readReply() else { throw WireError("Project policy lost on reconnect") }
        let again = Task { try await reconnected.projectExecution(.pause(key: assignment.key)) }
        guard case .projectChildren(let id, scope, .stop) = try retry.readReply() else { throw WireError("Missing retried scope stop") }
        try retry.send(.childCommandResult(id: id, error: nil))
        let result = try await again.value
        #expect(result.receipt.helpersStopped == true && result.receipt.phase == .waiting)
        #expect(pi.stdin("abort").isEmpty)
        try await rig.host.server.enqueue {
            #expect(rig.host.server.canResumeProjectChildScope(scope))
            var wrong = scope; wrong.generation = "not-the-native-generation"
            rig.host.server.currentProjectChildScope[pi.agent.id] = wrong
            rig.host.server.projectChildClosed.insert(wrong)
            rig.host.server.projectChildStopped.insert(wrong)
            rig.host.server.projectChildDrained.insert(wrong)
            #expect(!rig.host.server.canResumeProjectChildScope(wrong), "Even matching saved ACKs cannot authorize the wrong native generation")
            rig.host.server.currentProjectChildScope[pi.agent.id] = scope
            wrong = scope; wrong.workerAgentID = .init()
            #expect(!rig.host.server.canResumeProjectChildScope(wrong))
        }
        #expect(chmod(rig.host.dir.path, 0o500) == 0)
        defer { _ = chmod(rig.host.dir.path, 0o700) }
        await #expect(throws: RemoteHostClientError.self) { try await reconnected.projectExecution(.resume(key: assignment.key)) }
        #expect(rig.receipt(assignment)?.ownerPaused == true && rig.receipt(assignment)?.childScopeEpoch == nil)
        try await rig.host.server.enqueue { #expect(rig.host.server.projectChildClosed.contains(scope)) }
        #expect(chmod(rig.host.dir.path, 0o700) == 0)
        let resumed = try await reconnected.projectExecution(.resume(key: assignment.key))
        let duplicate = try await reconnected.projectExecution(.resume(key: assignment.key))
        #expect(duplicate.receipt == resumed.receipt, "Duplicate Resume neither rotates nor restarts its deadline")
        let (freshController, fresh) = try await authorize(pi, on: rig.host)
        #expect(fresh.epoch == scope.epoch + 1 && fresh.key == scope.key)
        #expect(resumed.receipt.childScopeEpoch == fresh.epoch)
        try await rig.host.server.enqueue {
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == fresh)
            #expect(!rig.host.server.projectChildClosed.contains(fresh))
            #expect(rig.host.server.projectChildClosed.contains(scope))
            #expect(rig.host.server.projectChildScope(resumed.receipt) == fresh)
        }
        _ = try await reconnected.projectExecution(.answer(key: assignment.key,
            request: .answer(expectedSessionID: scope.sessionID, generation: scope.generation, operationID: UUID(),
                             dialogID: try #require(question.dialogs.first?.id), answer: .confirm(value: true))))
        guard case .projectChildren(let drain, fresh, .drain) = try freshController.readReply() else { throw WireError("Resumed executor did not drain its fresh helpers") }
        #expect(rig.receipt(assignment)?.phase.active == true)
        try freshController.send(.childCommandResult(id: drain, error: nil))
        try await eventually("resumed executor question and helpers settle") { rig.receipt(assignment)?.phase == .settled }
    }

    @Test(arguments: [false, true])
    func resumeNeverRestoresAuthorityAfterNativeManualConsumptionOfAParkedQuestion(duringSave: Bool) async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("ask")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("parked question") { rig.receipt(assignment)?.phase == .waiting }
        let (controller, scope) = try await authorize(pi, on: rig.host)
        let pause = Task { try await rig.host.server.projectExecution(.pause(key: assignment.key)) }
        guard case .projectChildren(let id, scope, .stop) = try controller.readReply() else { throw WireError("Missing scoped Stop") }
        try controller.send(.childCommandResult(id: id, error: nil))
        _ = try await pause.value
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        var resume: Task<ProjectExecutionResult, Error>?
        if duringSave {
            rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
            try await eventually("Resume disk gate installed") { entered.current }
            resume = Task { try await rig.host.server.projectExecution(.resume(key: assignment.key)) }
            try await eventually("Resume staged before manual consumption") {
                try await rig.host.server.enqueue { !rig.host.server.executionSaves.isEmpty }
            }
        }
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: pi.agent.id))
            // The trusted native event, not helper prose or a caller-supplied operation, is the fence.
            thread.handle(.messageStart(message: .init(role: "user", content: [.text("manual takeover")], timestamp: Date().timeIntervalSince1970 * 1000)))
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil)
            #expect(!rig.host.server.canResumeProjectChildScope(scope))
        }
        gate.signal()
        if let resume { _ = try await resume.value }
        else {
            await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.projectExecution(.resume(key: assignment.key)) }
            #expect(rig.receipt(assignment)?.childScopeEpoch == nil)
        }
        try await eventually("takeover persisted") { rig.receipt(assignment)?.phase == .unknown }
        #expect(pi.stdin("abort").isEmpty)
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: pi.agent.id))
            thread.handle(.messageStart(message: .init(role: "custom", content: [.text("late old result")], customType: "shepherd-child", display: false)))
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil)
            #expect(rig.host.server.projectChildClosed.contains(scope))
        }
    }

    @Test func executorRootSettlementWaitsForHelpersAndFollowUpGetsANewScope() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        try await eventually("consumed activation receipt persisted") { rig.receipt(assignment)?.phase == .sent }
        pi.finishTool(1)
        guard case .projectChildren(let id, scope, .drain) = try controller.readReply() else { throw WireError("Missing executor drain") }
        #expect(rig.receipt(assignment)?.phase == .sent)
        try controller.send(.childCommandResult(id: id, error: nil))
        try await eventually("executor helpers settled") { rig.receipt(assignment)?.phase == .settled }
        try await rig.host.server.enqueue {
            #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nil)
            #expect(rig.host.server.projectChildClosed.contains(scope))
        }
        var followUp = assignment
        followUp.key.operationID = UUID(); followUp.prompt = "tools:2 new activation"
        _ = try await rig.host.server.projectExecution(.execute(followUp))
        try await eventually("new operation consumed") { rig.receipt(followUp)?.phase == .sent }
        let (next, nextScope) = try await authorize(pi, on: rig.host)
        #expect(nextScope.key == followUp.key && nextScope != scope)
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        let snapshot = try await pi.snapshot("follow-up still running") { $0.running }
        try next.send(.childScope(id: 107, agentID: pi.agent.id, sessionID: nextScope.sessionID,
                                 userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(107, "project_scope", _) = try next.readReply() else { throw WireError("Follow-up admitted helpers") }
        try await rig.host.server.enqueue { #expect(rig.host.server.currentProjectChildScope[pi.agent.id] == nextScope) }
        #expect(pi.stdin("abort").isEmpty)
    }

    @Test func executorManualTakeoverReleasesTheOldReservationOnlyAfterScopedHelperStop() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        _ = try await pi.send("tools:2 manual", delivery: .steer, from: pi.ready())
        pi.finishTool(1)
        try await eventually("executor native takeover") { rig.receipt(assignment)?.phase == .unknown }
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        guard case .projectChildren(let id, scope, .stop) = try controller.readReply() else { throw WireError("Missing superseded helper stop") }
        #expect(rig.receipt(assignment)?.phase == .interruptPending)
        try controller.send(.childCommandResult(id: id, error: nil))
        try await eventually("old executor slot released with exit evidence") { rig.receipt(assignment)?.phase == .cancelled }
        #expect(rig.receipt(assignment)?.resultText == nil)
        #expect(pi.stdin("abort").isEmpty)
        #expect(try await pi.ready().running)
    }

    @Test func nativeStopDuringProjectWorkClosesHelpersBeforeAcknowledgingTheParentAbort() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        let stopping = Task { try await pi.request(.abort(expectedSessionID: scope.sessionID, generation: scope.generation, operationID: UUID())) }
        guard case .projectChildren(let id, scope, .stop) = try controller.readReply() else { throw WireError("Native Stop bypassed helpers") }
        #expect(pi.stdin("abort").isEmpty)
        try controller.send(.childCommandResult(id: id, error: nil))
        guard case .accepted = try await stopping.value else { throw WireError("Native Stop not acknowledged") }
        #expect(pi.stdin("abort").count == 1)
        try await eventually("native stopped task settles") { rig.receipt(assignment)?.phase == .settled }
    }

    @Test func disconnectedHelperControllerCannotDefeatTheExecutorDeadlineOrReleaseItsReservation() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        try await rig.host.server.enqueue { rig.host.server.executionDuration = 2 }
        let assignment = try await rig.assignment("tools:1 deadline disconnected")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        controller.closeConnection()
        try await eventually("deadline aborts root despite missing helper controller") { pi.stdin("abort").count == 1 }
        _ = try await pi.snapshot("root is stopped") { !$0.running }
        #expect(rig.receipt(assignment)?.phase == .interruptPending)
        #expect(rig.receipt(assignment)?.helpersStopped != true)
        try await rig.host.server.enqueue {
            #expect(rig.host.server.projectChildClosed.contains(scope))
            #expect(!rig.host.server.projectChildStopped.contains(scope))
            #expect(!rig.host.server.projectChildDrained.contains(scope))
        }
        _ = try await pi.send("tools:2 manual after failed cleanup", from: pi.ready())
        try await eventually("manual takeover") { rig.receipt(assignment)?.phase == .unknown }
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        try await eventually("failed helper retry finished") {
            try await rig.host.server.enqueue { !rig.host.server.executionInterrupts.contains(assignment.key) }
        }
        #expect(pi.stdin("abort").count == 1, "A retry must not abort the later manual turn")
        #expect(try await pi.ready().running)
        #expect(rig.receipt(assignment)?.phase != .cancelled)
    }

    @Test(arguments: [false, true])
    func localPauseTimeoutStopsOnlyItsOriginalRootAndNeverAcknowledgesHelperCleanup(manualTakeover: Bool) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Unacknowledged helpers", prompt: "tools:1"))
        try await eventually("managed worker") { rig.agents.current.values.first?.stdin("prompt").count == 1 }
        let pi = try #require(rig.agents.current.values.first)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        _ = try await rig.perform(project.id, .pause)
        guard case .projectChildren(_, scope, .stop) = try controller.readReply() else { throw WireError("Missing scoped Stop") }
        if manualTakeover {
            _ = try await pi.send("tools:2 manual during helper timeout", delivery: .steer, from: pi.ready())
            pi.finishTool(1)
            try await eventually("manual message supersedes managed turn") { rig.host.server.state.projects.first?.tasks.first?.phase == .unknown }
        }
        // Exercise the production acknowledgement timeout, not a fabricated successful reply.
        try await eventually("unacknowledged helper Stop times out", timeout: .seconds(25)) {
            try await rig.host.server.enqueue { !rig.host.server.projectInterrupts.contains(pi.agent.id) }
        }
        if manualTakeover {
            #expect(pi.stdin("abort").isEmpty)
            #expect(try await pi.ready().running)
        } else {
            #expect(pi.stdin("abort").count == 1)
            _ = try await pi.snapshot("managed root stopped despite helper timeout") { !$0.running }
        }
        #expect(rig.host.server.state.projects.first?.interruptPending == true)
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase.occupiesSlot == true)
        try await rig.host.server.enqueue {
            #expect(rig.host.server.projectChildClosed.contains(scope))
            #expect(!rig.host.server.projectChildStopped.contains(scope))
            #expect(!rig.host.server.projectInterruptAcknowledged.contains(pi.agent.id))
        }
    }

    @Test func executionDeadlineUsesTheSameScopedStopAndWaitsForHelperExitEvidence() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        try await rig.host.server.enqueue { rig.host.server.executionDuration = 2 }
        let assignment = try await rig.assignment("tools:1 deadline")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        let (controller, scope) = try await authorize(pi, on: rig.host)
        guard case .projectChildren(let id, scope, .stop) = try controller.readReply() else { throw WireError("Deadline did not stop helpers") }
        #expect(rig.receipt(assignment)?.phase == .interruptPending)
        #expect(pi.stdin("abort").isEmpty)
        try controller.send(.childCommandResult(id: id, error: nil))
        try await eventually("bounded activation cancelled after helper ACK") { rig.receipt(assignment)?.phase == .cancelled }
        #expect(pi.stdin("abort").count == 1)
    }

    @Test func oldControllerCannotClaimScopedCancellationAndScopeLookupCannotChangeAgentOrSession() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("executor sent") { rig.receipt(assignment)?.phase == .sent }
        let (controller, scope) = try await authorize(pi, on: rig.host)
        try controller.send(.childScope(id: 104, agentID: AgentID(), sessionID: scope.sessionID, userTimestamp: nil))
        guard case .error(104, _, _) = try controller.readReply() else { throw WireError("Other agent accepted") }
        try controller.send(.childScope(id: 105, agentID: pi.agent.id, sessionID: "wrong", userTimestamp: nil))
        guard case .error(105, _, _) = try controller.readReply() else { throw WireError("Other session accepted") }
        controller.closeConnection()
        let old = try ExtensionClient(path: rig.host.socketPath)
        try old.send(.helloChildren(agentID: pi.agent.id))
        try old.send(.childScope(id: 106, agentID: pi.agent.id, sessionID: scope.sessionID, userTimestamp: nil))
        _ = try old.readReply() // Orders registration before cancellation.
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        try await eventually("cancellation remains pending") { rig.receipt(assignment)?.phase == .interruptPending }
        #expect(pi.stdin("abort").isEmpty)
    }
}
