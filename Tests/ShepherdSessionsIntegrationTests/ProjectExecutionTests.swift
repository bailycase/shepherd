import Foundation
import Darwin
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Durable Project executor", .integrationTimeLimit)
struct ProjectExecutionTests {
    final class Rig: @unchecked Sendable {
        let remote: RemoteHost
        let owner: ScratchServer
        let agents = Locked<[AgentID: PiAgent]>([:])
        let launches = Locked(0)
        let heldLaunch = Locked<(@Sendable () -> Void)?>(nil)
        let heldCompletion = Locked<(@Sendable () -> Void)?>(nil)
        let heldPreparation = Locked<(() -> Void)?>(nil)
        let heldSettlement = Locked<(() -> Void)?>(nil)
        var host: ScratchServer { remote.host }
        init(hold: Bool = false, holdPreparation: Bool = false, holdSettlement: Bool = false, holdCompletion: Bool = false) throws {
            remote = try RemoteHost()
            owner = try ScratchServer()
            remote.server.setProjectsEnabled(true)
            owner.server.setProjectsEnabled(true)
            let host = remote.host, agents = agents, launches = launches, held = heldLaunch
            let preparation = heldPreparation, settlement = heldSettlement, completion = heldCompletion
            host.server.onProjectExecutionLaunch = { assignment, done in
                launches.withValue { $0 += 1 }
                let launch: @Sendable () -> Void = {
                    Task {
                        do {
                            let space = try #require(host.server.state.spaces.first { $0.id == assignment.executorSpaceID })
                            let agent: Agent, tab: Tab, pane: LeafPane
                            if let existing = host.server.state.agents.first(where: { $0.id == assignment.reservedWorkerID }) {
                                agent = existing
                                tab = try #require(host.server.state.tabs.first { $0.id == agent.tabID })
                                pane = try #require(tab.layout.leaves.first)
                            } else {
                                pane = LeafPane(cwd: space.path, agentID: assignment.reservedWorkerID)
                                tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
                                agent = Agent(id: assignment.reservedWorkerID, name: assignment.title, spaceID: space.id, tabID: tab.id, paneID: pane.id)
                                try await host.server.addAgent(agent, withTab: tab)
                            }
                            let log = host.dir.appendingPathComponent("\(agent.id).log")
                            let session = try await host.server.createSession(params: .init(cwd: space.path, command: StubPi.command,
                                env: ["STUB_PI_LOG": log.path, "SHEPHERD_AGENT_ID": agent.id.rawValue,
                                      "STUB_PI_MESSAGES_FILE": host.dir.appendingPathComponent("\(agent.id)-messages.json").path], runtime: .rpc))
                            try await host.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: session.id)
                            agents.withValue { $0[agent.id] = PiAgent(host: host, agent: agent, sessionID: session.id, log: log) }
                            try await host.server.enqueue {
                                let thread = try #require(host.server.rpcThread(forAgent: agent.id))
                                if holdPreparation { thread.beforePrompt = { done in preparation.withValue { $0 = done } } }
                                if holdSettlement { thread.captureSettledTurn = { done in settlement.withValue { $0 = done } } }
                            }
                            if holdCompletion { completion.withValue { $0 = { done(.success(agent.id)) } } }
                            else { done(.success(agent.id)) }
                        } catch { done(.failure(error)) }
                    }
                }
                if hold { held.withValue { $0 = launch } } else { launch() }
            }
        }
        func stop() { host.server.onProjectExecutionLaunch = nil; remote.stop(); owner.stop() }
        func assignment(_ prompt: String = "tools:0") async throws -> ProjectExecutionAssignment {
            let space = Space(name: "Executor", path: host.dir.path)
            try await host.server.addSpace(space)
            return .init(key: .init(ownerID: UUID(), projectID: ProjectID(), operationID: UUID()), taskID: ProjectTaskID(),
                         reservedWorkerID: AgentID(), executorSpaceID: space.id, title: "Task", prompt: prompt)
        }
        func receipt(_ assignment: ProjectExecutionAssignment) -> ProjectExecutionReceipt? {
            host.server.state.projectExecutions.first { $0.key == assignment.key }
        }
        /// Deterministically puts manual input into the async send-reservation write window.
        func queueBehindManual(_ assignment: ProjectExecutionAssignment, precedingManual: Bool) async throws -> PiAgent {
            _ = try await host.server.projectExecution(.execute(assignment))
            let worker = try await pi(assignment), ready = try await worker.ready()
            _ = try await worker.queue(.setMode(mode: .all), from: ready)
            try await eventually("held launch completion") { self.heldCompletion.current != nil }
            let gate = DispatchSemaphore(value: 0), entered = Locked(false)
            defer { gate.signal() }
            host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
            try await eventually("held send reservation write") { entered.current }
            heldCompletion.current?()
            try await eventually("send reservation staging") { try await self.host.server.enqueue { self.host.server.executionSending.contains(assignment.key) } }
            _ = try await worker.send("tools:1 manual active", from: ready)
            let running = try await worker.snapshot("manual won the write race") { $0.running }
            if precedingManual { _ = try await worker.send("tools:0 manual before", from: running) }
            gate.signal()
            try await eventually("execution queued behind manual") {
                try await self.host.server.enqueue { self.host.server.rpcThread(forAgent: assignment.reservedWorkerID)?.items.contains { $0.entry.id == assignment.key.operationID } == true }
            }
            _ = try await worker.send("tools:0 manual after", from: running)
            return worker
        }

