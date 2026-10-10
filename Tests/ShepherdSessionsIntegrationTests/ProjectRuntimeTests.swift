import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Owner-local Project runtime", .integrationTimeLimit)
struct ProjectRuntimeTests {
    final class Rig: @unchecked Sendable {
        let host: ScratchServer
        let agents = Locked<[AgentID: PiAgent]>([:])
        let heldWorkerPreparation = Locked<(() -> Void)?>(nil)
        init(dir: URL? = nil, projectsEnabled: Bool = true, holdWorkerPreparation: Bool = false) throws {
            host = try ScratchServer(dir: dir)
            host.server.setProjectsEnabled(projectsEnabled)
            let host = host, agents = agents, preparation = heldWorkerPreparation
            host.server.onProjectRuntimeLaunch = { launch, done in
                Task {
                    do {
                        let existing = host.server.state.agents.first { $0.id == launch.agentID }
                        let oldTab = host.server.state.tabs.first { $0.id == existing?.tabID }
                        let pane = oldTab?.layout.leaves.first ?? LeafPane(cwd: launch.cwd, agentID: launch.agentID)
                        let tab = oldTab ?? Tab(spaceID: launch.spaceID, order: 0, layout: .leaf(pane))
                        let agent = existing ?? Agent(id: launch.agentID, name: launch.name, spaceID: launch.spaceID, tabID: tab.id,
                                          paneID: pane.id, coordinatorFor: launch.coordinator ? launch.projectID : nil)
                        if existing == nil { try await host.server.addAgent(agent, withTab: tab) }
                        let log = host.dir.appendingPathComponent("\(agent.id).log")
                        let session = try await host.server.createSession(params: .init(cwd: launch.cwd, command: StubPi.command,
                            env: ["STUB_PI_LOG": log.path, "SHEPHERD_AGENT_ID": agent.id.rawValue,
                                  "SHEPHERD_SOCKET": host.socketPath,
                                  "SHEPHERD_PROJECT_CONTEXT": "{\"projectID\":\"\(launch.projectID)\"}"], runtime: .rpc))
                        try await host.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: session.id)
                        agents.withValue { $0[agent.id] = PiAgent(host: host, agent: agent, sessionID: session.id, log: log) }
                        if holdWorkerPreparation && !launch.coordinator {
                            try await host.server.enqueue {
                                let thread = try #require(host.server.rpcThread(forAgent: agent.id))
                                thread.beforePrompt = { done in preparation.withValue { $0 = done } }
                            }
                        }
                        done(.success(agent.id))
                    } catch { done(.failure(error)) }
                }
            }
        }
        func stop() { host.server.onProjectRuntimeLaunch = nil; host.stop() }
        func create() async throws -> Project {
            let space = Space(name: "Source", path: host.dir.path)
            try await host.server.addSpace(space)
            guard case .project(let project) = try await host.server.logicalProjects(.create(projectID: .init(), name: "Project", goal: "Assigned work", linkedSpaceIDs: [space.id])) else { throw WireError("Project missing") }
            return project
        }
        func perform(_ id: ProjectID, _ request: ProjectRuntimeRequest) async throws -> Project {
            // Native events can advance the revision while a staged write runs; retain the
            // same operation/payload and retry only a definite stale/busy refusal.
            for _ in 0..<32 {
                let project = try #require(host.server.state.projects.first { $0.id == id })
                do { return try await host.server.projectRuntime(id, expectedRevision: project.revision, request: request) }
                catch let error as LogicalProjectsError where ["stale_project", "workspace_changed", "project_busy"].contains(error.code) { continue }
            }
            throw WireError("Project revision did not settle")
        }
    }

    @Test func firstMessageCreatesOneHiddenCoordinatorAndOperationRetryNeverResends() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create()
        #expect(rig.host.server.state.agents.isEmpty)
        let operation = UUID()
        let sent = try await rig.perform(project.id, .message(operationID: operation, text: "hello"))
        let id = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator's real prompt") { rig.agents.current[id]?.stdin("prompt").count == 1 }
        let coordinator = try #require(rig.host.server.state.agents.first { $0.id == id })
        #expect(coordinator.coordinatorFor == project.id)
        #expect(rig.host.server.state.spaces.first { $0.id == coordinator.spaceID }?.holdsProjects == true)
        #expect(rig.host.server.state.withoutProjectCoordinators.agents.isEmpty)
        #expect(!ProjectSettingsStore.directories(in: rig.host.server.state).contains { $0.0.contains("logical-projects") })
        _ = try await rig.host.server.projectRuntime(project.id, expectedRevision: project.revision,
                                                     request: .message(operationID: operation, text: "must not resend"))
        #expect(rig.agents.current[id]?.stdin("prompt").count == 1)
        let pi = try #require(rig.agents.current[id]), snapshot = try await pi.ready()
        await #expect(throws: RemoteHostClientError.self) { try await pi.send("bypass", from: snapshot) }
        let client = try ExtensionClient(path: rig.host.socketPath)
        try client.send(.spawnAgent(id: 5, agentID: id, cwd: rig.host.dir.path, prompt: "bypass"))
        guard case .error(5, "project_scope", _) = try client.readReply() else { Issue.record("Expected project scope refusal"); return }
        try client.send(.childScope(id: 7, agentID: id, sessionID: snapshot.piSessionID, userTimestamp: nil))
        guard case .error(7, "project_scope", _) = try client.readReply() else { Issue.record("Coordinator admitted helpers"); return }
        try client.send(.helloAgent(agentID: id))
        try client.send(.createAutomation(id: 6, name: "Bypass", prompt: "loop", cwd: rig.host.dir.path, enabled: true, start: true))
        guard case .error(6, "project_scope", _) = try client.readReply() else { Issue.record("Expected automation refusal without a speaksFor field"); return }
    }

    @Test func projectMessagesWaitForTheCoordinatorsActualTurnToSettle() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create()
        let sent = try await rig.perform(project.id, .message(operationID: UUID(), text: "slow"))
        let id = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator launched") { rig.agents.current[id] != nil }
        let pi = try #require(rig.agents.current[id])
        _ = try await pi.snapshot("coordinator active") { $0.running }
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "second assigned message"))
        #expect(pi.stdin("prompt").count == 1)
        let directory = rig.host.dir.appendingPathComponent("logical-projects/\(project.id)")
        for pause in [1, 2] { FileManager.default.createFile(atPath: directory.appendingPathComponent("continue-\(pause)").path, contents: nil) }
        try await eventually("second project message delivered") { pi.stdin("prompt").count == 2 }
        #expect(rig.agents.current.count == 1)
    }

    @Test func threeWorkersRunAndTheFourthWaitsForActualSettlement() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        for i in 0..<4 { _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Task \(i)", prompt: "slow")) }
        try await eventually("three native workers") { rig.agents.current.count == 3 && rig.agents.current.values.allSatisfy { $0.stdin("prompt").count == 1 } }
        let state = try #require(rig.host.server.state.projects.first)
        #expect(state.tasks.filter { $0.phase.occupiesSlot }.count == 3)
        #expect(state.tasks.filter { $0.phase == .queued }.count == 1)
        await #expect(throws: LogicalProjectsError.self) { try await rig.perform(project.id, .resolve(taskID: state.tasks[0].id)) }
        for pi in rig.agents.current.values { pi.release(1); pi.release(2) }
        try await eventually("fourth admitted after native settlement") { rig.agents.current.count == 4 }
        try await eventually("settled tasks") { rig.host.server.state.projects.first?.tasks.allSatisfy { $0.phase == .settled } == true }
        let settled = try #require(rig.host.server.state.projects.first)
        #expect(settled.tasks.allSatisfy { $0.settledAt != nil })
        let resolved = try await rig.perform(project.id, .resolve(taskID: settled.tasks[0].id))
        #expect(resolved.tasks[0].phase == .resolved)
        let reopened = try await rig.perform(project.id, .reopen(taskID: settled.tasks[0].id))
        #expect(reopened.tasks[0].phase == .settled)
    }

    @Test func pauseInterruptsAndQueuesNewMessagesUntilExplicitResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create()
        let sent = try await rig.perform(project.id, .message(operationID: UUID(), text: "slow"))
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator running") { rig.agents.current[coordinator]?.stdin("prompt").count == 1 }
        let pi = try #require(rig.agents.current[coordinator])
        _ = try await pi.snapshot("coordinator active") { $0.running }
        try await eventually("revision-fenced configuration Pause") {
            guard let before = rig.host.server.state.projects.first else { return false }
            return (try? await rig.host.server.logicalProjects(.setPaused(projectID: project.id, expectedRevision: before.revision, paused: true))) != nil
        }
        try await eventually("native abort acknowledgement") { rig.agents.current[coordinator]?.stdin("abort").count ?? 0 > 0 }
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "after pause"))
        #expect(rig.agents.current[coordinator]?.stdin("prompt").count == 1)
        try await eventually("safe pause acknowledgement") { rig.host.server.state.projects.first?.interruptPending == false }
        _ = try await rig.perform(project.id, .resume)
        try await eventually("retained message after resume") { rig.agents.current[coordinator]?.stdin("prompt").count == 2 }
    }

    @Test func restartKeepsUnknownWorkersPausedAndDeletionPreservesOrdinaryThreads() async throws {
        let rig = try Rig()
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Work", prompt: "hang"))
        try await eventually("worker prompt") { rig.agents.current.values.first?.stdin("prompt").count == 1 }
        let worker = try #require(rig.agents.current.values.first?.agent.id)
        rig.host.server.onProjectRuntimeLaunch = nil
        rig.host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: rig.host.dir); defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        let saved = try #require(restarted.server.state.projects.first)
        #expect(saved.paused && saved.tasks.first?.phase == .unknown)
        #expect(await restarted.server.listSessions().isEmpty)
        _ = try await restarted.server.logicalProjects(.delete(projectID: project.id, expectedRevision: saved.revision))
        #expect(restarted.server.state.agents.contains { $0.id == worker })
        #expect(FileManager.default.fileExists(atPath: restarted.dir.appendingPathComponent("logical-projects/\(project.id)").path))
    }

    @Test func followupsReuseTheWorkerAndQuestionsCanBeAnsweredOnlyOnceAcrossViews() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("worker launched") { rig.agents.current.count == 1 }
        let pi = try #require(rig.agents.current.values.first)
        let asked = try await pi.snapshot("worker question") { !$0.dialogs.isEmpty }
        try await eventually("question receipt persisted") { rig.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        let state = try #require(rig.host.server.state.projects.first), task = try #require(state.tasks.first)
        #expect(task.phase == .waiting)
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                               operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await rig.host.server.answerProjectQuestion(project.id, expectedRevision: state.revision, taskID: task.id, request: answer).failureCode == nil)
        let duplicate = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation,
                                                   operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await pi.request(duplicate).failureCode != nil)
        _ = try await pi.waitForStdin("extension_ui_response")
        #expect(pi.stdin("extension_ui_response").count == 1)
        try await eventually("question task settled") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        _ = try await rig.perform(project.id, .followUp(taskID: task.id, operationID: UUID(), text: "follow-up"))
        try await eventually("same worker received follow-up") { pi.stdin("prompt").count == 2 }
        #expect(rig.agents.current.count == 1)
        #expect(rig.host.server.state.projects.first?.tasks.first?.workerAgentID == pi.agent.id)
    }

    @Test func theDefaultActivationCapLeavesTheThirteenthAssignmentQueuedAndManualThreadsUsable() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        for i in 0..<13 { _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Task \(i)", prompt: "hello")) }
        try await eventually("default activation bound") { rig.host.server.state.projects.first?.paused == true }
        #expect(rig.agents.current.count <= 12)
        #expect(rig.host.server.state.projects.first?.tasks.filter { $0.phase == .queued }.count == 1, "Exactly twelve reservations hit the default cap")
        let pi = try #require(rig.agents.current.values.first)
        try await eventually("limit interruption acknowledged") { rig.host.server.state.projects.first?.interruptPending == false }
        let before = try await pi.snapshot("ordinary worker idle") { !$0.running }
        let promptsBefore = pi.stdin("prompt").count
        #expect(try await pi.send("manual after bound", from: before).failureCode == nil)
        try await pi.waitForStdin("prompt", count: promptsBefore + 1)
    }

    @Test func anExitedWorkerFailsItsAssignmentRatherThanHoldingTheQueueForever() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Exit", prompt: "die"))
        try await eventually("failed exited assignment") { rig.host.server.state.projects.first?.tasks.first?.phase == .failed }
        #expect(rig.host.server.state.projects.first?.tasks.first?.error?.contains("exited") == true)
        #expect(rig.agents.current.count == 1)
    }

    @Test func aFailedSettlementWriteStopsAdmissionsInsteadOfStartingQueuedWork() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        for i in 0..<4 { _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Task \(i)", prompt: "slow")) }
        try await eventually("three started workers") { rig.agents.current.count == 3 && rig.agents.current.values.allSatisfy { $0.stdin("prompt").count == 1 } }
        try FileManager.default.removeItem(at: rig.host.stateURL)
        try FileManager.default.createDirectory(at: rig.host.stateURL, withIntermediateDirectories: false)
        for pi in rig.agents.current.values { pi.release(1); pi.release(2) }
        try await eventually("failed persistence stops run admission") {
            await withCheckedContinuation { continuation in
                rig.host.server.queue.async { continuation.resume(returning: rig.host.server.projectRunStarts[project.id] == nil) }
            }
        }
        #expect(rig.agents.current.count == 3)
        #expect(rig.host.server.state.projects.first?.tasks.contains { $0.phase == .queued } == true)
    }

    @Test func launchFailuresFreeSlotsWithoutRetryAndRunBoundsReallyPause() async throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.host.server.onProjectRuntimeLaunch = { _, done in done(.failure(WireError("launch refused"))) }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Fail", prompt: "hello"))
        try await eventually("failed reservation") { rig.host.server.state.projects.first?.tasks.first?.phase == .failed }
        #expect(rig.host.server.state.projects.first?.tasks.first?.error == "launch refused")
        rig.host.server.projectActivationLimit = 0
        _ = try await rig.perform(project.id, .resume)
        try await eventually("activation pause persisted") { rig.host.server.state.projects.first?.paused == true && rig.host.server.state.projects.first?.interruptPending == false }
        rig.host.server.projectActivationLimit = 12
        rig.host.server.projectRunSeconds = 0
        _ = try await rig.perform(project.id, .resume)
        try await eventually("time pause persisted") { rig.host.server.state.projects.first?.paused == true }
        #expect(await rig.host.server.listSessions().isEmpty)
    }
}
