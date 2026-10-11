import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project chat answer provenance", .integrationTimeLimit)
struct ProjectChatAnswerTests {
    typealias Rig = ProjectRuntimeTests.Rig

    private func workerScript(_ r: Rig) throws {
        try JSONSerialization.data(withJSONObject: ["prompts": ["Choose": [["ask": ["title": "Permit change?", "options": ["Allow", "Deny"]]]]]])
            .write(to: r.host.dir.appendingPathComponent("project-script.json"))
    }

    @Test func onlyTheCurrentConsumedHumanReplyAfterTheOriginalQuestionCanRelayAnAnswer() async throws {
        let r = try Rig(); defer { r.stop() }
        let p = try await r.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        let dir = r.host.dir.appendingPathComponent("logical-projects/\(p.id)")
        try JSONSerialization.data(withJSONObject: ["prompts": [
            "Before question": [["wait": "before-done"]],
            "Please allow that change password=private-human-token": [["wait": "reply-done"]]
        ]]).write(to: dir.appendingPathComponent("project-script.json"))
        try workerScript(r)
        let before = UUID()
        let sent = try await r.perform(p.id, .message(operationID: before, text: "Before question"))
        let coordinator = try #require(sent.coordinatorAgentID)
        _ = try await r.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "Choose"))
        try await eventually("worker question and pre-question human consumed") {
            let current = r.host.server.state.projects.first
            return current?.tasks.first?.phase == .waiting && current?.messages.first?.phase == .delivered
                && current?.messages.contains { $0.source?.kind == .question } == true
        }
        let task = try #require(r.host.server.state.projects.first?.tasks.first)
        let event = try #require(r.host.server.state.projects.first?.messages.first { $0.source?.kind == .question })
        func relay(_ human: UUID, eventID: UUID? = nil, taskID: ProjectTaskID? = nil,
                   actor: AgentID? = nil, projectID: ProjectID? = nil, revision: UInt64? = nil,
                   operation: UUID = UUID(), answer: NativeDialogAnswer = .select(value: "Allow")) async throws -> Project {
            try await r.host.server.projectTool(agentID: actor ?? coordinator, projectID: projectID ?? p.id,
                expectedRevision: revision ?? r.host.server.state.projects.first!.revision,
                request: .answer(operationID: operation, taskID: taskID ?? task.id,
                                 questionEventID: eventID ?? event.id, humanReplyID: human, answer: answer))
        }
        await #expect(throws: LogicalProjectsError.self) { try await relay(before) }
        try Data().write(to: dir.appendingPathComponent("before-done"))
        try await eventually("question event delivered") {
            r.host.server.state.projects.first?.messages.first { $0.id == event.id }?.phase == .delivered
        }
        let human = UUID(), text = "Please allow that change password=private-human-token"
        _ = try await r.perform(p.id, .message(operationID: human, text: text))
        try await eventually("actual human answer consumed") {
            r.host.server.state.projects.first?.messages.first { $0.id == human }?.phase == .delivered
        }
        let other = try await r.create()
        // Wrong author, cross-Project, fabricated identities, event-as-human, old turn, stale revision,
        // and wrong native answer kind/value all fail before touching the worker.
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, actor: task.workerAgentID) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, actor: AgentID()) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, projectID: other.id) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, taskID: ProjectTaskID()) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, eventID: UUID()) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(event.id) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(before) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, revision: 0) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, answer: .select(value: "allow")) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, answer: .confirm(value: true)) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, answer: .cancel) }
        await #expect(throws: LogicalProjectsError.self) {
            try await r.perform(p.id, .answer(operationID: UUID(), taskID: task.id, questionEventID: event.id, humanReplyID: human, answer: .select(value: "Allow")))
        }
        // Unknown old source-nil state is not a human signature, even in a consumed turn.
        _ = try await r.host.server.updateRuntimeProject(p.id) { project in
            let i = project.messages.firstIndex { $0.id == human }!
            project.messages[i].humanSubmitted = nil
        }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human) }
        _ = try await r.host.server.updateRuntimeProject(p.id) { project in
            let i = project.messages.firstIndex { $0.id == human }!
            project.messages[i].humanSubmitted = true
            let e = project.messages.firstIndex { $0.id == event.id }!
            project.messages[e].source?.generation = "stale-generation"
        }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human) }
        _ = try await r.host.server.updateRuntimeProject(p.id) { project in
            let e = project.messages.firstIndex { $0.id == event.id }!
            project.messages[e].source = event.source
            project.messages[e].source?.workerAgentID = coordinator
        }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human) }
        _ = try await r.host.server.updateRuntimeProject(p.id) { project in
            project.messages[project.messages.firstIndex { $0.id == event.id }!].source = event.source
        }
        // Real human Space approval produces a source-nil *synthetic* message, never human proof.
        let proposal = UUID()
        _ = try await r.perform(p.id, .proposeSpace(operationID: proposal, path: "/not-approved", spaceID: nil, originTaskID: task.id))
        _ = try await r.perform(p.id, .decideSpace(proposalID: proposal, expectedProposalRevision: 1, accept: false))
        let synthetic = try #require(r.host.server.state.projects.first?.messages.first { $0.id == proposal })
        #expect(synthetic.source == nil && synthetic.humanSubmitted == nil)
        await #expect(throws: LogicalProjectsError.self) { try await relay(proposal) }
        for request in [ProjectRuntimeRequest.read, .inspect(taskID: task.id)] {
            let read = try await r.host.server.projectTool(agentID: coordinator, projectID: p.id, expectedRevision: 0, request: request)
            #expect(read.messages.filter { $0.humanSubmitted == true }.map(\.id) == [human])
            #expect(!read.messages.contains { $0.id == before || $0.id == proposal })
            #expect(!String(decoding: try JSONEncoder().encode(read), as: UTF8.self).contains("private-human-token"))
        }
        let worker = try #require(r.agents.current[task.workerAgentID])
        #expect(worker.stdin("extension_ui_response").isEmpty)
        let operation = UUID()
        try await eventually("answer admitted despite unrelated native revisions") {
            do { _ = try await relay(human, operation: operation); return true }
            catch let error as LogicalProjectsError where ["stale_project", "project_busy", "workspace_changed"].contains(error.code) { return false }
        }
        #expect(r.host.server.state.projects.first?.messages.first { $0.id == human }?.answerReceipts?.first?.nativeAnswer.operationID == operation)
        _ = try await relay(human, revision: 0, operation: operation)
        await #expect(throws: LogicalProjectsError.self) { try await relay(human, operation: operation, answer: .select(value: "Deny")) }
        await #expect(throws: LogicalProjectsError.self) { try await relay(human) }
        #expect(worker.stdin("extension_ui_response").count == 1)
        #expect(r.host.server.state.projects.first?.messages.first { $0.id == human }?.text == text)
        let safe = try await r.host.server.projectTool(agentID: coordinator, projectID: p.id, expectedRevision: 0, request: .read)
        #expect(safe.messages.first { $0.id == human }?.answerReceipts == nil)
        try Data().write(to: dir.appendingPathComponent("reply-done"))
    }

    @Test(arguments: [false, true])
    func aDefinitelyUnsentAnswerDoesNotBlockAFreshToolCallOrLaterHumanReply(laterHuman: Bool) async throws {
        let r = try Rig(); defer { r.stop() }
        let p = try await r.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        let dir = r.host.dir.appendingPathComponent("logical-projects/\(p.id)")
        try JSONSerialization.data(withJSONObject: ["prompts": ["hello": [],
            "Allow it please": [["wait": "reply-done"]], "Yes, allow it": [["wait": "later-done"]]]])
            .write(to: dir.appendingPathComponent("project-script.json"))
        try workerScript(r)
        let sent = try await r.perform(p.id, .message(operationID: UUID(), text: "hello"))
        let coordinator = try #require(sent.coordinatorAgentID)
        _ = try await r.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: "Choose"))
        try await eventually("question consumed before human reply") {
            r.host.server.state.projects.first?.messages.contains { $0.source?.kind == .question && $0.phase == .delivered } == true
        }
        let task = try #require(r.host.server.state.projects.first?.tasks.first)
        let event = try #require(r.host.server.state.projects.first?.messages.first { $0.source?.kind == .question })
        let human = UUID(), originalOperation = UUID()
        _ = try await r.perform(p.id, .message(operationID: human, text: "Allow it please"))
        try await eventually("human reply consumed") {
            r.host.server.state.projects.first?.messages.first { $0.id == human }?.phase == .delivered
        }
        let worker = try #require(r.agents.current[task.workerAgentID])
        let snapshot = try await worker.snapshot("original native question") { !$0.dialogs.isEmpty }
        let native = NativeThreadRequest.answer(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
            operationID: originalOperation, dialogID: try #require(event.source?.dialogID), answer: .select(value: "Allow"))
        let receipt = ProjectChatAnswerReceipt(taskID: task.id, questionEventID: event.id,
            nativeAnswer: .init(operationID: originalOperation, sessionID: snapshot.piSessionID, generation: snapshot.generation,
                dialogID: try #require(event.source?.dialogID), request: try NDJSON.encode(native), phase: .delivering))
        // Enter the production post-admission boundary explicitly: no scheduler race or test hook.
        let admitted = try await r.host.server.updateRuntimeProject(p.id) { project in
            project.messages[project.messages.firstIndex { $0.id == human }!].answerReceipts = [receipt]
        }
        let epoch = try await r.host.server.enqueue { r.host.server.logicalProjectEpoch }
        _ = try await r.host.server.updateRuntimeProject(p.id) { $0.goal = "An intervening human edit" }
        do {
            _ = try await r.host.server.dispatchProjectChatAnswer(admitted, epoch: epoch, coordinator: coordinator,
                operation: originalOperation, taskID: task.id, eventID: event.id, replyID: human, answer: .select(value: "Allow"))
            Issue.record("Stale admitted revision reached native dispatch")
        } catch let error as LogicalProjectsError { #expect(error.code == "stale_project") }
        #expect(worker.stdin("extension_ui_response").isEmpty)
        let failed = try #require(r.host.server.state.projects.first?.messages.first { $0.id == human }?.answerReceipts?.first)
        #expect(failed.nativeAnswer.phase == .failed && failed.nativeAnswer.request == receipt.nativeAnswer.request)
        #expect(r.host.server.state.projects.first?.tasks.first?.phase == .waiting)

        func relay(_ reply: UUID, operation: UUID = UUID(), answer: NativeDialogAnswer = .select(value: "Allow")) async throws -> Project {
            try await r.host.server.projectTool(agentID: coordinator, projectID: p.id,
                expectedRevision: r.host.server.state.projects.first!.revision,
                request: .answer(operationID: operation, taskID: task.id, questionEventID: event.id, humanReplyID: reply, answer: answer))
        }
        // A fresh call cannot change the original operation's bound payload.
        do {
            _ = try await relay(human, operation: originalOperation, answer: .select(value: "Deny"))
            Issue.record("Failed answer identity changed payload")
        } catch let error as LogicalProjectsError { #expect(error.code == "answer_conflict") }
        // Only a definitely-unsent terminal reservation is replaceable. Unknown/accepted stays closed.
        for phase in [ProjectQuestionAnswer.Phase.delivering, .unknown, .delivered] {
            _ = try await r.host.server.updateRuntimeProject(p.id) { project in
                project.messages[project.messages.firstIndex { $0.id == human }!].answerReceipts?[0].nativeAnswer.phase = phase
            }
            await #expect(throws: LogicalProjectsError.self) { try await relay(human) }
        }
        _ = try await r.host.server.updateRuntimeProject(p.id) { project in
            project.messages[project.messages.firstIndex { $0.id == human }!].answerReceipts?[0].nativeAnswer.phase = failed.nativeAnswer.phase
        }
        let reply: UUID
        if laterHuman {
            try Data().write(to: dir.appendingPathComponent("reply-done"))
            try await eventually("original human turn finished") {
                try await r.host.server.enqueue { r.host.server.projectPromptInFlight[coordinator] == nil }
            }
            reply = UUID()
            _ = try await r.perform(p.id, .message(operationID: reply, text: "Yes, allow it"))
            try await eventually("later human reply consumed") {
                r.host.server.state.projects.first?.messages.first { $0.id == reply }?.phase == .delivered
            }
        } else { reply = human }
        let freshOperation = UUID()
        _ = try await relay(reply, operation: freshOperation)
        _ = try await relay(reply, operation: freshOperation)
        await #expect(throws: LogicalProjectsError.self) { try await relay(reply, operation: freshOperation, answer: .select(value: "Deny")) }
        try await eventually("fresh operation answered the original question once") {
            worker.stdin("extension_ui_response").count == 1 && r.host.server.state.projects.first?.tasks.first?.phase == .settled
        }
        let receipts = r.host.server.state.projects.first!.messages.flatMap { $0.answerReceipts ?? [] }
        #expect(receipts.count == 2)
        #expect(receipts.first { $0.nativeAnswer.operationID == originalOperation }?.nativeAnswer.phase == .failed)
        #expect(receipts.first { $0.nativeAnswer.operationID == freshOperation }?.nativeAnswer.phase == .delivered)
        try Data().write(to: dir.appendingPathComponent(laterHuman ? "later-done" : "reply-done"))
    }

    @Test(arguments: [false, true])
    func aButtonAnsweredOrExpiredQuestionCannotBorrowAChatReplyForTheNextDialog(expired: Bool) async throws {
        let r = try Rig(); defer { r.stop() }
        let p = try await r.create(), space = try #require(p.linkedSpaces.first?.spaceID)
        let dir = r.host.dir.appendingPathComponent("logical-projects/\(p.id)")
        try JSONSerialization.data(withJSONObject: ["prompts": ["hello": [], "Allow it please": [["wait": "reply-done"]]]])
            .write(to: dir.appendingPathComponent("project-script.json"))
        try workerScript(r)
        let sent = try await r.perform(p.id, .message(operationID: UUID(), text: "hello"))
        let coordinator = try #require(sent.coordinatorAgentID)
        _ = try await r.perform(p.id, .assign(operationID: UUID(), spaceID: space, title: "Worker", prompt: expired ? "question-timeout" : "Choose"))
        try await eventually("question published") { r.host.server.state.projects.first?.messages.contains { $0.source?.kind == .question && $0.phase == .delivered } == true }
        let task = try #require(r.host.server.state.projects.first?.tasks.first)
        let event = try #require(r.host.server.state.projects.first?.messages.first { $0.source?.kind == .question })
        let human = UUID()
        _ = try await r.perform(p.id, .message(operationID: human, text: "Allow it please"))
        try await eventually("human reply consumed") { r.host.server.state.projects.first?.messages.first { $0.id == human }?.phase == .delivered }
        let worker = try #require(r.agents.current[task.workerAgentID])
        if !expired {
            let snapshot = try await worker.snapshot("original native select") { !$0.dialogs.isEmpty }
            _ = try await r.host.server.nativeThread(agentID: task.workerAgentID,
                request: .answer(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                 operationID: UUID(), dialogID: try #require(event.source?.dialogID), answer: .select(value: "Deny")))
        }
        try await eventually("button or timeout settles original question") { r.host.server.state.projects.first?.tasks.first?.phase == .settled }
        if expired {
            let ended = try await worker.snapshot("expired native question record") { ($0.messages + $0.provisional).contains { $0.question?.outcome == .expired } }
            #expect(ended.dialogs.isEmpty)
        }
        _ = try await r.perform(p.id, .followUp(taskID: task.id, operationID: UUID(), text: "Choose"))
        try await eventually("new activation has its own question") { r.host.server.state.projects.first?.tasks.first?.phase == .waiting }
        await #expect(throws: LogicalProjectsError.self) {
            try await r.host.server.projectTool(agentID: coordinator, projectID: p.id,
                expectedRevision: r.host.server.state.projects.first!.revision,
                request: .answer(operationID: UUID(), taskID: task.id, questionEventID: event.id, humanReplyID: human, answer: .select(value: "Allow")))
        }
        #expect(worker.stdin("extension_ui_response").count == (expired ? 0 : 1))
        #expect(r.host.server.state.projects.first?.messages.first { $0.id == human }?.text == "Allow it please")
        #expect(r.host.server.state.projects.first?.tasks.first?.phase == .waiting)
        try Data().write(to: dir.appendingPathComponent("reply-done"))
    }
}
