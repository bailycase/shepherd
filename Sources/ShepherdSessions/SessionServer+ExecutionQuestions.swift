import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// The native worker and the owner's Project page share the same retained native envelope.
    func queuePausedExecutionAnswer(agentID: AgentID, request: NativeThreadRequest,
                                    completion: @escaping (NativeThreadResult) -> Void) -> Bool {
        guard case .answer(let session, let generation, let operation, let dialog, _) = request,
              let receipt = store.state.projectExecutions.first(where: {
                  $0.assignment?.reservedWorkerID == agentID && $0.phase == .waiting
                    && $0.sessionID == session && $0.generation == generation
              }), !projectScopeWasTakenOver(projectChildScope(receipt)) else { return false }
        guard projectsEnabled else {
            completion(.failure(code: "unsupported", message: Self.projectsDisabledMessage)); return true
        }
        if let pending = receipt.pendingAnswer, [.queued, .delivering, .unknown].contains(pending.phase) {
            completion(pending.operationID == operation ? .accepted(operationID: operation)
                : .failure(code: "question_answer_pending", message: "This native question already has a retained answer."))
            return true
        }
        if receipt.ownerPaused != true, let scope = projectChildScope(receipt), projectChildClosed.contains(scope) {
            completion(.failure(code: "project_paused", message: "Project interruption is pending.")); return true
        }
        guard receipt.ownerPaused == true else { return false }
        guard let thread = rpcThread(forAgent: agentID), thread.piSessionID == session, thread.generation == generation,
              thread.dialogs.contains(where: { $0.id == dialog && $0.unavailable == nil }),
              let data = try? NDJSON.encode(request), data.count <= 32 * 1024 else {
            completion(.failure(code: "dialog_unavailable", message: "The original native question is unavailable.")); return true
        }
        saveExecution(receipt.key, change: { current in
            guard var r = current, r.phase == .waiting, r.questionID == dialog, r.ownerPaused == true else {
                throw LogicalProjectsError("dialog_unavailable", "Refresh the original native question.")
            }
            if let pending = r.pendingAnswer, [.queued, .delivering, .unknown].contains(pending.phase) {
                guard pending.operationID == operation else { throw LogicalProjectsError("question_answer_pending", "Question already answered.") }
            } else {
                r.pendingAnswer = .init(operationID: operation, sessionID: session, generation: generation, dialogID: dialog, request: data)
            }
            return r
        }) { result in
            switch result {
            case .success: completion(.accepted(operationID: operation))
            case .failure: completion(.failure(code: "dialog_unavailable", message: "Question changed before its answer was retained."))
            }
        }
        return true
    }

    func deliverExecutionAnswer(_ receipt: ProjectExecutionReceipt) {
        guard projectsEnabled, receipt.ownerPaused != true, receipt.phase == .waiting, let answer = receipt.pendingAnswer, answer.phase == .queued else { return }
        let generation = projectsGeneration
        saveExecution(receipt.key, revalidate: {
            try self.requireProjectsEnabled()
            guard self.projectsGeneration == generation else { throw LogicalProjectsError("project_paused", "Answer admission was revoked.") }
        }, change: { current in
            guard var r = current, r.ownerPaused != true, r.pendingAnswer?.phase == .queued else {
                throw LogicalProjectsError("dialog_unavailable", "Answer reservation changed.")
            }
            r.pendingAnswer?.phase = .delivering
            return r
        }) { result in
            guard case .success(let current) = result else { return }
            let finish: (NativeThreadResult) -> Void = { result in
                self.saveExecution(receipt.key, change: { current in
                    guard var r = current, r.pendingAnswer?.operationID == answer.operationID else { throw LogicalProjectsError("no_such_execution", "Answer reservation changed.") }
                    if case .accepted = result { r.pendingAnswer?.phase = .delivered }
                    else { r.pendingAnswer?.phase = .failed; r.outcome = "The original native question expired or changed; its retained answer was not sent." }
                    return r
                }) { _ in }
            }
            guard self.projectsEnabled, let worker = current.assignment?.reservedWorkerID, let thread = self.rpcThread(forAgent: worker),
                  current.ownerPaused != true, thread.piSessionID == answer.sessionID, thread.generation == answer.generation,
                  thread.dialogs.contains(where: { $0.id == answer.dialogID && $0.unavailable == nil }),
                  let request = try? NDJSON.decode(NativeThreadRequest.self, from: answer.request) else {
                finish(.failure(code: "dialog_unavailable", message: "Original native question expired or changed.")); return
            }
            thread.handle(request, completion: finish)
        }
    }

    func answerProjectPlacement(_ id: ProjectID, revision: UInt64, task: ProjectTask, request: NativeThreadRequest,
                                admission: (@Sendable (Project) throws -> Void)? = nil) async throws -> NativeThreadResult {
        guard let assignment = task.executionAssignment,
              case .answer(let session, let generation, let operation, let dialog, _) = request,
              session == task.executionReceipt?.sessionID, generation == task.executionReceipt?.generation,
              dialog == task.executionReceipt?.questionID else { throw LogicalProjectsError("dialog_unavailable", "Refresh the original execution question.") }
        if let pending = task.executionReceipt?.pendingAnswer, [.queued, .delivering, .unknown].contains(pending.phase) {
            guard pending.operationID == operation else { throw LogicalProjectsError("question_answer_pending", "The executor already retained an answer to this question.") }
            return .accepted(operationID: operation)
        }
        let data = try NDJSON.encode(request)
        guard data.count <= 32 * 1024 else { throw LogicalProjectsError("invalid", "Answer exceeds native envelope budget.") }
        let project = try await updateRuntimeProject(id, expectedRevision: revision, revalidate: {
            try self.requireProjectsEnabled()
            if let admission { try admission(try self.runtimeProject(id)) }
        }) { p in
            try admission?(p)
            guard let i = p.tasks.firstIndex(where: { $0.id == task.id && $0.operationID == assignment.key.operationID }) else {
                throw LogicalProjectsError("stale_project", "Task changed.")
            }
            if let pending = p.tasks[i].pendingAnswer, [.queued, .delivering, .unknown].contains(pending.phase) {
                guard pending.operationID == operation else { throw LogicalProjectsError("question_answer_pending", "Question already has a retained answer.") }
            } else { p.tasks[i].pendingAnswer = .init(operationID: operation, sessionID: session, generation: generation, dialogID: dialog, request: data) }
        }
        try await enqueue { if !project.paused { self.deliverProjectAnswers(id) } }
        return .accepted(operationID: operation)
    }
}
