import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Projects experiment host admission", .integrationTimeLimit)
struct ProjectExperimentTests {
    private func disabled<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Disabled Projects admitted work") }
        catch let error as LogicalProjectsError {
            #expect(error.code == "unsupported")
            #expect(error.description.contains("Enable Projects in Settings > Experiments."))
        } catch { Issue.record("Unexpected refusal: \(error)") }
    }

    @Test func freshHostRefusesProjectsButOrdinarySpacesAndThreadsStillWork() async throws {
        let rig = try ProjectRuntimeTests.Rig(projectsEnabled: false); defer { rig.stop() }
        let server = rig.host.server, id = ProjectID()
        await disabled { try await server.logicalProjects(.create(projectID: id, name: "Hidden", goal: "")) }
        await disabled { try await server.projectRuntime(id, expectedRevision: 1, request: .resume) }
        await disabled { try await server.projectTool(agentID: .init(), projectID: id, expectedRevision: 1, request: .read) }
        await disabled { try await server.runProjectAutomation(projectID: id, expectedRevision: 1, automationID: .init()) }
        await disabled { try await server.projectPublish(.init(), request: .publish(publicationID: UUID(), sourcePath: "report.txt", artifactName: "report.txt")) }
        let space = Space(name: "Ordinary Space", path: rig.host.dir.path)
        try await server.addSpace(space)
        let assignment = ProjectExecutionAssignment(key: .init(ownerID: UUID(), projectID: id, operationID: UUID()), taskID: .init(), reservedWorkerID: .init(), executorSpaceID: space.id, title: "Task", prompt: "tools:0")
        await disabled { try await server.projectExecution(.execute(assignment)) }
        await disabled { try await server.projectExecution(.resume(key: assignment.key)) }
        let registered = try await server.registerProject(path: rig.host.dir.path, name: "Ordinary Space")
        #expect(registered.space.id == space.id)
        let ordinary = try await PiAgent.launch(on: rig.host)
        _ = try await ordinary.send("tools:0 ordinary", from: ordinary.ready())
        _ = try await ordinary.snapshot("ordinary reply while experiment off") { !$0.running && !$0.messages.isEmpty }
        #expect(server.state.projects.isEmpty && server.state.projectExecutions.isEmpty)
        #expect(server.state.spaces.contains(space))
        server.setProjectsEnabled(true)
        let project = try await rig.create()
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "tools:0 enabled"))
        try await eventually("enabled coordinator prompt") { rig.agents.current.values.contains { $0.stdin("prompt").count == 1 } }
    }

    @Test func connectedViewersCannotBypassTheDefaultOffHost() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        remote.server.onProjectRuntimeLaunch = { _, _ in Issue.record("Disabled owner launched") }
        remote.server.onProjectRuntimeRequest = { _, _ in Issue.record("Disabled owner served runtime") }
        remote.server.onProjectExecutionLaunch = { _, _ in Issue.record("Disabled executor launched") }
        let client = try await remote.typed(); defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.projectsExperimentCapability))
        do {
            _ = try await client.logicalProjects(.create(projectID: .init(), name: "Hidden", goal: ""))
            Issue.record("Disabled remote owner created Project")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "unsupported" && message.contains("Settings > Experiments"))
        }
        do {
            _ = try await client.projectRuntime(.hosts)
            Issue.record("Disabled remote runtime was served")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "unsupported" && message.contains("Settings > Experiments"))
        }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: .init(), operationID: UUID())
        do {
            _ = try await client.projectExecution(.execute(.init(key: key, taskID: .init(), reservedWorkerID: .init(), executorSpaceID: .init(), title: "Task", prompt: "tools:0")))
            Issue.record("Disabled remote executor admitted assignment")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "unsupported" && message.contains("Settings > Experiments"))
        }
        #expect(try await client.projectExecution(.cancel(key: key)).receipt.phase == .cancelled)
        #expect(try await client.projectExecution(.snapshot(key: key, watch: false)).receipt.phase == .cancelled)
    }

    @Test func disablingLiveOwnerStopsWorkRetainsDataAndEnablingDoesNotResume() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "hang"))
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("coordinator active and worker waiting") {
            rig.host.server.state.projects.first?.tasks.first?.phase == .waiting && rig.agents.current.count == 2
        }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first)
        let worker = try #require(rig.agents.current[task.workerAgentID])
        let question = try await worker.snapshot("native question") { !$0.dialogs.isEmpty }
        rig.host.server.setProjectsEnabled(false)
        try await eventually("owner paused and acknowledged") {
            rig.host.server.state.projects.first?.paused == true && rig.host.server.state.projects.first?.interruptPending == false
        }
        let answer = NativeThreadRequest.answer(expectedSessionID: question.piSessionID, generation: question.generation, operationID: UUID(), dialogID: try #require(question.dialogs.first?.id), answer: .confirm(value: true))
        await disabled { try await rig.host.server.answerProjectQuestion(project.id, expectedRevision: rig.host.server.state.projects[0].revision, taskID: task.id, request: answer) }
        guard case .failure("unsupported", _) = try await rig.host.server.nativeThread(agentID: task.workerAgentID, request: answer) else { Issue.record("Native answer bypassed experiment"); return }
        let saved = try #require(rig.host.server.state.projects.first)
        #expect(saved.linkedSpaces == project.linkedSpaces && !saved.messages.isEmpty)
        #expect(rig.host.server.state.agents.count == 2)
        let client = try ExtensionClient(path: rig.host.socketPath)
        try client.send(.projectRuntime(id: 1, agentID: task.workerAgentID, projectID: project.id, expectedRevision: saved.revision, request: .read))
        guard case .error(1, "unsupported", _) = try client.readReply() else { Issue.record("Project tool bypassed experiment"); return }
        try client.send(.childScope(id: 2, agentID: task.workerAgentID, sessionID: question.piSessionID, userTimestamp: nil))
        guard case .error(2, "project_scope", _) = try client.readReply() else { Issue.record("Disabling Projects reopened worker subagents"); return }
        rig.host.server.setProjectsEnabled(true)
        _ = try await rig.host.server.logicalProjects(.list)
        #expect(rig.host.server.state.projects.first?.paused == true)
        #expect(worker.stdin("prompt").count == 1)
        _ = try await rig.perform(project.id, .resume)
        #expect(rig.host.server.state.projects.first?.paused == false)
    }

    @Test(arguments: [false, true])
    func disablingOwnerCancelsThePreparedWorkerInputUntilExplicitResume(reenableBeforeRelease: Bool) async throws {
        let rig = try ProjectRuntimeTests.Rig(holdWorkerPreparation: true); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Prepared worker", prompt: "tools:0"))
        try await eventually("worker preparation held") { rig.heldWorkerPreparation.current != nil }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first)
        let worker = try #require(rig.agents.current[task.workerAgentID])
        #expect(worker.stdin("prompt").isEmpty)
        #expect(try await rig.host.server.enqueue { rig.host.server.currentProjectChildScope[task.workerAgentID] == nil })

        rig.host.server.setProjectsEnabled(false)
        if reenableBeforeRelease { rig.host.server.setProjectsEnabled(true) }
        try await eventually("prepared worker returned to reservation after disabling") {
            guard let saved = rig.host.server.state.projects.first else { return false }
            return saved.paused && !saved.interruptPending && saved.tasks.first?.phase == .reserved
        }
        let held = try #require(rig.heldWorkerPreparation.current)
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: task.workerAgentID))
            thread.beforePrompt = nil
            held()
            #expect(thread.preparingPrompts.isEmpty && thread.dispatches.isEmpty && thread.items.isEmpty)
        }
        #expect(worker.stdin("prompt").isEmpty)
        let paused = try #require(rig.host.server.state.projects.first)
        #expect(paused.tasks.first?.nativeDeliveryID != task.nativeDeliveryID)
        if !reenableBeforeRelease { rig.host.server.setProjectsEnabled(true) }
        _ = try await rig.host.server.logicalProjects(.list)
        #expect(rig.host.server.state.projects.first?.paused == true)
        _ = try await rig.perform(project.id, .resume)
        try await eventually("only explicit Resume sends the prepared worker") {
            worker.stdin("prompt").count == 1 && rig.host.server.state.projects.first?.tasks.first?.phase == .settled
        }
        #expect(rig.agents.current.count == 1)
    }

    @Test func disablingExecutorRevokesHeldLaunchAndStillServesCancellationProof() async throws {
        let rig = try ProjectExecutionTests.Rig(hold: true); defer { rig.stop() }
        let assignment = try await rig.assignment("hang")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("held executor launch") { rig.heldLaunch.current != nil }
        rig.host.server.setProjectsEnabled(false)
        try await eventually("disabled executor cancelled reservation") { rig.receipt(assignment)?.phase == .cancelled }
        rig.heldLaunch.current?()
        rig.host.server.setProjectsEnabled(true)
        let proof = try await rig.host.server.projectExecution(.snapshot(key: assignment.key, watch: false))
        #expect(proof.receipt.phase == .cancelled)
        #expect(rig.host.server.state.agents.isEmpty)
        #expect(rig.agents.current.isEmpty)
        #expect(try await rig.host.server.projectExecution(.execute(assignment)).receipt.phase == .cancelled)
    }

    @Test func offOnWhileExecutorAdmissionStagesLeavesACancellationTombstone() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment()
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("executor writer held") { entered.current }
        let executing = Task { try await rig.host.server.projectExecution(.execute(assignment)) }
        try await eventually("executor admission pending") {
            try await rig.host.server.enqueue { rig.host.server.executionPending.contains(assignment.key) }
        }
        rig.host.server.setProjectsEnabled(false)
        rig.host.server.setProjectsEnabled(true)
        _ = try await rig.host.server.logicalProjects(.list)
        gate.signal()
        await #expect(throws: LogicalProjectsError.self) { try await executing.value }
        try await eventually("revoked executor admission tombstone") { rig.receipt(assignment)?.phase == .cancelled }
        #expect(rig.launches.current == 0)
        #expect(try await rig.host.server.projectExecution(.execute(assignment)).receipt.phase == .cancelled)
    }

    @Test func disabledExecutorRetainsWaitingQuestionAndRefusesAnswerUntilExplicitResume() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("ask")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("executor waiting") { rig.receipt(assignment)?.phase == .waiting }
        rig.host.server.setProjectsEnabled(false)
        try await eventually("executor parked with proof") { rig.receipt(assignment)?.ownerPaused == true && rig.receipt(assignment)?.helpersStopped == true }
        let receipt = try #require(rig.receipt(assignment))
        let answer = NativeThreadRequest.answer(expectedSessionID: try #require(receipt.sessionID), generation: try #require(receipt.generation), operationID: UUID(), dialogID: try #require(receipt.questionID), answer: .confirm(value: true))
        await disabled { try await rig.host.server.projectExecution(.answer(key: assignment.key, request: answer)) }
        #expect(try await rig.host.server.projectExecution(.snapshot(key: assignment.key, watch: false)).receipt.phase == .waiting)
        rig.host.server.setProjectsEnabled(true)
        #expect(try await rig.host.server.projectExecution(.snapshot(key: assignment.key, watch: false)).receipt.ownerPaused == true)
        _ = try await rig.host.server.projectExecution(.resume(key: assignment.key))
        _ = try await rig.host.server.projectExecution(.answer(key: assignment.key, request: answer))
        try await eventually("explicitly resumed executor settles") { rig.receipt(assignment)?.phase == .settled }
    }

    @Test func disabledOwnerReconcilesDisconnectedExecutorWithoutReleasingItsReservation() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let owner = rig.owner.server, destination = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let assignment = try await rig.assignment("ask")
        let space = try #require(rig.host.server.state.spaces.first { $0.id == assignment.executorSpaceID })
        owner.setProjectEligibleHosts([.local, destination])
        owner.setProjectExecutionSpaces([destination: [space]])
        owner.onProjectRuntimeLaunch = { _, _ in Issue.record("Remote placement must not launch on owner") }
        owner.onProjectDefaultModel = { nil }
        let offline = Locked(false)
        owner.onProjectPlacement = { _, request, completion in
            if offline.current { completion(.failure(WireError("Executor disconnected"))); return }
            Task {
                do { completion(.success(try await rig.host.server.projectExecution(request))) }
                catch { completion(.failure(error)) }
            }
        }
        guard case .project(let project) = try await owner.logicalProjects(.create(projectID: assignment.key.projectID, name: "Remote owner", goal: "")) else { throw WireError("Project missing") }
        _ = try await owner.updateRuntimeProject(project.id) {
            $0.ownerID = assignment.key.ownerID
            $0.settings.allowedHosts = [destination]
            $0.linkedSpaces = [.init(spaceID: space.id, linkedAt: 0, host: destination)]
            var task = ProjectTask(id: assignment.taskID, operationID: assignment.key.operationID, workerAgentID: assignment.reservedWorkerID,
                                   spaceID: space.id, title: assignment.title, prompt: assignment.prompt, phase: .reserved, host: destination)
            task.executionAssignment = assignment
            $0.tasks = [task]
        }
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("remote question") { rig.receipt(assignment)?.phase == .waiting }
        offline.withValue { $0 = true }
        owner.setProjectsEnabled(false)
        try await eventually("owner retains failed interruption") {
            owner.state.projects.first?.paused == true && owner.state.projects.first?.interruptPending == true
                && owner.state.projects.first?.tasks.first?.error?.contains("disconnected") == true
        }
        #expect(owner.state.projects.first?.tasks.first?.phase.occupiesSlot == true)
        #expect(rig.receipt(assignment)?.ownerPaused != true)
        offline.withValue { $0 = false }
        owner.reconcileProjectExecutions(host: destination)
        try await eventually("disabled owner reconciles original pause proof") {
            owner.state.projects.first?.interruptPending == false && rig.receipt(assignment)?.ownerPaused == true
        }
        #expect(owner.state.projects.first?.tasks.first?.phase == .waiting)
        owner.setProjectsEnabled(true)
        _ = try await owner.logicalProjects(.list)
        #expect(owner.state.projects.first?.paused == true)
        #expect(rig.launches.current == 1)
    }

    @Test func offOnDuringRuntimeAdmissionCannotCommitOrLaunchTheOldMessage() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create()
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("runtime file writer held") { entered.current }
        let sending = Task { try await rig.perform(project.id, .message(operationID: UUID(), text: "hang")) }
        try await eventually("message admission staging") {
            try await rig.host.server.enqueue { rig.host.server.projectRuntimeWriterBusy && rig.host.server.logicalProjectSaveCount == 1 }
        }
        rig.host.server.setProjectsEnabled(false)
        rig.host.server.setProjectsEnabled(true)
        _ = try await rig.host.server.logicalProjects(.list)
        gate.signal()
        await #expect(throws: LogicalProjectsError.self) { try await sending.value }
        try await eventually("revoked owner paused") { rig.host.server.state.projects.first?.paused == true }
        #expect(rig.host.server.state.projects.first?.messages.isEmpty == true)
        #expect(rig.host.server.state.agents.isEmpty)
    }

    @Test func offOnDuringDirectoryCreationRevokesTheOriginalAdmission() async throws {
        let host = try ScratchServer(); defer { host.stop() }
        host.server.setProjectsEnabled(true)
        let held = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { held.signal() }
        host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; held.wait() }
        try await eventually("file queue held") { entered.current }
        let id = ProjectID()
        let creating = Task { try await host.server.logicalProjects(.create(projectID: id, name: "Racing", goal: "")) }
        try await eventually("creation admitted") { try await host.server.enqueue { host.server.logicalProjectCreates.contains(id) } }
        host.server.setProjectsEnabled(false)
        host.server.setProjectsEnabled(true)
        _ = try await host.server.logicalProjects(.list)
        held.signal()
        await #expect(throws: LogicalProjectsError.self) { try await creating.value }
        #expect(host.server.state.projects.isEmpty)
    }
}