        func pi(_ assignment: ProjectExecutionAssignment) async throws -> PiAgent {
            try await eventually("reserved worker launched") { self.agents.current[assignment.reservedWorkerID] != nil }
            return try #require(agents.current[assignment.reservedWorkerID])
        }
    }

    @Test func pausedNativeQuestionSurvivesItsOldDeadlineAndExplicitResumeHasANewBound() async throws {
        let rig = try Rig(); defer { rig.stop() }
        try await rig.host.server.enqueue { rig.host.server.executionDuration = 2 }
        let assignment = try await rig.assignment("ask")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("native question retained") { rig.receipt(assignment)?.phase == .waiting }
        _ = try await rig.host.server.projectExecution(.pause(key: assignment.key))
        let admitted = try #require(rig.receipt(assignment)?.admittedAt)
        try await eventually("old execution deadline elapsed while paused") { Date().timeIntervalSince1970 > admitted + 2.1 }
        #expect(rig.receipt(assignment)?.phase == .waiting)
        #expect(rig.receipt(assignment)?.ownerPaused == true)
        _ = try await rig.host.server.projectExecution(.resume(key: assignment.key))
        try await eventually("resumed execution reaches its bound without an answer") { rig.receipt(assignment)?.phase == .cancelled }
    }

    @Test func cancellingAQueuedPreparationWithdrawsItsRestoredBatchWithoutPausingManualWork() async throws {
        let rig = try Rig(holdCompletion: true); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:0 cancelled queued operation")
        let pi = try await rig.queueBehindManual(assignment, precedingManual: false)
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: assignment.reservedWorkerID))
            thread.queueNotice = "Keep manual policy"
            thread.beforePrompt = { [weak thread] done in
                if thread?.dispatches.contains(where: { $0.id == assignment.key.operationID }) == true {
                    rig.heldPreparation.withValue { $0 = done }
                } else { done() }
            }
        }
        pi.finishTool(1)
        try await eventually("queued operation preparation held after manual settlement") { rig.heldPreparation.current != nil }
        #expect(pi.stdin("prompt").count == 1)
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        try await eventually("queued cancellation acknowledged") { rig.receipt(assignment)?.phase == .cancelled }
        try await rig.host.server.enqueue {
            let thread = try #require(rig.host.server.rpcThread(forAgent: assignment.reservedWorkerID))
            #expect(!thread.items.contains { $0.entry.id == assignment.key.operationID })
            #expect(thread.preparingPrompts[assignment.key.operationID] == nil)
            #expect(!thread.paused && thread.queueNotice == "Keep manual policy")
            rig.heldPreparation.current?()
            thread.beforePrompt = nil
        }
        try await eventually("unrelated queued manual message still delivered") { pi.stdin("prompt").count == 2 }
        _ = try await pi.snapshot("manual queue completed") { !$0.running }
        _ = try await pi.send("tools:0 ordinary resume", from: pi.ready())
        try await eventually("ordinary resume delivered") { pi.stdin("prompt").count == 3 }
        #expect(pi.stdin("prompt").compactMap { $0["message"] as? String } == ["tools:1 manual active", "tools:0 manual after", "tools:0 ordinary resume"])
    }

    @Test func managedExecutionKeepsItsOwnIdentityBetweenManualMessagesInAllAtOnceMode() async throws {
        let rig = try Rig(holdCompletion: true); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:0 isolated assignment")
        let pi = try await rig.queueBehindManual(assignment, precedingManual: true)
        pi.finishTool(1)
        try await eventually("isolated project operation settles") { rig.receipt(assignment)?.phase == .settled }
        try await eventually("both adjacent manual messages delivered separately") { pi.stdin("prompt").count == 4 }
        let snapshot = try await pi.snapshot("all isolated turns ended") { !$0.running }
        #expect(pi.stdin("prompt").compactMap { $0["message"] as? String } == ["tools:1 manual active", "tools:0 manual before", assignment.nativePrompt, "tools:0 manual after"])
        #expect(snapshot.messages.contains { $0.operationID == assignment.key.operationID && $0.entryID == rig.receipt(assignment)?.matchedUserEntryID })
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        #expect(pi.stdin("abort").isEmpty)
    }

    @Test func manualWorkBeforeLaunchCompletionDefinitivelyFailsTheFreshReservation() async throws {
        let rig = try Rig(holdCompletion: true); defer { rig.stop() }
        let assignment = try await rig.assignment()
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        _ = try await pi.send("tools:1 manual before launch completed", from: pi.ready())
        _ = try await pi.snapshot("manual turn active before launch acknowledgement") { $0.running }
        try await eventually("launcher completion held") { rig.heldCompletion.current != nil }
        rig.heldCompletion.current?()
        try await eventually("fresh reservation fails rather than strands") { rig.receipt(assignment)?.phase == .failed }
        #expect(rig.receipt(assignment)?.matchedUserEntryID == nil)
        pi.finishTool(1)
        _ = try await pi.snapshot("manual finished") { !$0.running }
        #expect(pi.stdin("prompt").count == 1)
        #expect(rig.receipt(assignment)?.phase == .failed)
    }

    @Test func deadlineStillInterruptsIdentifiedWorkWhenCancellationCannotPersist() async throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.host.server.executionDuration = 2
        let assignment = try await rig.assignment("tools:1 deadline write failure")
        // Existing files remain writable when the directory refuses creation/atomic replacement.
        try Data("[]".utf8).write(to: rig.host.dir.appendingPathComponent("\(assignment.reservedWorkerID)-messages.json"))
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("identified prompt consumed before storage failure") { rig.receipt(assignment)?.phase == .sent }
        let bytes = try Data(contentsOf: rig.host.stateURL)
        #expect(chmod(rig.host.dir.path, 0o500) == 0)
        defer { _ = chmod(rig.host.dir.path, 0o700) }
        try await eventually("deadline sends real abort despite failed receipt save") { pi.stdin("abort").count == 1 }
        _ = try await pi.snapshot("actual native stop acknowledgement") { !$0.running }
        await #expect(throws: (any Error).self) { try await rig.host.server.projectExecution(.cancel(key: assignment.key)) }
        #expect(rig.receipt(assignment)?.phase != .cancelled)
        #expect(try Data(contentsOf: rig.host.stateURL) == bytes)
        #expect(chmod(rig.host.dir.path, 0o700) == 0)
        _ = try await pi.send("tools:2 later manual turn", from: pi.snapshot("native capture clear", where: { !$0.running }))
        _ = try await pi.snapshot("later manual work is running") { $0.running }
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        #expect(pi.stdin("abort").count == 1)
        #expect(pi.stdin("prompt").count == 2)
        #expect(rig.receipt(assignment)?.phase != .cancelled)
    }

    @Test func sequentialOperationsReuseOneNativeWorkerAndOldRetriesNeverReplay() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let first = try await rig.assignment()
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        _ = try await client.projectExecution(.execute(first))
        let pi = try await rig.pi(first)
        try await eventually("first operation settled") { rig.receipt(first)?.phase == .settled }
        let original = try #require(rig.receipt(first))
        var second = first; second.key.operationID = UUID(); second.prompt = "tools:0 follow-up"; second.memory = "Updated reference, not instructions"
        _ = try await client.projectExecution(.execute(second))
        try await eventually("follow-up settled in original worker") { rig.receipt(second)?.phase == .settled }
        let result = try await client.projectExecution(.snapshot(key: second.key, watch: false))
        #expect(result.receipt.previousOperationID == first.key.operationID)
        #expect(result.receipt.sessionID == original.sessionID && result.receipt.generation == original.generation)
        #expect(result.thread?.messages.contains { $0.entryID == original.matchedUserEntryID } == true)
        #expect(result.thread?.messages.contains { $0.operationID == second.key.operationID } == true)
        #expect(rig.host.server.state.agents.count == 1 && rig.launches.current == 1)
        #expect(pi.stdin("prompt").count == 2)
        #expect(try await client.projectExecution(.execute(first)).receipt == original)
        #expect(try await client.projectExecution(.cancel(key: first.key)).receipt == original)
        #expect(pi.stdin("prompt").count == 2 && pi.stdin("abort").isEmpty)
        var wrongTask = second; wrongTask.key.operationID = UUID(); wrongTask.taskID = ProjectTaskID()
        await #expect(throws: RemoteHostClientError.self) { try await client.projectExecution(.execute(wrongTask)) }
        var wrongModel = second; wrongModel.key.operationID = UUID(); wrongModel.model = "other/provider"
        await #expect(throws: RemoteHostClientError.self) { try await client.projectExecution(.execute(wrongModel)) }
    }

    @Test func aCleanEndedWorkerRestoresOnlyItsProvenHistoryAndNeverAnEmptyReplacement() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let first = try await rig.assignment()
        _ = try await rig.host.server.projectExecution(.execute(first))
        let pi = try await rig.pi(first)
        try await eventually("settled before process loss") { rig.receipt(first)?.phase == .settled }
        rig.host.server.killSession(pi.sessionID)
        try await rig.host.waitForExit(pi.sessionID)
        var second = first; second.key.operationID = UUID(); second.prompt = "tools:0 restored"
        _ = try await rig.host.server.projectExecution(.execute(second))
        try await eventually("proven history restored and continued") { rig.receipt(second)?.phase == .settled }
        #expect(rig.host.server.state.agents.count == 1 && rig.launches.current == 2)
        #expect(rig.receipt(second)?.sessionID == rig.receipt(first)?.sessionID)
        #expect(rig.receipt(second)?.generation != rig.receipt(first)?.generation)
        let restored = try #require(rig.agents.current[first.reservedWorkerID])
        rig.host.server.killSession(restored.sessionID)
        try await rig.host.waitForExit(restored.sessionID)
        try FileManager.default.removeItem(at: rig.host.dir.appendingPathComponent("\(first.reservedWorkerID)-messages.json"))
        var third = first; third.key.operationID = UUID(); third.prompt = "tools:0 must not run"
        _ = try await rig.host.server.projectExecution(.execute(third))
        try await eventually("empty bootstrap refused before follow-up") { rig.receipt(third)?.phase == .failed }
        #expect(rig.receipt(third)?.outcome?.contains("conversation is unavailable") == true)
        #expect(rig.host.server.state.agents.count == 1)
        #expect(restored.stdin("prompt").count == 2)
    }

    @Test func manualBusyWorkerBlocksFollowupAndOldCancellationCannotAbortTheNextActivation() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let first = try await rig.assignment()
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        _ = try await client.projectExecution(.execute(first))
        let pi = try await rig.pi(first)
        try await eventually("initial project settlement") { rig.receipt(first)?.phase == .settled }
        _ = try await pi.send("tools:1 manual", from: pi.ready())
        _ = try await pi.snapshot("manual turn running") { $0.running }
        var second = first; second.key.operationID = UUID(); second.prompt = "tools:2 follow-up"
        await #expect(throws: RemoteHostClientError.self) { try await client.projectExecution(.execute(second)) }
        #expect(rig.receipt(second) == nil)
        _ = try await client.projectExecution(.cancel(key: first.key))
        #expect(pi.stdin("abort").isEmpty)
        FileManager.default.createFile(atPath: rig.host.dir.appendingPathComponent("tool-1").path, contents: nil)
        _ = try await pi.snapshot("manual turn ended") { !$0.running }
        try await eventually("capture finished") { try await rig.host.server.enqueue { rig.host.server.rpcThread(forAgent: first.reservedWorkerID)?.piBusy == false } }
        rig.host.server.executionDuration = 2
        _ = try await client.projectExecution(.execute(second))
        try await eventually("next project turn consumed") { rig.receipt(second)?.phase == .sent }
        _ = try await client.projectExecution(.cancel(key: first.key))
        _ = try await client.projectExecution(.execute(first))
        #expect(pi.stdin("abort").isEmpty)
        #expect(pi.stdin("prompt").count == 3 && rig.launches.current == 1)
        try await eventually("the new activation's own deadline interrupts it") { rig.receipt(second)?.phase == .cancelled }
        #expect(rig.receipt(first)?.phase == .settled)
        #expect(pi.stdin("abort").count == 1)
    }

    @Test func manualWorkWinningTheOffQueueAdmissionRaceIsNeverQueuedBehindOrInterrupted() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let first = try await rig.assignment()
        _ = try await rig.host.server.projectExecution(.execute(first))
        let pi = try await rig.pi(first)
        try await eventually("settled before admission race") { rig.receipt(first)?.phase == .settled }
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("follow-up persistence held") { entered.current }
        var next = first; next.key.operationID = UUID(); next.prompt = "tools:0 must not queue"
        let followup = next
        let request = Task { try await rig.host.server.projectExecution(.execute(followup)) }
        try await eventually("follow-up admitted before disk") { try await rig.host.server.enqueue { rig.host.server.executionPending.contains(followup.key) } }
        _ = try await pi.send("tools:1 manual race winner", from: pi.ready())
        _ = try await pi.snapshot("manual running while receipt stages") { $0.running }
        gate.signal()
        _ = try await request.value
        try await eventually("busy recheck refuses delivery") { rig.receipt(followup)?.phase == .failed }
        #expect(rig.receipt(followup)?.matchedUserEntryID == nil)
        #expect(pi.stdin("prompt").count == 2 && pi.stdin("abort").isEmpty)
    }

    @Test func disconnectedBusyOrRestartedUnknownWorkersCannotBeAdoptedByFollowups() async throws {
        let rig = try Rig(); defer { rig.owner.stop() }
        let first = try await rig.assignment("tools:1")
        let client = try await rig.remote.typed()
        _ = try await client.projectExecution(.execute(first))
        try await eventually("active before owner disconnect") { rig.receipt(first)?.phase == .sent }
        client.disconnect()
        let reconnect = try await rig.remote.typed()
        var next = first; next.key.operationID = UUID()
        await #expect(throws: RemoteHostClientError.self) { try await reconnect.projectExecution(.execute(next)) }
        reconnect.disconnect()
        rig.host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: rig.host.dir); defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        restarted.server.onProjectExecutionLaunch = { _, _ in Issue.record("Unknown must not relaunch") }
        await #expect(throws: LogicalProjectsError.self) { try await restarted.server.projectExecution(.execute(next)) }
        #expect(try await restarted.server.projectExecution(.execute(first)).receipt.phase == .unknown)
        #expect(restarted.server.state.agents.count == 1)
        #expect(await restarted.server.listSessions().isEmpty)
    }

    @Test func duplicateAndLostReplyCreateOnceWhileChangedPayloadIsRefused() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment()
        let raw = try RawRemote(port: rig.remote.port)
        _ = try await raw.hello(token: rig.remote.token, capabilities: [RemoteProtocol.projectExecutionCapability])
        try raw.send(.projectExecution(id: 2, request: .execute(assignment)))
        try await eventually("durable receipt despite lost response") { rig.receipt(assignment) != nil }
        raw.closeConnection()
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        _ = try await client.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("proven native settlement") { rig.receipt(assignment)?.phase == .settled }
        let receipt = try await client.projectExecution(.execute(assignment)).receipt
        #expect(receipt.matchedUserEntryID != nil)
        #expect(receipt.resultText?.isEmpty == false)
        #expect(pi.stdin("prompt").count == 1 && rig.launches.current == 1)
        var changed = assignment; changed.prompt = "different"
        await #expect(throws: RemoteHostClientError.self) { try await client.projectExecution(.execute(changed)) }
        #expect(pi.stdin("prompt").count == 1)
        #expect(rig.owner.server.state.agents.isEmpty)
    }

    @Test func cancelBeforeExecuteAndDuringHeldLaunchPersistWithoutCreatingWorker() async throws {
        let rig = try Rig(hold: true); defer { rig.stop() }
        let cancelled = try await rig.assignment()
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        #expect(try await client.projectExecution(.cancel(key: cancelled.key)).receipt.phase == .cancelled)
        #expect(try await client.projectExecution(.execute(cancelled)).receipt.phase == .cancelled)
        #expect(rig.launches.current == 0)
        let held = try await rig.assignment()
        _ = try await client.projectExecution(.execute(held))
        try await eventually("held launch callback") { rig.heldLaunch.current != nil }
        _ = try await client.projectExecution(.cancel(key: held.key))
        rig.heldLaunch.current?()
        // A queue barrier after the refused addAgent proves no metadata can be committed.
        try await eventually("cancelled receipt") { rig.receipt(held)?.phase == .cancelled }
        #expect(rig.host.server.state.agents.isEmpty)
        #expect(try rig.host.persisted().projectExecutions.count == 2)
    }

    @Test func disconnectRetainsQuestionThenActualResultAndManualFollowupStillWorks() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("question")
        let client = try await rig.remote.typed()
        _ = try await client.projectExecution(.execute(assignment))
        let revisions = Locked<[UInt64]>([])
        client.onProjectExecutionChanged = { key, revision in if key == assignment.key { revisions.withValue { $0.append(revision) } } }
        _ = try await client.projectExecution(.snapshot(key: assignment.key, watch: true))
        let pi = try await rig.pi(assignment)
        let question = try await pi.snapshot("native question") { !$0.dialogs.isEmpty }
        try await eventually("durable question") { rig.receipt(assignment)?.questionID == question.dialogs.first?.id }
        try await eventually("receipt hint") { !revisions.current.isEmpty }
        client.disconnect()
        let dialog = try #require(question.dialogs.first)
        _ = try await rig.host.server.nativeThread(agentID: assignment.reservedWorkerID,
            request: .answer(expectedSessionID: question.piSessionID, generation: question.generation, operationID: UUID(), dialogID: dialog.id, answer: .select(value: "Leave Horizon alone")))
        try await eventually("settled disconnected worker") { rig.receipt(assignment)?.phase == .settled }
        let reconnect = try await rig.remote.typed(); defer { reconnect.disconnect() }
        let result = try await reconnect.projectExecution(.snapshot(key: assignment.key, watch: true))
        #expect(result.receipt.question == dialog.title && result.receipt.questionID == dialog.id)
        #expect(result.receipt.resultText?.isEmpty == false)
        #expect(result.thread != nil)
        _ = try await reconnect.projectExecution(.cancel(key: assignment.key))
        let ready = try await pi.ready()
        _ = try await pi.send("ordinary manual followup", from: ready)
        try await eventually("manual prompt") { pi.stdin("prompt").count == 2 }
        #expect(rig.receipt(assignment)?.phase == .settled)
    }

    @Test func deadlineInterruptsAndRestartNeverReplaysInFlightReceipt() async throws {
        let rig = try Rig(); defer { rig.owner.stop() }
        rig.host.server.executionDuration = 2
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("deadline acknowledged") { rig.receipt(assignment)?.phase == .cancelled }
        #expect(pi.stdin("abort").count == 1)
        let ready = try await pi.ready()
        _ = try await pi.send("manual after deadline", from: ready)
        try await eventually("ordinary work still usable") { pi.stdin("prompt").count == 2 }
        rig.host.server.executionDuration = 600
        let inFlight = try await rig.assignment("tools:2")
        _ = try await rig.host.server.projectExecution(.execute(inFlight))
        _ = try await rig.pi(inFlight)
        try await eventually("started operation") { rig.receipt(inFlight)?.phase == .sent }
        rig.host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: rig.host.dir); defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        restarted.server.onProjectExecutionLaunch = { _, _ in Issue.record("Restart must not launch") }
        #expect(restarted.server.state.projectExecutions.first { $0.key == inFlight.key }?.phase == .unknown)
        #expect(try await restarted.server.projectExecution(.execute(inFlight)).receipt.phase == .unknown)
        #expect(await restarted.server.listSessions().isEmpty)
    }

    @Test func queuedAcceptanceIsNotSentAndStatusIdleDoesNotProveSettlement() async throws {
        let rig = try Rig(holdSettlement: true); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:0 hold-start")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        _ = try await pi.snapshot("pi accepted but not consumed") { $0.running }
        #expect(rig.receipt(assignment)?.phase == .sendReserved)
        #expect(rig.receipt(assignment)?.matchedUserEntryID == nil)
        FileManager.default.createFile(atPath: rig.host.dir.appendingPathComponent("start").path, contents: nil)
        try await eventually("capture awaiting completion") { rig.heldSettlement.current != nil }
        try await eventually("consumption evidence persisted while capture remains held") { rig.receipt(assignment)?.phase == .sent }
        #expect(rig.receipt(assignment)?.phase == .sent)
        _ = try await pi.snapshot("native reports idle before capture") { !$0.running }
        #expect(rig.receipt(assignment)?.phase != .settled)
        try await rig.host.server.enqueue { rig.heldSettlement.current?() }
        try await eventually("capture acknowledged settlement") { rig.receipt(assignment)?.phase == .settled }
    }

    @Test func cancelDuringPromptPreparationDoesNotSendAndLeavesManualWorkerUsable() async throws {
        let rig = try Rig(holdPreparation: true); defer { rig.stop() }
        let assignment = try await rig.assignment()
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("prompt preparation held") { rig.heldPreparation.current != nil }
        #expect(pi.stdin("prompt").isEmpty)
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        try await eventually("targeted preparation cancellation") { rig.receipt(assignment)?.phase == .cancelled }
        try await rig.host.server.enqueue {
            rig.heldPreparation.current?()
            rig.host.server.rpcThread(forAgent: assignment.reservedWorkerID)?.beforePrompt = nil
        }
        #expect(pi.stdin("prompt").isEmpty)
        let ready = try await pi.ready()
        _ = try await pi.send("tools:0 manual", from: ready)
        try await eventually("manual prompt after cancellation") { pi.stdin("prompt").count == 1 }
        #expect(rig.receipt(assignment)?.matchedUserEntryID == nil)
    }

    @Test func aManualSteerTakingOverTheTurnIsNotInterruptedByLaterProjectCancellation() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        let pi = try await rig.pi(assignment)
        try await eventually("project message consumed") { rig.receipt(assignment)?.phase == .sent }
        let snapshot = try await pi.ready()
        _ = try await pi.send("tools:2 manual", delivery: .steer, from: snapshot)
        FileManager.default.createFile(atPath: rig.host.dir.appendingPathComponent("tool-1").path, contents: nil)
        try await eventually("manual message supersedes project evidence") { rig.receipt(assignment)?.phase == .unknown }
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        try await eventually("explicit cancellation releases the superseded activation") { rig.receipt(assignment)?.phase == .cancelled }
        #expect(pi.stdin("abort").isEmpty)
        #expect(rig.receipt(assignment)?.resultText == nil)
        #expect(try await pi.ready().running)
    }

    @Test func stagedReceiptPreservesConcurrentWorkspaceEditsAndLaunchFailuresAreDurable() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let assignment = try await rig.assignment()
        rig.host.server.onProjectExecutionLaunch = { _, done in done(.failure(WireError("definite launch failure"))) }
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("receipt disk queue held") { entered.current }
        let request = Task { try await rig.host.server.projectExecution(.execute(assignment)) }
        try await eventually("receipt reservation on server queue") { try await rig.host.server.enqueue { rig.host.server.executionPending.contains(assignment.key) } }
        let concurrent = Space(name: "Concurrent ordinary edit", path: rig.owner.dir.path)
        try await rig.host.server.addSpace(concurrent)
        gate.signal()
        _ = try await request.value
        try await eventually("actual launch failure persisted") { rig.receipt(assignment)?.phase == .failed }
        #expect(rig.host.server.state.spaces.contains { $0.id == concurrent.id })
        #expect(try rig.host.persisted().spaces.contains { $0.id == concurrent.id })
        #expect(rig.receipt(assignment)?.outcome?.contains("definite launch failure") == true)
        #expect(rig.host.server.state.agents.isEmpty)
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        #expect(rig.receipt(assignment)?.phase == .failed)
    }

    @Test func deletingWorkerMetadataKeepsProvenReceiptsAndNeverReplaysAnUnknownWorker() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let settled = try await rig.assignment()
        _ = try await rig.host.server.projectExecution(.execute(settled))
        try await eventually("settlement before deletion") { rig.receipt(settled)?.phase == .settled }
        let evidence = rig.receipt(settled)?.resultText
        try await rig.host.server.deleteAgent(settled.reservedWorkerID)
        #expect(rig.receipt(settled)?.phase == .settled && rig.receipt(settled)?.resultText == evidence)
        let active = try await rig.assignment("tools:1")
        _ = try await rig.host.server.projectExecution(.execute(active))
        try await eventually("consumed before deletion") { rig.receipt(active)?.phase == .sent }
        try await rig.host.server.deleteAgent(active.reservedWorkerID)
        try await eventually("deleted worker outcome retained") { rig.receipt(active)?.phase == .unknown }
        _ = try await rig.host.server.projectExecution(.execute(active))
        #expect(rig.launches.current == 2)
        #expect(!rig.host.server.state.agents.contains { $0.id == active.reservedWorkerID })
    }

    @Test func stoppingDuringReceiptStagingNeverCommitsOrLaunchesAfterRestart() async throws {
        let rig = try Rig(hold: true); defer { rig.stop() }
        let assignment = try await rig.assignment()
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("held executor storage") { entered.current }
        let request = Task { try await rig.host.server.projectExecution(.execute(assignment)) }
        try await eventually("pending execution save") { try await rig.host.server.enqueue { rig.host.server.executionPending.contains(assignment.key) } }
        rig.host.stop(keepFiles: true)
        gate.signal()
        await #expect(throws: (any Error).self) { try await request.value }
        let restarted = try ScratchServer(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.server.state.projectExecutions.isEmpty)
        #expect(rig.launches.current == 0)
        #expect(await restarted.server.listSessions().isEmpty)
    }

    @Test func invalidInputAndCapacityRefuseBeforeAgentCreationAndCapabilityRequiresAdapter() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        let plain = try await remote.typed(); defer { plain.disconnect() }
        #expect(!plain.capabilities.contains(RemoteProtocol.projectExecutionCapability))
        let rig = try Rig(hold: true); defer { rig.stop() }
        rig.host.server.executionCapacity = 1
        let assignment = try await rig.assignment()
        for prompt in [" \n", String(repeating: "x", count: 16_385)] {
            var invalid = assignment; invalid.prompt = prompt
            await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.projectExecution(.execute(invalid)) }
        }
        #expect(rig.host.server.state.projectExecutions.isEmpty && rig.launches.current == 0)
        let hidden = Space(name: "Private", path: rig.owner.dir.path, hidden: true, holdsProjects: true)
        try await rig.host.server.addSpace(hidden)
        var privateAssignment = assignment; privateAssignment.executorSpaceID = hidden.id
        await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.projectExecution(.execute(privateAssignment)) }
        #expect(rig.host.server.state.projectExecutions.isEmpty)
        _ = try await rig.host.server.projectExecution(.cancel(key: assignment.key))
        var second = assignment; second.key.operationID = UUID()
        await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.projectExecution(.execute(second)) }
        #expect(rig.host.server.state.projectExecutions.count == 1)
        #expect(rig.host.server.state.agents.isEmpty)
        let legacy = try await rig.remote.raw(); defer { legacy.closeConnection() }
        try legacy.send(.projectExecution(id: 2, request: .execute(assignment)))
        guard case .error(2, "unsupported", _) = try await legacy.next() else { Issue.record("Legacy client must be refused"); return }
        let unauthenticated = try await rig.remote.raw(authenticated: false); defer { unauthenticated.closeConnection() }
        try unauthenticated.send(.projectExecution(id: 2, request: .execute(assignment)))
        guard case .error = try await unauthenticated.next() else { Issue.record("Authentication required"); return }
        let viewer = RemoteHostClient(); defer { viewer.disconnect() }
        let state = try await viewer.connect(host: "127.0.0.1", port: rig.remote.port, token: rig.remote.token, clientName: "viewer")
        #expect(state.projectExecutions.isEmpty)
    }
}
