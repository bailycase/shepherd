import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project coordination through native tools", .integrationTimeLimit)
struct ProjectCoordinationTests {
    typealias Rig = ProjectRuntimeTests.Rig

    @Test func invalidNativeTextNeverCommitsAReceiptOrReservesAWorker() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        for text in [" \n\t", String(repeating: "😀", count: 6000)] {
            await #expect(throws: ProjectValidationError.self) { try await rig.perform(p.id, .message(operationID: UUID(), text: text)) }
            await #expect(throws: ProjectValidationError.self) { try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Task", prompt: text)) }
        }
        await #expect(throws: ProjectValidationError.self) { try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: " \n", prompt: "valid")) }
        #expect(rig.host.server.state.projects.first == p)
        #expect(rig.agents.current.isEmpty)
    }

    @Test func aFailedHeldLaunchAcknowledgesPauseAndDoesNotStrandResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let pending = Locked<(@Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        rig.host.server.onProjectRuntimeLaunch = { _, done in pending.withValue { $0 = done } }
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Held", prompt: "hello"))
        try await eventually("launch held") { pending.current != nil }
        _ = try await rig.perform(p.id, .pause)
        #expect(rig.host.server.state.projects.first?.interruptPending == true)
        pending.current?(.failure(WireError("launch refused after pause")))
        try await eventually("failed launch acknowledged") { rig.host.server.state.projects.first?.interruptPending == false }
        let resumed = try await rig.perform(p.id, .resume)
        #expect(!resumed.paused && resumed.tasks.first?.phase == .failed)
        #expect(await rig.host.server.listSessions().isEmpty)
    }

    @Test func pauseDuringSecondPromptPreparationRetainsItAndRestartNeverReplaysUnknownDelivery() async throws {
        let rig = try Rig()
        let p = try await rig.create()
        let first = try await rig.perform(p.id, .message(operationID: UUID(), text: "first"))
        let coordinator = try #require(first.coordinatorAgentID)
        try await eventually("first consumed") { rig.host.server.state.projects.first?.messages.first?.phase == .delivered }
        let pi = try #require(rig.agents.current[coordinator])
        _ = try await pi.snapshot("first settled") { !$0.running }
        let preparation = Locked<(() -> Void)?>(nil)
        try await rig.host.server.enqueue { rig.host.server.rpcThread(forAgent: coordinator)?.beforePrompt = { done in preparation.withValue { $0 = done } } }
        let operation = UUID()
        _ = try await rig.perform(p.id, .message(operationID: operation, text: "second"))
        try await eventually("second preparation held") { preparation.current != nil }
        #expect(pi.stdin("prompt").count == 1)
        #expect(rig.host.server.state.projects.first?.messages.last?.phase == .delivering)
        _ = try await rig.perform(p.id, .pause)
        try await eventually("unsent message durably queued and interruption acknowledged") {
            let p = rig.host.server.state.projects.first
            return p?.messages.last?.phase == .queued && p?.interruptPending == false
        }
        #expect(rig.host.server.state.projects.first?.messages.last?.id == operation)
        try await rig.host.server.enqueue {
            rig.host.server.rpcThread(forAgent: coordinator)?.beforePrompt = nil
            preparation.current?()
        }
        _ = try await rig.perform(p.id, .resume)
        try await eventually("second actually consumed once") { pi.stdin("prompt").count == 2 && rig.host.server.state.projects.first?.messages.last?.phase == .delivered }
        _ = try await rig.perform(p.id, .message(operationID: operation, text: "retry cannot replace payload"))
        #expect(pi.stdin("prompt").count == 2)
        _ = try await pi.snapshot("second settled") { !$0.running }
        preparation.withValue { $0 = nil }
        try await rig.host.server.enqueue { rig.host.server.rpcThread(forAgent: coordinator)?.beforePrompt = { done in preparation.withValue { $0 = done } } }
        _ = try await rig.perform(p.id, .message(operationID: UUID(), text: "third outcome unknown"))
        try await eventually("third preparation held") { preparation.current != nil }
        rig.host.server.onProjectRuntimeLaunch = nil; rig.host.stop(keepFiles: true)
        let restarted = try Rig(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.host.server.state.projects.first?.messages.last?.phase == .unknown)
        #expect(restarted.host.server.state.projects.first?.paused == true)
        #expect(await restarted.host.server.listSessions().isEmpty)
    }

    @Test func authenticatedCoordinatorToolsDispatchThreeQueueFourAndWakeFromActualResultsOnce() async throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.host.useRealPeerCheck()
        let p = try await rig.create()
        let commands: [[String: Any]] = (0..<4).map { i in ["assign": ["operationID": UUID().uuidString, "spaceID": "$linked", "title": "Task \(i)", "prompt": "slow"]] }
        let text = "project-tools " + String(decoding: try JSONSerialization.data(withJSONObject: commands), as: UTF8.self)
        let sent = try await rig.perform(p.id, .message(operationID: UUID(), text: text)), coordinator = try #require(sent.coordinatorAgentID)
        try await eventually("model tools reserved three and queued four") {
            let tasks = rig.host.server.state.projects.first?.tasks ?? []
            return tasks.count == 4 && tasks.filter { $0.phase.occupiesSlot }.count == 3 && tasks.last?.phase == .queued
        }
        #expect(rig.host.server.state.agents.filter { $0.coordinatorFor == nil }.count <= 3)
        let first = try #require(rig.host.server.state.projects.first?.tasks.first)
        let worker = try #require(rig.agents.current[first.workerAgentID])
        worker.release(1); worker.release(2)
        try await eventually("native result wakes coordinator") {
            rig.host.server.state.projects.first?.messages.contains { $0.source?.taskID == first.id && $0.source?.kind == .settled && $0.phase == .delivered } == true
        }
        let receipt = try #require(rig.host.server.state.projects.first?.messages.first { $0.source?.taskID == first.id })
        #expect(receipt.text.contains("Hello") && receipt.text.contains("Native content:") && receipt.text.contains(first.workerAgentID.rawValue))
        try await rig.host.server.enqueue { rig.host.server.projectWorkerSettled(agentID: first.workerAgentID) }
        #expect(rig.host.server.state.projects.first?.messages.filter { $0.source?.taskID == first.id && $0.source?.kind == .settled }.count == 1)
        let c = try #require(rig.agents.current[coordinator])
        #expect(c.stdin("prompt").contains { ($0["message"] as? String)?.contains("Worker event") == true })
    }

    @Test func nativeQuestionAndSettledReceiptsReachTheCoordinatorAndTypedFollowupReusesItsWorker() async throws {
        let rig = try Rig(); defer { rig.stop() }
        rig.host.useRealPeerCheck()
        let p = try await rig.create()
        func tool(_ action: [String: Any]) async throws {
            let text = "project-tools " + String(decoding: try JSONSerialization.data(withJSONObject: [action]), as: UTF8.self)
            _ = try await rig.perform(p.id, .message(operationID: UUID(), text: text))
        }
        try await tool(["assign": ["operationID": UUID().uuidString, "spaceID": "$linked", "title": "Question", "prompt": "ask"]])
        try await eventually("native question card and wake") {
            rig.host.server.state.projects.first?.messages.contains { $0.source?.kind == .question && $0.phase == .delivered } == true
        }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first)
        let worker = try #require(rig.agents.current[task.workerAgentID])
        let asked = try await worker.snapshot("native question remains open") { !$0.dialogs.isEmpty }
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        let revision = try #require(rig.host.server.state.projects.first?.revision)
        #expect(try await rig.host.server.answerProjectQuestion(p.id, expectedRevision: revision, taskID: task.id, request: answer).failureCode == nil)
        #expect(try await worker.request(answer).failureCode == nil, "Native retry replays its receipt, not the answer")
        _ = try await worker.waitForStdin("extension_ui_response")
        #expect(worker.stdin("extension_ui_response").count == 1)
        try await eventually("settled answer wake") { rig.host.server.state.projects.first?.messages.contains { $0.source?.kind == .settled && $0.phase == .delivered } == true }
        try await tool(["followUp": ["taskID": task.id.rawValue, "operationID": UUID().uuidString, "text": "follow-up"]])
        try await eventually("follow-up reused native worker") { worker.stdin("prompt").count == 2 && rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        #expect(rig.agents.current.count == 2)
        try await tool(["remember": ["operationID": UUID().uuidString, "taskID": task.id.rawValue, "text": "Factual note from inspected task"]])
        try await eventually("inspectable factual memory") { rig.host.server.state.projects.first?.memory.count == 1 }
        #expect(rig.host.server.state.projects.first?.memory.first?.source.contains(task.workerAgentID.rawValue) == true)
    }

    @Test func pauseKeepsTheNativeQuestionAndBothAnswerViewsWaitForExplicitResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("question persisted") { rig.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first)
        let worker = try #require(rig.agents.current[task.workerAgentID])
        let asked = try await worker.snapshot("original dialog") { !$0.dialogs.isEmpty }
        _ = try await rig.perform(p.id, .pause)
        try await eventually("question is a safe pause point") { rig.host.server.state.projects.first?.interruptPending == false }
        #expect(worker.stdin("abort").isEmpty)
        #expect(rig.host.server.state.projects.first?.tasks.first?.phase == .waiting)
        let paused = try await worker.snapshot("question survives pause") { !$0.dialogs.isEmpty }
        #expect(paused.dialogs.first?.id == asked.dialogs.first?.id && paused.running)
        let operation = UUID()
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: operation, dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await worker.request(answer).failureCode == nil, "Ordinary answer view uses the same durable pause gate")
        #expect(rig.host.server.state.projects.first?.tasks.first?.pendingAnswer?.phase == .queued)
        let revision = try #require(rig.host.server.state.projects.first?.revision)
        #expect(try await rig.host.server.answerProjectQuestion(p.id, expectedRevision: revision, taskID: task.id, request: answer).failureCode == nil)
        #expect(worker.stdin("extension_ui_response").isEmpty)
        _ = try await rig.perform(p.id, .resume)
        try await eventually("one retained native answer and settlement") { worker.stdin("extension_ui_response").count == 1 && rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        #expect(try await worker.request(answer).failureCode == nil)
        #expect(worker.stdin("extension_ui_response").count == 1)
    }

    @Test func aQueuedPausedAnswerBecomesUnknownOnRestartAndNeverAutoResumes() async throws {
        let rig = try Rig()
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("question persisted") { rig.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first), worker = try #require(rig.agents.current[task.workerAgentID])
        let asked = try await worker.snapshot("dialog") { !$0.dialogs.isEmpty }
        _ = try await rig.perform(p.id, .pause)
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await worker.request(answer).failureCode == nil)
        #expect(worker.stdin("extension_ui_response").isEmpty)
        rig.host.server.onProjectRuntimeLaunch = nil; rig.host.stop(keepFiles: true)
        let restarted = try Rig(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.host.server.state.projects.first?.tasks.first?.pendingAnswer?.phase == .unknown)
        #expect(restarted.host.server.state.projects.first?.paused == true)
        #expect(await restarted.host.server.listSessions().isEmpty)
    }

    @Test func aStaleQueuedAnswerIsRefusedRatherThanCreatingAReplacementDialog() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Question", prompt: "ask"))
        try await eventually("question persisted") { rig.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(rig.host.server.state.projects.first?.tasks.first), worker = try #require(rig.agents.current[task.workerAgentID])
        let asked = try await worker.snapshot("original question") { !$0.dialogs.isEmpty }
        _ = try await rig.perform(p.id, .pause)
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        #expect(try await worker.request(answer).failureCode == nil)
        // An explicit ordinary-thread Stop closes the actual native dialog. It must not turn
        // the Project's retained confirmation into an answer to some later question.
        #expect(try await worker.request(.abort(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID())).failureCode == nil)
        try await eventually("question close reconciled") { rig.host.server.state.projects.first?.interruptPending == false }
        _ = try await rig.perform(p.id, .resume)
        try await eventually("stale native answer rejected") { rig.host.server.state.projects.first?.tasks.first?.pendingAnswer?.phase == .failed }
        #expect(!worker.stdin("extension_ui_response").contains { $0["confirmed"] as? Bool == true })
    }

    @Test func coordinatorRetryAndCompactionCannotBypassAdmissionAndOrdinaryWorkerSteerStillWorks() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        let sent = try await rig.perform(p.id, .message(operationID: UUID(), text: "hello")), id = try #require(sent.coordinatorAgentID)
        try await eventually("coordinator ready") { rig.agents.current[id] != nil }
        let coordinator = try #require(rig.agents.current[id])
        let snapshot = try await coordinator.snapshot("coordinator settled") { !$0.running && !$0.messages.isEmpty }
        for request in [NativeThreadRequest.retry(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), entryID: "irrelevant"),
                        .compact(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID()),
                        .send(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: "bypass", delivery: .steer)] {
            await #expect(throws: RemoteHostClientError.self) { try await coordinator.request(request) }
        }
        _ = try await rig.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "slow"))
        try await eventually("worker launched") { rig.agents.current.count == 2 }
        let worker = try #require(rig.agents.current.values.first { $0.agent.id != id })
        let working = try await worker.snapshot("worker active") { $0.running }
        #expect(try await worker.send("manual steer", delivery: .steer, from: working).failureCode == nil)
        let steer = try await worker.waitForStdin("prompt", count: 2)
        #expect(steer["streamingBehavior"] as? String == "steer")
        await #expect(throws: RemoteHostClientError.self) {
            try await worker.request(.subagentCommand(expectedSessionID: working.piSessionID, generation: working.generation, operationID: UUID(), runID: "unadmitted", action: .resume))
        }
        _ = try await rig.perform(p.id, .pause)
    }

    @Test func missingOwnerRuntimeCapabilityRefusesBeforeAnyExecution() async throws {
        let host = try RemoteHost(); defer { host.stop() }
        let client = try await host.typed(); defer { client.disconnect() }
        #expect(!client.capabilities.contains(RemoteProtocol.logicalProjectRuntimeCapability))
        await #expect(throws: RemoteHostClientError.self) { try await client.projectRuntime(.action(projectID: ProjectID(), expectedRevision: 1, request: .resume)) }
        let raw = try await host.raw(); defer { raw.closeConnection() }
        try raw.send(.logicalProjectRuntime(id: 80, request: .hosts))
        guard case .error(80, "unsupported", _) = try await raw.next() else { Issue.record("Expected capability refusal"); return }
        #expect(await host.server.listSessions().isEmpty)
    }

    @Test func proposalsAreExplicitConsumedApprovalsWithProjectProvenanceAndOwnerHostValidation() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let directory = rig.host.dir.appendingPathComponent("approved-space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let proposal = UUID()
        _ = try await rig.perform(p.id, .proposeSpace(operationID: proposal, path: directory.path, spaceID: nil, originTaskID: nil))
        #expect(rig.host.server.state.spaces.count == 1)
        _ = try await rig.perform(p.id, .decideSpace(proposalID: proposal, expectedProposalRevision: 1, accept: true))
        let current = try #require(rig.host.server.state.projects.first)
        #expect(current.spaceProposals.first?.phase == .accepted)
        #expect(current.linkedSpaces.last?.provenance == .project)
        let denied = UUID()
        _ = try await rig.perform(p.id, .proposeSpace(operationID: denied, path: "/does/not/exist", spaceID: nil, originTaskID: nil))
        _ = try await rig.perform(p.id, .decideSpace(proposalID: denied, expectedProposalRevision: 1, accept: false))
        _ = try await rig.perform(p.id, .decideSpace(proposalID: denied, expectedProposalRevision: 1, accept: true))
        #expect(rig.host.server.state.projects.first?.spaceProposals.last?.phase == .denied)
        let latest = try #require(rig.host.server.state.projects.first)
        var settings = latest.settings
        settings.allowedHosts = [.remote(hostID: UUID(), bindingID: UUID())]
        await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.logicalProjects(.settings(projectID: p.id, expectedRevision: latest.revision, settings: settings)) }
        settings = latest.settings; settings.canRequestSpaceLinks = false
        _ = try await rig.host.server.logicalProjects(.settings(projectID: p.id, expectedRevision: latest.revision, settings: settings))
        await #expect(throws: LogicalProjectsError.self) { try await rig.perform(p.id, .proposeSpace(operationID: UUID(), path: directory.path, spaceID: nil, originTaskID: nil)) }
        #expect(rig.host.server.state.projects.first?.spaceProposals.count == 2)
    }
}
