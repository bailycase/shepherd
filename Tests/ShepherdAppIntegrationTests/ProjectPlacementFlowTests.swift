import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Owner to executor placement", .mainActorExclusive)
@MainActor
struct ProjectPlacementFlowTests {
    @MainActor private final class Rig {
        let owner: AppHarness
        let executor: AppHarness
        let spaceA: Space
        let spaceB: Space
        var host: ProjectHostReference = .local
        var projectID = ProjectID()
        var project: Project { owner.server.state.projects.first { $0.id == projectID }! }
        init() throws {
            owner = try AppHarness(modelCatalog: { .init(models: ["anthropic/claude-sonnet-4-5"], defaultModel: "anthropic/claude-sonnet-4-5") })
            executor = try AppHarness(modelCatalog: { .init(models: ["anthropic/claude-sonnet-4-5"], defaultModel: "anthropic/claude-sonnet-4-5") })
            // Each host opts in on its own; the owner is also the viewer of the executor.
            owner.settings.projectsEnabled = true; executor.settings.projectsEnabled = true
            spaceA = Space(name: "Owner sources", path: owner.dir.path)
            // Deliberately the same SpaceID: host identity, never ID or path alone, chooses it.
            spaceB = Space(id: spaceA.id, name: "Executor sources", path: executor.dir.path)
        }
        func start() async throws {
            try StubPi.installAsEngine()
            try Data(#"{"model":{"provider":"anthropic","id":"claude-sonnet-4-5"}}"#.utf8)
                .write(to: executor.dir.appendingPathComponent("stub-pi-startup.json"))
            _ = try await executor.start(); _ = try await owner.start()
            try await owner.server.addSpace(spaceA); try await executor.server.addSpace(spaceB)
            let tokenURL = executor.dir.appendingPathComponent("placement-token")
            let port = try executor.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            owner.remoteHosts.addHost(name: "Executor", host: "127.0.0.1", port: port, token: token)
            try await eventuallyOnMain("authenticated executor") { self.owner.remoteHosts.connections.first?.phase == .connected }
            let config = try #require(owner.remoteHosts.hosts.first)
            host = .remote(hostID: config.id, bindingID: config.bindingID)
            _ = try await owner.server.logicalProjects(.create(projectID: projectID, name: "Owner", goal: "", linkedSpaceIDs: [spaceA.id]))
            _ = try await owner.server.logicalProjects(.settings(projectID: projectID, expectedRevision: project.revision,
                settings: .init(threadModel: "anthropic/claude-sonnet-4-5", allowedHosts: [.local, host])))
            _ = try await owner.server.logicalProjects(.linkSpace(projectID: projectID, expectedRevision: project.revision, spaceID: spaceB.id, host: host))
        }
        func perform(_ request: ProjectRuntimeRequest) async throws {
            try await eventuallyAsync("revision-fenced owner action") {
                do {
                    _ = try await self.owner.vm.projectCoordinator.perform(projectID: self.projectID, expectedRevision: self.project.revision, request: request)
                    return true
                } catch let error as LogicalProjectsError where ["stale_project", "project_busy"].contains(error.code) { return false }
            }
        }
        func assign(_ prompt: String, remote: Bool = true) async throws {
            try await perform(.assign(operationID: UUID(), spaceID: spaceA.id, title: "Assigned work", prompt: prompt, host: remote ? host : nil))
        }
        func connectViewer() async throws -> RemoteHostClient {
            let tokenURL = owner.dir.appendingPathComponent("worker-viewer-token")
            let port = try owner.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let viewer = RemoteHostClient()
            _ = try await viewer.connect(host: "127.0.0.1", port: port, token: token, clientName: "Worker viewer")
            return viewer
        }
        func stop() { owner.stop(); executor.stop() }
    }

