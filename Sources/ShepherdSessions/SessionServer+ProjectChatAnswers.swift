import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Native consumption and the current coordinator turn, not source-nil prose, prove authorship.
    func projectHumanReply(_ p: Project, coordinator: AgentID) -> ProjectMessage? {
        guard projectsEnabled, !p.paused, p.coordinatorAgentID == coordinator, projectRunStarts[p.id] != nil,
              store.state.agents.contains(where: { $0.id == coordinator && $0.coordinatorFor == p.id }),
              projectStartedPrompts.contains(coordinator), let operation = projectPromptInFlight[coordinator] else { return nil }
        return p.messages.first { $0.id == operation && $0.humanSubmitted == true && $0.source == nil && $0.phase == .delivered }
    }

    /// All question identities come from the owner event and the current native producer.
    private func projectChatQuestion(_ p: Project, taskID: ProjectTaskID, eventID: UUID,
                                     replyID: UUID, coordinator: AgentID, answer: NativeDialogAnswer,
                                     operation: UUID) throws -> NativeThreadRequest {
        guard projectHumanReply(p, coordinator: coordinator)?.id == replyID,
              let replyIndex = p.messages.firstIndex(where: { $0.id == replyID }),
              let eventIndex = p.messages.firstIndex(where: { $0.id == eventID }), eventIndex < replyIndex,
              let source = p.messages[eventIndex].source, source.kind == .question, source.taskID == taskID,
              let session = source.sessionID, let generation = source.generation, let dialogID = source.dialogID,
              let task = p.tasks.first(where: { $0.id == taskID && $0.phase == .waiting }),
              task.workerAgentID == source.workerAgentID, task.operationID == source.operationID else {
            throw LogicalProjectsError("question_proof", "Answer requires this turn's consumed human reply after the original worker question.")
        }
        let kind: String, options: [String]
        if let assignment = task.executionAssignment, let receipt = task.executionReceipt {
            guard receipt.key == assignment.key, receipt.phase == .waiting, receipt.sessionID == session,
                  receipt.generation == generation, receipt.questionID == dialogID,
                  ![receipt.pendingAnswer, task.pendingAnswer].compactMap({ $0 }).contains(where: {
                      $0.dialogID == dialogID || [.queued, .delivering, .unknown].contains($0.phase)
                  }) else {
                throw LogicalProjectsError("dialog_unavailable", "The original execution question changed or already has an answer.")
            }
            kind = receipt.questionKind ?? ""; options = receipt.questionOptions ?? []
        } else {
            guard task.workerSessionID == session, projectPromptInFlight[task.workerAgentID] == task.operationID,
                  let thread = rpcThread(forAgent: task.workerAgentID), thread.piSessionID == session,
                  thread.generation == generation,
                  !projectScopeWasTakenOver(projectChildScope(p, task: task, thread: thread)),
                  let dialog = thread.dialogs.first(where: { $0.id == dialogID && $0.unavailable == nil }),
                  task.pendingAnswer.map({ $0.dialogID != dialogID && [.delivered, .failed].contains($0.phase) }) ?? true else {
                throw LogicalProjectsError("dialog_unavailable", "The original native question expired or already has an answer.")
            }
            kind = dialog.kind.rawValue; options = dialog.options ?? []
        }
        let valid: Bool
        switch answer {
        case .select(let value): valid = kind == "select" && options.contains(value)
        case .confirm: valid = kind == "confirm"
        case .input: valid = kind == "input"
        case .editor: valid = kind == "editor"
        case .cancel: valid = false
        }
        guard valid else { throw LogicalProjectsError("invalid_answer", "Use the exact native option or the question's typed confirm/input/editor answer.") }
        let request = NativeThreadRequest.answer(expectedSessionID: session, generation: generation, operationID: operation, dialogID: dialogID, answer: answer)
        guard try NDJSON.encode(request).count <= 32 * 1024 else { throw LogicalProjectsError("invalid_answer", "Native answer exceeds 32 KiB.") }
        return request
    }

    func relayProjectAnswer(_ id: ProjectID, revision: UInt64, coordinator: AgentID, operation: UUID,
                            taskID: ProjectTaskID, eventID: UUID, replyID: UUID, answer: NativeDialogAnswer) async throws -> Project {
        let (current, epoch, existing) = try await enqueue {
            let p = try self.runtimeProject(id)
            guard self.projectHumanReply(p, coordinator: coordinator)?.id == replyID else {
                throw LogicalProjectsError("question_proof", "Only the active turn's consumed human reply can authorize an answer.")
            }
            let prior = p.messages.flatMap { message in (message.answerReceipts ?? []).map { (message.id, $0) } }
                .first { $0.1.nativeAnswer.operationID == operation }
            if let (human, receipt) = prior {
                guard human == replyID, receipt.taskID == taskID, receipt.questionEventID == eventID,
                      case .answer(_, _, _, _, let stored) = try NDJSON.decode(NativeThreadRequest.self, from: receipt.nativeAnswer.request), stored == answer else {
                    throw LogicalProjectsError("answer_conflict", "An answer operation cannot change its human source, question or payload.")
                }
            }
            return (p, self.logicalProjectEpoch, prior?.1)
        }
        if let existing, existing.nativeAnswer.phase != .queued {
            guard existing.nativeAnswer.phase != .failed else { throw LogicalProjectsError("dialog_unavailable", "The native answer was refused; inspect the original question.") }
            guard existing.nativeAnswer.phase == .delivered else {
                throw LogicalProjectsError("answer_outcome_unknown", "Answer dispatch is in flight or uncertain. Inspect the original worker; do not send a new answer.")
            }
            return current
        }
        let admitted = try await updateRuntimeProject(id, expectedRevision: revision, expectedEpoch: epoch) { p in
            let request = try self.projectChatQuestion(p, taskID: taskID, eventID: eventID, replyID: replyID,
                                                       coordinator: coordinator, answer: answer, operation: operation)
            guard let i = p.messages.firstIndex(where: { $0.id == replyID }),
                  !p.messages.contains(where: { message in
                      (message.answerReceipts ?? []).contains { $0.questionEventID == eventID && $0.nativeAnswer.operationID != operation && $0.nativeAnswer.phase != .failed }
                  }) else { throw LogicalProjectsError("question_answer_pending", "This question already has a chat answer receipt.") }
            guard case .answer(let session, let generation, _, let dialog, _) = request else { return }
            let receipt = ProjectChatAnswerReceipt(taskID: taskID, questionEventID: eventID,
                nativeAnswer: .init(operationID: operation, sessionID: session, generation: generation,
                                    dialogID: dialog, request: try NDJSON.encode(request), phase: .delivering))
            if let j = p.messages[i].answerReceipts?.firstIndex(where: { $0.nativeAnswer.operationID == operation }) {
                guard p.messages[i].answerReceipts?[j].nativeAnswer.phase == .queued else {
                    throw LogicalProjectsError("question_answer_pending", "Answer dispatch is already in flight.")
                }
                p.messages[i].answerReceipts?[j] = receipt
            } else { p.messages[i].answerReceipts = (p.messages[i].answerReceipts ?? []) + [receipt] }
        }
        return try await dispatchProjectChatAnswer(admitted, epoch: epoch, coordinator: coordinator, operation: operation,
                                                  taskID: taskID, eventID: eventID, replyID: replyID, answer: answer)
    }

    /// The persisted admission is a revision fence, not evidence of native delivery.
    func dispatchProjectChatAnswer(_ admitted: Project, epoch: UInt64, coordinator: AgentID, operation: UUID,
                                   taskID: ProjectTaskID, eventID: UUID, replyID: UUID, answer: NativeDialogAnswer) async throws -> Project {
        let id = admitted.id
        guard let receipt = admitted.messages.first(where: { $0.id == replyID })?.answerReceipts?.first(where: { $0.nativeAnswer.operationID == operation }) else {
            throw LogicalProjectsError("answer_outcome_unknown", "Answer receipt is unavailable; no new answer was dispatched.")
        }
        let request = try NDJSON.decode(NativeThreadRequest.self, from: receipt.nativeAnswer.request)
        let result: NativeThreadResult
        do {
            result = try await answerProjectQuestion(id, expectedRevision: admitted.revision, taskID: taskID, request: request, admission: { p in
                _ = try self.projectChatQuestion(p, taskID: taskID, eventID: eventID, replyID: replyID,
                                                coordinator: coordinator, answer: answer, operation: operation)
            })
        } catch {
            // A definite refusal before native dispatch retires this reservation. Keep its exact
            // payload/identity, but allow a fresh tool call (or later human reply) to try again.
            // A stopped/restarted owner cannot commit this transition under the original epoch.
            _ = try await finishProjectChatAnswer(id, epoch: epoch, replyID: replyID, operation: operation, phase: .failed)
            throw error
        }
        let accepted: Bool
        if case .accepted = result { accepted = true } else { accepted = false }
        let finished = try await finishProjectChatAnswer(id, epoch: epoch, replyID: replyID, operation: operation, phase: accepted ? .delivered : .failed)
        if case .failure(let code, let message) = result { throw LogicalProjectsError(code, message) }
        return finished
    }

    private func finishProjectChatAnswer(_ id: ProjectID, epoch: UInt64, replyID: UUID, operation: UUID,
                                         phase: ProjectQuestionAnswer.Phase) async throws -> Project {
        try await updateRuntimeProject(id, expectedEpoch: epoch) { p in
            guard let i = p.messages.firstIndex(where: { $0.id == replyID }),
                  let j = p.messages[i].answerReceipts?.firstIndex(where: { $0.nativeAnswer.operationID == operation }) else { return }
            p.messages[i].answerReceipts?[j].nativeAnswer.phase = phase
        }
    }
}
