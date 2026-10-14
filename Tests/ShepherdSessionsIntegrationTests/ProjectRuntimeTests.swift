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

    @Test(arguments: [false, true])
    func coordinatorLaunchFailurePreservesQueuedDeliveryAndOnlyRetiresUncreatedAgents(persistAgent: Bool) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let launcher = try #require(rig.host.server.onProjectRuntimeLaunch)
        let held = Locked<(ProjectRuntimeLaunch, @Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        rig.host.server.onProjectRuntimeLaunch = { launch, done in held.withValue { $0 = (launch, done) } }
        let project = try await rig.create()
        do {
            _ = try await rig.host.server.projectConversation(project.id, request: .snapshot())
            Issue.record("An unopened Project has no conversation")
        } catch let error as LogicalProjectsError { #expect(error.code == "no_conversation") }

        let operation = UUID()
        let sent = try await rig.perform(project.id, .message(operationID: operation, text: "hello"))
        let reserved = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator launch held before persistence") { held.current != nil }
        let (launch, done) = try #require(held.current)
        #expect(launch.agentID == reserved)
        #expect(rig.host.server.state.agents.isEmpty)
        let pending = try await rig.host.server.projectConversation(project.id, request: .snapshot())
        #expect(pending.failureCode == NativeThreadCode.starting)
        do {
            _ = try await rig.host.server.nativeThread(agentID: reserved, request: .snapshot())
            Issue.record("An ordinary native request must refuse the nonexistent Agent")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == NativeThreadCode.unavailable && message == "The agent no longer exists.")
        }

        if persistAgent {
            let pane = LeafPane(cwd: launch.cwd, agentID: reserved)
            let tab = Tab(spaceID: launch.spaceID, order: 0, layout: .leaf(pane))
            let agent = Agent(id: reserved, name: launch.name, spaceID: launch.spaceID, tabID: tab.id,
                              paneID: pane.id, coordinatorFor: project.id)
            try await rig.host.server.addAgent(agent, withTab: tab)
        }
        done(.failure(WireError("launch refused")))
        try await eventually("failed coordinator paused and reservation reconciled") {
            guard let p = rig.host.server.state.projects.first else { return false }
            return p.paused && !p.interruptPending && p.coordinatorAgentID == (persistAgent ? reserved : nil)
        }
        let failed = try #require(rig.host.server.state.projects.first)
        #expect(failed.messages.count == 1)
        #expect(failed.messages.first?.id == operation && failed.messages.first?.phase == .queued)
        #expect(rig.host.server.state.agents.map(\.id) == (persistAgent ? [reserved] : []))
        #expect(await rig.host.server.listSessions().isEmpty)
        let retainedAgent = rig.host.server.state.agents.first
        if !persistAgent {
            do {
                _ = try await rig.host.server.projectConversation(project.id, request: .snapshot())
                Issue.record("A failed uncreated reservation is not still starting")
            } catch let error as LogicalProjectsError { #expect(error.code == "no_conversation") }
        }

        rig.host.server.onProjectRuntimeLaunch = launcher
        _ = try await rig.perform(project.id, .resume)
        try await eventually("original queued operation delivered after explicit resume") {
            rig.host.server.state.projects.first?.messages.first?.phase == .delivered
        }
        let resumed = try #require(rig.host.server.state.projects.first)
        let coordinator = try #require(resumed.coordinatorAgentID)
        #expect(persistAgent ? coordinator == reserved : coordinator != reserved)
        #expect(rig.host.server.state.agents.map(\.id) == [coordinator])
        if let retainedAgent {
            #expect(rig.host.server.state.agents.first?.tabID == retainedAgent.tabID)
            #expect(rig.host.server.state.agents.first?.paneID == retainedAgent.paneID)
        }
        #expect(resumed.messages.count == 1 && resumed.messages.first?.id == operation)
        let pi = try #require(rig.agents.current[coordinator])
        #expect(pi.stdin("prompt").count == 1)
        _ = try await rig.perform(project.id, .message(operationID: operation, text: "hello"))
        #expect(pi.stdin("prompt").count == 1, "retrying the original operation never sends it twice")
    }

    @Test func delayedCoordinatorFailureFencesConcurrentMessagesAndResumeGetsFreshRunBounds() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let launcher = try #require(rig.host.server.onProjectRuntimeLaunch)
        let held = Locked<(ProjectRuntimeLaunch, @Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        let launches = Locked(0)
        rig.host.server.onProjectRuntimeLaunch = { launch, done in
            launches.withValue { $0 += 1 }
            held.withValue { $0 = (launch, done) }
        }
        let project = try await rig.create(), original = UUID(), concurrent = UUID()
        _ = try await rig.perform(project.id, .message(operationID: original, text: "hello"))
        try await eventually("held coordinator launch") { held.current != nil }
        let (launch, done) = try #require(held.current)
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("failure persistence held") { entered.current }
        let expiredStart = Date().addingTimeInterval(-600)
        try await rig.host.server.enqueue {
            rig.host.server.projectRunStarts[project.id] = expiredStart
        }
        done(.failure(WireError("launch refused")))
        try await eventually("failure synchronously revokes run but retains launch fence") {
            try await rig.host.server.enqueue {
                rig.host.server.projectRunStarts[project.id] == nil
                    && rig.host.server.projectLaunches.contains(launch.agentID)
                    && rig.host.server.projectRuntimeWriterBusy
            }
        }
        do {
            _ = try await rig.host.server.projectConversation(project.id, request: .snapshot())
            Issue.record("A failed launch waiting for persistence is not starting")
        } catch let error as LogicalProjectsError { #expect(error.code == "no_conversation") }
        let message = Task { try await rig.perform(project.id, .message(operationID: concurrent, text: "second")) }
        try await eventually("concurrent message waits behind failure") {
            try await rig.host.server.enqueue { !rig.host.server.projectRuntimeWriters.isEmpty }
        }
        try await rig.host.server.enqueue { rig.host.server.pumpProject(project.id) }
        #expect(launches.current == 1)
        gate.signal()
        _ = try await message.value
        try await eventually("failure saved and concurrent message retained without relaunch") {
            guard let p = rig.host.server.state.projects.first else { return false }
            return p.paused && p.coordinatorAgentID == nil && p.messages.count == 2
        }
        #expect(launches.current == 1)
        #expect(rig.host.server.state.projects.first?.messages.map(\.id) == [original, concurrent])
        rig.host.server.onProjectRuntimeLaunch = launcher
        _ = try await rig.perform(project.id, .resume)
        let started = try await rig.host.server.enqueue { rig.host.server.projectRunStarts[project.id] }
        #expect(try #require(started) > expiredStart)
        try await eventually("both retained operations delivered once after fresh Resume") {
            rig.host.server.state.projects.first?.messages.allSatisfy { $0.phase == .delivered } == true
        }
        let id = try #require(rig.host.server.state.projects.first?.coordinatorAgentID)
        #expect(try #require(rig.agents.current[id]).stdin("prompt").count == 2)
    }

    @Test func lateCoordinatorLaunchFailureRetainsEstablishedNativeHistory() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let launcher = try #require(rig.host.server.onProjectRuntimeLaunch)
        let held = Locked<(@Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        rig.host.server.onProjectRuntimeLaunch = { launch, done in
            launcher(launch) { result in
                if case .success = result { held.withValue { $0 = done } }
                else { done(result) }
            }
        }
        let project = try await rig.create(), operation = UUID()
        let sent = try await rig.perform(project.id, .message(operationID: operation, text: "hello"))
        let id = try #require(sent.coordinatorAgentID)
        try await eventually("native conversation established before launch completion") {
            held.current != nil && rig.host.server.state.projects.first?.messages.first?.phase == .delivered
        }
        let pi = try #require(rig.agents.current[id])
        let before = try await pi.snapshot("settled native history") { !$0.running && !$0.messages.isEmpty }
        let agent = try #require(rig.host.server.state.agents.first)
        let done = try #require(held.current)
        done(.failure(WireError("late launch failure")))
        try await eventually("late launch failure pauses with coordinator retained") {
            rig.host.server.state.projects.first?.paused == true
        }
        #expect(rig.host.server.state.projects.first?.coordinatorAgentID == id)
        #expect(rig.host.server.state.agents.first?.tabID == agent.tabID)
        let result = try await rig.host.server.projectConversation(project.id, request: .snapshot())
        guard case .snapshot(let after) = result else { Issue.record("Native history was not retained"); return }
        #expect(after.piSessionID == before.piSessionID && after.generation == before.generation)
        #expect(after.messages == before.messages)
        #expect(rig.host.server.state.projects.first?.messages.first?.id == operation)
        #expect(pi.stdin("prompt").count == 1)
    }

    @Test func lateCoordinatorFailureInterruptsItsActiveTurnAndResumeWaitsForAcknowledgement() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let launcher = try #require(rig.host.server.onProjectRuntimeLaunch)
        let held = Locked<(ProjectRuntimeLaunch, @Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        rig.host.server.onProjectRuntimeLaunch = { launch, done in
            launcher(launch) { result in
                if case .success = result { held.withValue { $0 = (launch, done) } }
                else { done(result) }
            }
        }
        let project = try await rig.create(), operation = UUID()
        let sent = try await rig.perform(project.id, .message(operationID: operation, text: "tools:1"))
        let id = try #require(sent.coordinatorAgentID)
        try await eventually("active coordinator before launch completion") {
            held.current != nil && rig.host.server.state.projects.first?.messages.first?.phase == .delivered
        }
        let pi = try #require(rig.agents.current[id])
        let before = try await pi.snapshot("active native turn") { $0.running && !$0.messages.isEmpty }
        let (launch, done) = try #require(held.current)
        let refusal = URL(fileURLWithPath: launch.cwd).appendingPathComponent("refuse-abort")
        try Data().write(to: refusal)
        done(.failure(WireError("late launch failure")))
        try await eventually("failure requests native interruption but cannot claim its acknowledgement") {
            let p = rig.host.server.state.projects.first
            return p?.paused == true && p?.interruptPending == true && pi.stdin("abort").count == 1
        }
        do {
            _ = try await rig.perform(project.id, .resume)
            Issue.record("Resume must wait for interruption acknowledgement")
        } catch let error as LogicalProjectsError { #expect(error.code == "conflict") }
        #expect(rig.host.server.state.projects.first?.coordinatorAgentID == id)
        try FileManager.default.removeItem(at: refusal)
        _ = try await rig.perform(project.id, .pause)
        try await eventually("explicit Pause retries and acknowledges native interruption") {
            rig.host.server.state.projects.first?.interruptPending == false && pi.stdin("abort").count == 2
        }
        let after = try await pi.snapshot("interrupted coordinator retains its conversation") { !$0.running }
        #expect(after.piSessionID == before.piSessionID && after.generation == before.generation)
        #expect(Set(before.messages.map(\.entryID)).isSubset(of: Set(after.messages.map(\.entryID))))
        #expect(rig.host.server.state.projects.first?.messages.first?.id == operation)
        #expect(pi.stdin("prompt").count == 1)
        _ = try await rig.perform(project.id, .resume)
        #expect(rig.host.server.state.projects.first?.paused == false)
        #expect(pi.stdin("prompt").count == 1, "Resume never replays the consumed Project operation")
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

    /// Projects never pause on their own: thirteen assignments (past the old twelve-activation bound) all run, a few at a time.
    @Test func manyAssignmentsAllRunAndTheProjectNeverPausesItself() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        for i in 0..<13 { _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Task \(i)", prompt: "hello")) }
        try await eventually("all thirteen settled") { rig.host.server.state.projects.first?.tasks.filter { $0.phase == .settled }.count == 13 }
        #expect(rig.agents.current.count == 13)
        #expect(rig.host.server.state.projects.first?.paused == false)
    }

    /// The coordinator chooses a task's thinking level; a follow-up can change it, and the worker's pi is set to it before the prompt.
    @Test func aTasksThinkingLevelIsTheCoordinatorsChoice() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Bad", prompt: "hello", thinking: "extreme"))
        }
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Bad", prompt: "hello", model: "nobody/unlisted"))
        }
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Hard", prompt: "hello", thinking: "high"))
        try await eventually("settled") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first)
        #expect(task.thinking == "high")
        let pi = try #require(rig.agents.current[task.workerAgentID])
        #expect(pi.stdin("set_thinking_level").last?["level"] as? String == "high")
        _ = try await rig.perform(project.id, .followUp(taskID: task.id, operationID: UUID(), text: "hello", thinking: "low"))
        try await eventually("follow-up settled") { pi.stdin("prompt").count == 2 && rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        #expect(rig.host.server.state.projects.first?.tasks.first?.thinking == "low")
        #expect(pi.stdin("set_thinking_level").last?["level"] as? String == "low")
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

    @Test func launchFailuresFreeSlotsWithoutRetryAndNeverPauseTheProject() async throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.host.server.onProjectRuntimeLaunch = { _, done in done(.failure(WireError("launch refused"))) }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Fail", prompt: "hello"))
        try await eventually("failed reservation") { rig.host.server.state.projects.first?.tasks.first?.phase == .failed }
        #expect(rig.host.server.state.projects.first?.tasks.first?.error == "launch refused")
        #expect(rig.host.server.state.projects.first?.paused == false)
        #expect(await rig.host.server.listSessions().isEmpty)
    }
}