    @Test func oneOwnerCountsLocalAndRemoteReservationsAndNeverFallsBackToAnEqualSpaceID() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("slow", remote: false)
        try await r.assign("slow"); try await r.assign("slow"); try await r.assign("hello")
        try await eventuallyOnMain("three shared slots and queued fourth") {
            r.project.tasks.filter { $0.phase.occupiesSlot }.count == 3 && r.project.tasks.last?.phase == .queued
                && r.executor.server.state.projectExecutions.filter { $0.phase == .sent }.count == 2
        }
        #expect(r.owner.server.state.agents.count == 1)
        #expect(r.executor.server.state.agents.count == 2)
        #expect(r.executor.server.state.projects.isEmpty)
        let remoteTask = try #require(r.project.tasks.first { $0.executionAssignment != nil })
        let assignment = try #require(remoteTask.executionAssignment)
        #expect(assignment.key.ownerID == r.project.ownerID)
        #expect(assignment.model == "anthropic/claude-sonnet-4-5")
        #expect(r.executor.server.state.tabs.allSatisfy { $0.layout.leaves.allSatisfy { $0.cwd == r.spaceB.path } })
        let receipt = try #require(r.executor.server.state.projectExecutions.first { $0.key == assignment.key })
        let client = try #require(r.owner.remoteHosts.connections.first?.browserClient)
        // Losing execute's response is just another immutable-key execute, never another worker.
        _ = try await client.projectExecution(.execute(assignment))
        #expect(r.executor.server.state.agents.count == 2)
        _ = try await r.executor.server.nativeThread(agentID: remoteTask.workerAgentID,
            request: .abort(expectedSessionID: try #require(receipt.sessionID), generation: try #require(receipt.generation), operationID: UUID()))
        try await eventuallyOnMain("actual remote settlement releases fourth") { r.project.tasks.last?.phase == .settled }
        #expect(r.executor.server.state.agents.count == 3)
        let followed = try #require(r.project.tasks.last)
        try await r.perform(.followUp(taskID: followed.id, operationID: UUID(), text: "hello again"))
        try await eventuallyOnMain("followup reuses proven worker") {
            r.project.tasks.last?.phase == .settled && r.project.tasks.last?.executionReceipt?.previousOperationID == followed.operationID
        }
        #expect(r.executor.server.state.agents.count == 3)
        #expect(r.project.tasks.last?.workerAgentID == followed.workerAgentID)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func aHumanProjectChatReplyClosesTheOriginalNativeSelectExactlyOnce(configuration: (Bool, Bool)) async throws {
        let (remote, paused) = configuration
        let r = try Rig(); defer { r.stop() }; try await r.start()
        r.owner.scratch.useRealPeerCheck()
        let coordinatorDir = r.owner.dir.appendingPathComponent("logical-projects/\(r.projectID)")
        let workerDir = remote ? r.executor.dir : r.owner.dir
        func script(_ prompts: [String: Any], in directory: URL) throws {
            try JSONSerialization.data(withJSONObject: ["prompts": prompts, "socket": r.owner.scratch.socketPath]).write(to: directory.appendingPathComponent("project-script.json"))
        }
        try script(["Start planning": []], in: coordinatorDir)
        try script(["Choose release target": [["ask": ["title": "Where should this release go?", "options": ["Staging", "Production"]]]]], in: workerDir)
        try await r.perform(.message(operationID: UUID(), text: "Start planning"))
        try await eventuallyOnMain("initial human turn consumed") { r.project.messages.first?.phase == .delivered }
        try await r.assign("Choose release target", remote: remote)
        try await eventuallyOnMain("question event consumed by coordinator") {
            r.project.tasks.first?.phase == .waiting && r.project.messages.contains { $0.source?.kind == .question && $0.phase == .delivered }
        }
        let task = try #require(r.project.tasks.first)
        let event = try #require(r.project.messages.first { $0.source?.kind == .question })
        let operation = UUID(), human = UUID(), reply = "Use the safer staging option, please."
        let forged = try ExtensionClient(path: r.owner.scratch.socketPath)
        try forged.send(.projectRuntime(id: 71, agentID: try #require(r.project.coordinatorAgentID), projectID: r.projectID,
            expectedRevision: r.project.revision, request: .answer(operationID: operation, taskID: task.id,
                questionEventID: event.id, humanReplyID: human, answer: .select(value: "Production"))))
        guard case .error(71, "wrong_process", _) = try forged.readReply() else {
            Issue.record("A different process spoke as the coordinator"); return
        }
        forged.closeConnection()
        let relay: [String: Any] = ["owner": ["project_answer": ["taskID": task.id.rawValue,
            "questionEventID": event.id.uuidString, "operationID": operation.uuidString, "answer": ["select": ["value": "Staging"]]]]]
        // The second identical tool invocation models a lost reply; it must not dispatch twice.
        try script([reply: [relay, relay], "Also list the open issues": []], in: coordinatorDir)
        let unrelated = UUID()
        try await r.perform(.message(operationID: unrelated, text: "Also list the open issues"))
        try await eventuallyOnMain("unrelated human work does not answer the pending question") {
            r.project.messages.first { $0.id == unrelated }?.phase == .delivered
        }
        #expect(r.project.tasks.first?.phase == .waiting && r.project.tasks.first?.pendingAnswer == nil)
        #expect(r.project.messages.allSatisfy { $0.answerReceipts == nil })
        if paused {
            try await r.perform(.pause)
            try await eventuallyOnMain("Project parked with original question") { !r.project.interruptPending }
        }
        try await r.perform(.message(operationID: human, text: reply))
        let worker = remote ? r.executor.server : r.owner.server
        if paused {
            #expect(r.project.messages.first { $0.id == human }?.phase == .queued)
            #expect(r.project.messages.first { $0.id == human }?.answerReceipts == nil)
            guard case .snapshot(let snapshot) = try await worker.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else {
                Issue.record("Missing parked worker"); return
            }
            #expect(snapshot.dialogs.first?.id == event.source?.dialogID)
            try await r.perform(.resume)
        }
        try await eventuallyOnMain("chat relay accepted by owner and original worker settled") {
            r.project.tasks.first?.phase == .settled
                && r.project.messages.first { $0.id == human }?.answerReceipts?.first?.nativeAnswer.phase == .delivered
        }
        try await eventuallyAsync("both identical coordinator tool calls finish successfully") {
            guard case .snapshot(let snapshot) = try await r.owner.server.projectConversation(r.projectID, request: .snapshot()) else { return false }
            let calls = (snapshot.messages + snapshot.provisional).filter { $0.role == "toolResult" && $0.toolName == "project_answer" }
            return calls.count == 2 && calls.allSatisfy { $0.isError != true && $0.status != "running" }
        }
        guard case .snapshot(let snapshot) = try await worker.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else {
            Issue.record("Missing answered worker"); return
        }
        #expect(snapshot.dialogs.isEmpty)
        let questions = (snapshot.messages + snapshot.provisional).compactMap(\.question)
        #expect(questions.count == 1 && questions.first?.answer == "Staging")
        let stored = try #require(r.project.messages.first { $0.id == human })
        #expect(stored.humanSubmitted == true && stored.text == reply && stored.answerReceipts?.count == 1)
        #expect(stored.answerReceipts?.first?.nativeAnswer.operationID == operation)
        #expect(stored.answerReceipts?.first?.questionEventID == event.id)
    }

    private struct ChildController: @unchecked Sendable {
        let client: ExtensionClient
        func read() async throws -> ExtensionReply {
            try await Task.detached { try client.readReply(timeout: .seconds(20)) }.value
        }
    }

    @Test func ownerPauseRetriesAReconnectedExecutorWhoseHelperStopWasNotAcknowledged() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("ask")
        try await eventuallyOnMain("remote question receipt") { r.project.tasks.first?.phase == .waiting }
        let task = try #require(r.project.tasks.first), receipt = try #require(task.executionReceipt)
        guard case .snapshot(let snapshot) = try await r.executor.server.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else {
            Issue.record("Missing executor snapshot"); return
        }
        let placement = try #require(r.owner.server.onProjectPlacement)
        let failedStops = Locked(0)
        r.owner.server.onProjectPlacement = { host, request, done in
            placement(host, request) { result in
                if case .pause = request, case .failure = result { failedStops.withValue { $0 += 1 } }
                done(result)
            }
        }
        let controller = ChildController(client: try ExtensionClient(path: r.executor.scratch.socketPath))
        try controller.client.send(.helloChildren(agentID: task.workerAgentID, projectScopes: true))
        try controller.client.send(.childScope(id: 910, agentID: task.workerAgentID, sessionID: snapshot.piSessionID,
            userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(910, "project_scope", _) = try await controller.read() else { Issue.record("Project admitted helpers"); return }
        // Legacy cleanup regression only; new Project launches cannot admit this controller.
        let executor = r.executor.server
        let scope = try await executor.enqueue { @Sendable in
            let scope = try #require(executor.currentProjectChildScope[task.workerAgentID])
            #expect(!executor.projectChildAdmitted.contains(scope))
            executor.projectChildAdmitted.insert(scope)
            return scope
        }
        try await r.perform(.pause)
        guard case .projectChildren(_, scope, .stop) = try await controller.read() else { Issue.record("Owner Pause did not reach helper controller"); return }
        controller.client.closeConnection()
        try await eventuallyOnMain("owner retains failed remote helper Stop") {
            r.project.interruptPending && r.project.tasks.first?.executionReceipt?.ownerPaused == true
                && r.project.tasks.first?.executionReceipt?.helpersStopped == false
                // A newer receipt may replace the transient task.error; the actual failed
                // transport reply plus retained reservation is the cancellation contract.
                && failedStops.current > 0
        }
        await #expect(throws: LogicalProjectsError.self) {
            try await r.owner.server.projectRuntime(r.projectID, expectedRevision: r.project.revision, request: .resume)
        }
        let reconnected = ChildController(client: try ExtensionClient(path: r.executor.scratch.socketPath))
        try reconnected.client.send(.helloChildren(agentID: task.workerAgentID, projectScopes: true))
        // Registration barrier; reconnect cannot reopen helper admission or claim old cleanup.
        try reconnected.client.send(.childScope(id: 911, agentID: task.workerAgentID, sessionID: snapshot.piSessionID,
            userTimestamp: (snapshot.messages + snapshot.provisional).last { $0.role == "user" }?.timestamp))
        guard case .error(911, "project_scope", _) = try await reconnected.read() else { Issue.record("Failed Stop reopened helper authority"); return }
        try await r.perform(.pause)
        guard case .projectChildren(let id, scope, .stop) = try await reconnected.read() else { Issue.record("Owner skipped the unacknowledged helper Stop retry"); return }
        try reconnected.client.send(.childCommandResult(id: id, error: nil))
        try await eventuallyOnMain("owner acknowledges the retried remote helper Stop") {
            !r.project.interruptPending && r.project.tasks.first?.executionReceipt?.helpersStopped == true
        }
        #expect(r.project.tasks.first?.phase == .waiting)
        guard case .snapshot(let retained) = try await r.executor.server.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else {
            Issue.record("Missing retained question"); return
        }
        #expect(retained.dialogs.first?.id == receipt.questionID)
        try await r.perform(.resume)
        #expect(!r.project.paused)
    }

    @Test func pauseRetainsExecutorDialogAndEitherNativeOrProjectAnswerUsesItsOriginalFence() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("ask")
        try await eventuallyOnMain("remote native question") { r.project.tasks.first?.phase == .waiting }
        try await r.perform(.pause)
        try await eventuallyOnMain("paused dialog acknowledged") { !r.project.interruptPending && r.project.tasks.first?.executionReceipt?.ownerPaused == true }
        let task = try #require(r.project.tasks.first), receipt = try #require(task.executionReceipt)
        let answer = NativeThreadRequest.answer(expectedSessionID: try #require(receipt.sessionID), generation: try #require(receipt.generation),
                                                operationID: UUID(), dialogID: try #require(receipt.questionID), answer: .confirm(value: true))
        guard case .accepted = try await r.executor.server.nativeThread(agentID: task.workerAgentID, request: answer) else {
            Issue.record("Native answer not retained"); return
        }
        #expect(r.executor.server.state.projectExecutions.first?.pendingAnswer?.phase == .queued)
        #expect(r.project.tasks.first?.phase == .waiting)
        try await r.perform(.resume)
        try await eventuallyOnMain("retained answer settles on explicit resume") { r.project.tasks.first?.phase == .settled }
        #expect(r.executor.server.state.projectExecutions.first?.pendingAnswer?.phase == .delivered)
        try await r.perform(.followUp(taskID: task.id, operationID: UUID(), text: "ask"))
        try await eventuallyOnMain("followup question") { r.project.tasks.first?.phase == .waiting }
        let next = try #require(r.project.tasks.first?.executionReceipt)
        let nextAnswer = NativeThreadRequest.answer(expectedSessionID: try #require(next.sessionID), generation: try #require(next.generation),
            operationID: UUID(), dialogID: try #require(next.questionID), answer: .confirm(value: true))
        try await eventuallyAsync("Project answer retains original native fence") {
            (try? await r.owner.server.answerProjectQuestion(r.projectID, expectedRevision: r.project.revision, taskID: task.id, request: nextAnswer)) != nil
        }
        try await eventuallyOnMain("Project answer settles") { r.project.tasks.first?.phase == .settled }
    }

    @Test func deletionCancelsOnlyManagedActivationAndLateCancelLeavesManualWorkAlone() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("slow")
        try await eventuallyOnMain("managed worker consumed") { r.project.tasks.first?.executionReceipt?.phase == .sent }
        let task = try #require(r.project.tasks.first), assignment = try #require(task.executionAssignment)
        let context = try #require(r.executor.server.state.projectContext(for: task.workerAgentID))
        #expect(context.ownerID == r.project.ownerID && context.tasks.first?.phase.occupiesSlot == true)
        let extensionClient = try ExtensionClient(path: r.executor.scratch.socketPath)
        try extensionClient.send(.spawnAgent(id: 7, agentID: task.workerAgentID, cwd: r.executor.dir.path, prompt: "unbounded peer"))
        guard case .error(7, "project_scope", _) = try extensionClient.readReply() else { Issue.record("Managed executor allowed peer admission"); return }
        await #expect(throws: (any Error).self) {
            _ = try await r.owner.server.logicalProjects(.delete(projectID: r.projectID, expectedRevision: r.project.revision))
        }
        try await eventuallyOnMain("deletion cancellation acknowledged") {
            r.executor.server.state.projectExecutions.first?.phase == .cancelled && r.project.tasks.first?.phase.occupiesSlot == false && !r.project.interruptPending
        }
        _ = try await r.owner.server.logicalProjects(.delete(projectID: r.projectID, expectedRevision: r.project.revision))
        #expect(r.executor.server.state.agents.count == 1)
        let retained = try #require(r.executor.server.state.projectContext(for: task.workerAgentID))
        #expect(retained.id == assignment.key.projectID && retained.tasks.first?.workerAgentID == task.workerAgentID,
                "Retained membership still supplies the Project launch marker that prevents helper registration")
        #expect(retained.paused && retained.tasks.first?.phase == .settled)
        #expect(retained.goal.isEmpty && retained.memory.isEmpty && retained.settings.instructions.isEmpty)
        #expect(retained.tasks.first?.prompt.isEmpty == true, "Membership must not replay deleted owner instructions")
        #expect(r.executor.server.state.projectExecutions.first?.phase == .cancelled)
        let executor = r.executor.server
        try await executor.enqueue { @Sendable in
            if let scope = executor.currentProjectChildScope[task.workerAgentID] {
                #expect(executor.projectChildClosed.contains(scope), "A retained cancellation identity is closed, never live authority")
            }
            #expect(executor.projectChildAdmitted.isEmpty, "Retained launch identity grants no activation authority")
        }
        try extensionClient.send(.childScope(id: 8, agentID: task.workerAgentID, sessionID: "stale", userTimestamp: nil))
        guard case .error(8, "project_scope", _) = try extensionClient.readReply() else { Issue.record("Deleted owner receipt admitted helpers"); return }
        let snapshot = try await r.executor.readyThread(task.workerAgentID)
        #expect(!snapshot.running, "Reading retained context never resumes cancelled execution")
        _ = try await r.executor.server.nativeThread(agentID: task.workerAgentID, request: .send(expectedSessionID: snapshot.piSessionID,
            generation: snapshot.generation, operationID: UUID(), text: "slow", delivery: .followUp))
        try await eventuallyAsync("ordinary manual turn active") {
            guard case .snapshot(let current) = try? await r.executor.server.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else { return false }
            return current.running
        }
        _ = try await r.executor.server.projectExecution(.cancel(key: assignment.key))
        guard case .snapshot(let stillRunning) = try await r.executor.server.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else { Issue.record("Missing manual snapshot"); return }
        #expect(stillRunning.running)
    }

