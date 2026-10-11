import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Both Project and ordinary native answer controls enter here on the owner queue. A paused
    /// answer is a durable intention, never an extension_ui_response that would resume pi.
    func queuePausedProjectAnswer(agentID: AgentID, request: NativeThreadRequest,
                                  completion: @escaping (NativeThreadResult) -> Void) -> Bool {
        guard case .answer(let session, let generation, let operation, let dialog, _) = request,
              let project = store.state.projects.first(where: { $0.tasks.contains { $0.workerAgentID == agentID && $0.phase.occupiesSlot } }),
              let task = project.tasks.first(where: { $0.workerAgentID == agentID }),
              task.workerSessionID == session, projectPromptInFlight[agentID] == task.operationID,
              let liveThread = rpcThread(forAgent: agentID),
              !projectScopeWasTakenOver(projectChildScope(project, task: task, thread: liveThread)) else { return false }
        guard projectsEnabled else {
            completion(.failure(code: "unsupported", message: Self.projectsDisabledMessage)); return true
        }
        if let pending = task.pendingAnswer, [.queued, .delivering, .unknown].contains(pending.phase) {
            completion(pending.operationID == operation ? .accepted(operationID: operation)
                : .failure(code: "question_answer_pending", message: "This question already has a retained answer; resume the Project or inspect its unknown outcome."))
            return true
        }
        if !project.paused, projectRunStarts[project.id] == nil {
            completion(.failure(code: "project_paused", message: "Project interruption is pending.")); return true
        }
        guard project.paused else { return false }
        guard let thread = rpcThread(forAgent: agentID), thread.piSessionID == session, thread.generation == generation,
              thread.dialogs.contains(where: { $0.id == dialog && $0.unavailable == nil }) else {
            completion(.failure(code: "dialog_unavailable", message: "The original native question expired or changed. No answer was sent.")); return true
        }
        guard let data = try? NDJSON.encode(request), data.count <= 32 * 1024 else {
            completion(.failure(code: "invalid", message: "Answer exceeds the 32 KiB envelope limit.")); return true
        }
        let pending = ProjectQuestionAnswer(operationID: operation, sessionID: session, generation: generation, dialogID: dialog, request: data)
        let epoch = logicalProjectEpoch
        Task {
            do {
                _ = try await updateRuntimeProject(project.id, expectedEpoch: epoch) { p in
                    guard p.paused, let i = p.tasks.firstIndex(where: { $0.id == task.id }),
                          self.rpcThread(forAgent: agentID)?.piSessionID == session,
                          self.rpcThread(forAgent: agentID)?.generation == generation,
                          self.rpcThread(forAgent: agentID)?.dialogs.contains(where: { $0.id == dialog && $0.unavailable == nil }) == true else {
                        throw LogicalProjectsError("dialog_unavailable", "Project or question changed. Refresh before answering.")
                    }
                    if let existing = p.tasks[i].pendingAnswer, [.queued, .delivering, .unknown].contains(existing.phase) {
                        guard existing.operationID == operation else { throw LogicalProjectsError("question_answer_pending", "This question already has an answer.") }
                    } else { p.tasks[i].pendingAnswer = pending; p.tasks[i].revision += 1 }
                }
                self.queue.async { completion(.accepted(operationID: operation)) }
            } catch { self.queue.async { completion(.failure(code: (error as? LogicalProjectsError)?.code ?? "project_failed", message: String(describing: error))) } }
        }
        return true
    }

    func deliverProjectAnswers(_ id: ProjectID) {
        guard projectsEnabled, let p = store.state.projects.first(where: { $0.id == id }), !p.paused, projectRunStarts[id] != nil else { return }
        for task in p.tasks {
            guard let pending = task.pendingAnswer, pending.phase == .queued,
                  projectAnswersInFlight.insert(task.id).inserted else { continue }
            changeRuntimeProject(id, { p in
                guard !p.paused, let i = p.tasks.firstIndex(where: { $0.id == task.id }), p.tasks[i].pendingAnswer?.phase == .queued else { return }
                p.tasks[i].pendingAnswer?.phase = .delivering; p.tasks[i].revision += 1
            }) { _ in
                self.projectAnswersInFlight.remove(task.id)
                guard let current = self.store.state.projects.first(where: { $0.id == id }),
                      let answer = current.tasks.first(where: { $0.id == task.id })?.pendingAnswer, answer.phase == .delivering else { return }
                let withinRun = self.projectRunStarts[id].map { Date().timeIntervalSince($0) < self.projectRunSeconds } == true
                    && (self.projectActivations[id] ?? 0) < self.projectActivationLimit
                if !self.projectsEnabled || current.paused || !withinRun {
                    if !current.paused { self.stopProjectRun(id) }
                    self.changeRuntimeProject(id, { p in
                        if let i = p.tasks.firstIndex(where: { $0.id == task.id }) { p.tasks[i].pendingAnswer?.phase = .queued; p.tasks[i].revision += 1 }
                    }); return
                }
                if let assignment = task.executionAssignment,
                   let request = try? NDJSON.decode(NativeThreadRequest.self, from: answer.request) {
                    self.projectActivations[id, default: 0] += 1
                    self.requestProjectPlacement(task, request: .answer(key: assignment.key, request: request))
                    return
                }
                guard let thread = self.rpcThread(forAgent: task.workerAgentID), thread.piSessionID == answer.sessionID,
                      thread.generation == answer.generation, thread.dialogs.contains(where: { $0.id == answer.dialogID && $0.unavailable == nil }),
                      let request = try? NDJSON.decode(NativeThreadRequest.self, from: answer.request),
                      case .answer(let session, let generation, let operation, let dialog, _) = request,
                      session == answer.sessionID, generation == answer.generation, operation == answer.operationID, dialog == answer.dialogID else {
                    self.changeRuntimeProject(id, { p in
                        if let i = p.tasks.firstIndex(where: { $0.id == task.id }) {
                            p.tasks[i].pendingAnswer?.phase = .failed; p.tasks[i].revision += 1
                            p.tasks[i].error = "The original native question expired or changed; the retained answer was not sent. Inspect the worker to ask again."
                        }
                    }); return
                }
                self.projectActivations[id, default: 0] += 1
                thread.handle(request) { result in
                    self.changeRuntimeProject(id, { p in
                        if let i = p.tasks.firstIndex(where: { $0.id == task.id }) {
                            p.tasks[i].revision += 1
                            if case .accepted = result { p.tasks[i].pendingAnswer?.phase = .delivered }
                            else { p.tasks[i].pendingAnswer?.phase = .failed; p.tasks[i].error = "Native question answer was refused. Inspect the worker." }
                        }
                    })
                }
            }
        }
    }
}