    @Test func remoteDataRequiresExplicitLinkAndHostPermissionAndPinsOwnersLiveDefaultModel() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        _ = try await r.owner.server.logicalProjects(.settings(projectID: r.projectID, expectedRevision: r.project.revision, settings: .init()))
        await #expect(throws: (any Error).self) { try await r.assign("not allowed") }
        r.owner.settings.defaultModel = "anthropic/claude-sonnet-4-5"
        _ = try await r.owner.server.logicalProjects(.settings(projectID: r.projectID, expectedRevision: r.project.revision,
            settings: .init(instructions: "Use tests; password=very-secret-password", hostPolicy: .anyConnected)))
        _ = try await r.owner.server.logicalProjects(.unlinkSpace(projectID: r.projectID, expectedRevision: r.project.revision, spaceID: r.spaceB.id, host: r.host))
        await #expect(throws: (any Error).self) { try await r.assign("still not linked") }
        _ = try await r.owner.server.logicalProjects(.linkSpace(projectID: r.projectID, expectedRevision: r.project.revision, spaceID: r.spaceB.id, host: r.host))
        _ = try await r.owner.server.logicalProjects(.edit(projectID: r.projectID, expectedRevision: r.project.revision, name: "Owner", goal: "Bearer abcdefghijklmnopqrstuvwxyz"))
        _ = try await r.owner.server.logicalProjects(.addMemory(projectID: r.projectID, expectedRevision: r.project.revision, memoryID: ProjectMemoryID(),
            text: "sk-proj-0123456789abcdefghijklmnop", source: "user"))
        try await r.assign("hello")
        try await eventuallyOnMain("redacted owner data reaches selected executor") { r.project.tasks.first?.phase == .settled }
        let assignment = try #require(r.project.tasks.first?.executionAssignment)
        #expect(assignment.model == r.owner.settings.defaultModel)
        let sent = String(decoding: try JSONEncoder().encode(assignment), as: UTF8.self)
        #expect(!sent.contains("very-secret-password") && !sent.contains("abcdefghijklmnopqrstuvwxyz") && !sent.contains("sk-proj-0123456789abcdefghijklmnop"))
        #expect(sent.contains("[redacted]") && !sent.contains(r.owner.dir.path))
        #expect(r.executor.server.state.projects.isEmpty)
        let launch = try #require(StubPi.launches().last { $0.argv.contains(assignment.reservedWorkerID.rawValue) })
        #expect(launch.env["SHEPHERD_PROJECT_CONTEXT"]?.contains(r.projectID.rawValue) == true)
        #expect(launch.env["SHEPHERD_PROJECT_CONTEXT"]?.contains("password") == false)
    }

    @Test func ownerRestartReconcilesOfflineResultsWithoutDispatchingTheFourthTask() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        for _ in 0..<3 { try await r.assign("slow") }
        try await r.assign("hello")
        try await eventuallyOnMain("three remote assignments consumed") { r.project.tasks.filter { $0.executionReceipt?.phase == .sent }.count == 3 }
        let assignments = r.project.tasks.compactMap(\.executionAssignment)
        r.owner.server.stop()
        for pause in [1, 2] { try Data().write(to: r.executor.dir.appendingPathComponent("continue-\(pause)")) }
        try await eventuallyOnMain("executor finishes while owner is stopped") { r.executor.server.state.projectExecutions.allSatisfy { $0.phase == .settled } }
        #expect(r.executor.server.state.projectExecutions.count == 3)
        try r.owner.server.start()
        #expect(r.project.paused)
        r.owner.server.reconcileProjectExecutions(host: r.host)
        try await eventuallyOnMain("read-only reconciliation after restart") { r.project.tasks.filter { $0.phase == .settled }.count == 3 }
        #expect(r.project.paused && r.project.tasks.last?.phase == .queued)
        #expect(r.project.tasks.compactMap(\.executionAssignment) == assignments)
        #expect(r.executor.server.state.projectExecutions.count == 3)
        #expect(r.executor.server.state.projectExecutions.allSatisfy { $0.ownerPaused != true })
        try await r.perform(.resume)
        try await eventuallyOnMain("only explicit Resume dispatches queued work") { r.project.tasks.last?.phase == .settled }
        #expect(r.executor.server.state.projectExecutions.count == 4)
    }

    @Test func remoteViewerUsesOwnersIdentityAndLostExecuteReplyReconcilesTheSameReservation() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        let tokenURL = r.owner.dir.appendingPathComponent("viewer-token")
        let port = try r.owner.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let viewer = RemoteHostClient(); defer { viewer.disconnect() }
        _ = try await viewer.connect(host: "127.0.0.1", port: port, token: token, clientName: "Independent viewer")
        let adapter = try #require(r.owner.server.onProjectPlacement)
        let replies = Locked(0)
        r.owner.server.onProjectPlacement = { host, request, done in
            adapter(host, request) { result in
                if case .execute = request {
                    replies.withValue { $0 += 1 }
                    done(.failure(LogicalProjectsError("outcome_unknown", "Simulated lost reply after authenticated executor admission")))
                } else { done(result) }
            }
        }
        let operation = UUID()
        guard case .project = try await viewer.projectRuntime(.action(projectID: r.projectID, expectedRevision: r.project.revision,
            request: .assign(operationID: operation, spaceID: r.spaceB.id, title: "Remote viewer's work", prompt: "hello", host: r.host))) else { Issue.record("Missing admission"); return }
        try await eventuallyOnMain("lost reply reconciled through subscribed receipt") { r.project.tasks.first?.phase == .settled }
        let assignment = try #require(r.project.tasks.first?.executionAssignment)
        #expect(assignment.key.ownerID == r.project.ownerID && assignment.key.operationID == operation)
        #expect(r.executor.server.state.projectExecutions.first?.assignment == assignment)
        #expect(replies.current == 1 && r.executor.server.state.agents.count == 1)
        #expect(r.owner.server.state.agents.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await viewer.projectRuntime(.action(projectID: r.projectID, expectedRevision: r.project.revision,
                request: .assign(operationID: operation, spaceID: r.spaceA.id, title: "Remote viewer's work", prompt: "hello")))
        }
    }

    @Test(arguments: [false, true])
    func viewerReadsAndSteersWorkersThroughTheirOwnerWithoutExecutorCredentials(remote: Bool) async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("hello", remote: remote)
        try await eventuallyOnMain("assigned task settled") { r.project.tasks.first?.phase == .settled }
        let task = try #require(r.project.tasks.first)
        let viewer = try await r.connectViewer(); defer { viewer.disconnect() }
        let read = ProjectRuntimeTransport.worker(projectID: r.projectID, taskID: task.id, request: .snapshot())
        guard case .native(.snapshot(let snapshot)) = try await viewer.projectRuntime(read) else {
            Issue.record("Owner did not return the worker's native snapshot"); return
        }
        let expected = try await (remote ? r.executor : r.owner).readyThread(task.workerAgentID)
        #expect(snapshot.piSessionID == expected.piSessionID && snapshot.generation == expected.generation)
        let text = "Inspecting from the separate viewer", operation = UUID()
        let send = ProjectRuntimeTransport.worker(projectID: r.projectID, taskID: task.id,
            request: .send(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
                           operationID: operation, text: text, delivery: .followUp))
        guard case .native(.accepted) = try await viewer.projectRuntime(send) else { Issue.record("Worker send refused"); return }
        _ = try await viewer.projectRuntime(send)
        try await eventuallyAsync("worker consumed viewer message exactly once") {
            guard case .native(.snapshot(let latest)) = try? await viewer.projectRuntime(read) else { return false }
            return !latest.running && latest.messages.filter { $0.role == "user" && $0.blocks == [.init(kind: .text, text: text)] }.count == 1
        }
        #expect(r.owner.server.state.agents.count == (remote ? 0 : 1))
        #expect(r.executor.server.state.agents.count == (remote ? 1 : 0))
        guard case .native(.failure) = try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: task.id,
            request: .send(expectedSessionID: snapshot.piSessionID, generation: "stale-generation", operationID: UUID(),
                           text: "must not send", delivery: .followUp))) else { Issue.record("Native generation fence was bypassed"); return }
        await #expect(throws: (any Error).self) { _ = try await viewer.projectRuntime(.worker(projectID: ProjectID(), taskID: task.id, request: .snapshot())) }
        await #expect(throws: (any Error).self) { _ = try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: ProjectTaskID(), request: .snapshot())) }
        if remote {
            let config = try #require(r.owner.remoteHosts.hosts.first)
            r.owner.remoteHosts.updateHost(id: config.id, name: config.name, host: "localhost", port: config.port, token: config.token)
            try await eventuallyOnMain("replacement executor connected") { r.owner.remoteHosts.connections.first?.phase == .connected }
            await #expect(throws: (any Error).self) { _ = try await viewer.projectRuntime(read) }
        }
    }

    @Test func viewerAnswerInTheWorkerPaneWaitsForOwnerResume() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("ask")
        try await eventuallyOnMain("worker asks a question") { r.project.tasks.first?.phase == .waiting }
        try await r.perform(.pause)
        try await eventuallyOnMain("pause acknowledged") { !r.project.interruptPending && r.project.tasks.first?.executionReceipt?.ownerPaused == true }
        let task = try #require(r.project.tasks.first), receipt = try #require(task.executionReceipt)
        let viewer = try await r.connectViewer(); defer { viewer.disconnect() }
        let answer = NativeThreadRequest.answer(expectedSessionID: try #require(receipt.sessionID), generation: try #require(receipt.generation),
            operationID: UUID(), dialogID: try #require(receipt.questionID), answer: .confirm(value: true))
        guard case .native(.accepted) = try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: task.id, request: answer)) else {
            Issue.record("Owner did not retain the worker-pane answer"); return
        }
        #expect(r.project.tasks.first?.pendingAnswer?.phase == .queued)
        #expect(r.executor.server.state.projectExecutions.first?.phase == .waiting)
        try await r.perform(.resume)
        do {
            try await eventuallyOnMain("queued answer consumed after resume") { r.project.tasks.first?.phase == .settled }
        } catch {
            let owner = r.project.tasks.first, executor = r.executor.server.state.projectExecutions.first
            Issue.record("Owner: phase=\(String(describing: owner?.phase)), answer=\(String(describing: owner?.pendingAnswer?.phase)), receipt=\(String(describing: owner?.executionReceipt?.phase)), error=\(String(describing: owner?.error)); executor: phase=\(String(describing: executor?.phase)), answer=\(String(describing: executor?.pendingAnswer?.phase)), paused=\(String(describing: executor?.ownerPaused)), epoch=\(String(describing: executor?.childScopeEpoch))")
            throw error
        }
    }

    @Test(arguments: [false, true])
    func aManualQuestionAfterManagedWorkSettlesCanBeAnsweredThroughItsOwner(remote: Bool) async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("hello", remote: remote)
        try await eventuallyOnMain("managed task settled") { r.project.tasks.first?.phase == .settled }
        let task = try #require(r.project.tasks.first)
        try await r.perform(.pause)
        let viewer = try await r.connectViewer(); defer { viewer.disconnect() }
        func send(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .native(let result) = try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: task.id, request: request)) else {
                throw AgentStartFailure(message: "Expected native worker reply")
            }
            return result
        }
        guard case .snapshot(let ready) = try await send(.snapshot()) else { Issue.record("No native worker snapshot"); return }
        let operation = UUID()
        #expect(try await send(.send(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: operation,
            text: "ask", delivery: .followUp)) == .accepted(operationID: operation))
        var question = ready
        try await eventuallyAsync("manual question through owner") {
            if case .snapshot(let snapshot) = try await send(.snapshot()) { question = snapshot }
            return !question.dialogs.isEmpty
        }
        let dialog = try #require(question.dialogs.first), answer = UUID()
        #expect(try await send(.answer(expectedSessionID: question.piSessionID, generation: question.generation,
            operationID: answer, dialogID: dialog.id, answer: .confirm(value: true))) == .accepted(operationID: answer))
        try await eventuallyAsync("ordinary question answered without Project Resume") {
            if case .snapshot(let snapshot) = try await send(.snapshot()) { return snapshot.dialogs.isEmpty && !snapshot.running }
            return false
        }
        #expect(r.project.paused && r.project.tasks.first?.pendingAnswer == nil)
        #expect(r.project.tasks.first?.phase == .settled, "Manual work must not reactivate the finished managed assignment")
    }

    @Test(arguments: [false, true])
    func aManualTakeoverQuestionIsAnsweredWithoutAttributingItToTheUnknownProjectActivation(remote: Bool) async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("tools:1", remote: remote)
        try await eventuallyOnMain("original managed turn is active") { r.project.tasks.first?.phase == .running }
        let task = try #require(r.project.tasks.first)
        let viewer = try await r.connectViewer(); defer { viewer.disconnect() }
        var snapshot: NativeThreadSnapshot?
        try await eventuallyAsync("worker tool is waiting") {
            guard case .native(.snapshot(let current)) = try await viewer.projectRuntime(.worker(
                projectID: r.projectID, taskID: task.id, request: .snapshot())) else { return false }
            snapshot = current
            return current.running && current.provisional.contains { $0.status == "toolUse" }
        }
        let initial = try #require(snapshot)
        guard case .native(.accepted) = try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: task.id,
            request: .send(expectedSessionID: initial.piSessionID, generation: initial.generation,
                operationID: UUID(), text: "question", delivery: .steer))) else {
            Issue.record("Manual steering was refused"); return
        }
        try Data().write(to: URL(fileURLWithPath: remote ? r.spaceB.path : r.spaceA.path).appendingPathComponent("tool-1"))
        try await eventuallyAsync("manual question supersedes managed authority") {
            guard case .native(.snapshot(let current)) = try await viewer.projectRuntime(.worker(
                projectID: r.projectID, taskID: task.id, request: .snapshot())) else { return false }
            snapshot = current
            return r.project.tasks.first?.phase == .unknown && current.dialogs.first != nil
        }
        #expect(r.project.tasks.first?.question == nil, "the manual dialog is not a Project question")
        let question = try #require(snapshot), dialog = try #require(question.dialogs.first)
        let operation = UUID()
        let answer = NativeThreadRequest.answer(expectedSessionID: question.piSessionID, generation: question.generation,
            operationID: operation, dialogID: dialog.id, answer: .confirm(value: true))
        #expect(try await viewer.projectRuntime(.worker(projectID: r.projectID, taskID: task.id, request: answer))
            == .native(.accepted(operationID: operation)))
        try await eventuallyAsync("ordinary manual work finishes") {
            guard case .native(.snapshot(let current)) = try await viewer.projectRuntime(.worker(
                projectID: r.projectID, taskID: task.id, request: .snapshot())) else { return false }
            return !current.running && current.dialogs.isEmpty
        }
        #expect(r.project.tasks.first?.phase == .unknown)
        #expect(r.project.tasks.first?.pendingAnswer == nil)
        #expect(r.project.tasks.first?.question == nil)
        #expect(r.executor.server.state.projectExecutions.first?.pendingAnswer == nil)
    }

    @Test func changedBindingCannotAdoptInflightWorkAndDisconnectDoesNotFreeItsSlot() async throws {
        let r = try Rig(); defer { r.stop() }; try await r.start()
        try await r.assign("slow")
        try await eventuallyOnMain("remote turn consumed") { r.project.tasks.first?.executionReceipt?.phase == .sent }
        let task = try #require(r.project.tasks.first)
        let config = try #require(r.owner.remoteHosts.hosts.first)
        r.owner.remoteHosts.updateHost(id: config.id, name: config.name, host: "localhost", port: config.port, token: config.token)
        try await eventuallyOnMain("replacement binding connected") { r.owner.remoteHosts.connections.first?.phase == .connected }
        #expect(r.owner.remoteHosts.hosts.first?.bindingID != config.bindingID)
        #expect(r.project.tasks.first?.phase.occupiesSlot == true)
        #expect(r.project.tasks.first?.executionAssignment == task.executionAssignment)
        await #expect(throws: (any Error).self) {
            try await r.owner.vm.projectCoordinator.place(host: r.host, request: .execute(try #require(task.executionAssignment)))
        }
        await #expect(throws: (any Error).self) { try await r.assign("must not fall back") }
        #expect(r.owner.server.state.agents.isEmpty)
        #expect(r.executor.server.state.agents.count == 1)
    }
}
