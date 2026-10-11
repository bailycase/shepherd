import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension SessionServer {
    public func projectExecution(_ request: ProjectExecutionRequest) async throws -> ProjectExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.projectExecutionOnQueue(request) { continuation.resume(with: $0) } }
        }
    }

    func projectExecutionOnQueue(_ request: ProjectExecutionRequest,
                                completion: @escaping @Sendable (Result<ProjectExecutionResult, Error>) -> Void) {
        do {
            try requireStarted()
            switch request {
            case .execute, .resume, .answer: try requireProjectsEnabled()
            case .pause, .cancel, .snapshot, .publicationRead: break
            }
            let generation = projectsGeneration
            let admission: () throws -> Void = {
                try self.requireProjectsEnabled()
                guard self.projectsGeneration == generation else { throw LogicalProjectsError("execution_cancelled", "Execution admission was revoked.") }
            }
            if case .execute = request, onProjectExecutionLaunch == nil {
                throw LogicalProjectsError("unsupported", "Project execution is unavailable on this host.")
            }
            guard Project.validID(request.key.projectID.rawValue) else { throw LogicalProjectsError("invalid_execution", "Invalid project identity.") }
            let key = request.key
            let existing = store.state.projectExecutions.first { $0.key == key }
            switch request {
            case .publicationRead(_, let id, let offset):
                guard let existing else { throw LogicalProjectsError("no_such_execution", "No execution receipt exists.") }
                try readExecutionPublication(existing, id: id, offset: offset, completion: completion)
            case .snapshot:
                guard let existing else { throw LogicalProjectsError("no_such_execution", "No execution receipt exists.") }
                executionSnapshot(existing, completion: completion)
            case .execute(let assignment):
                if let existing {
                    guard existing.assignment == nil || existing.assignment == assignment else {
                        throw LogicalProjectsError("execution_conflict", "An execution identity cannot be reused with a changed assignment.")
                    }
                    executionSnapshot(existing, completion: completion)
                    return
                }
                try assignment.validate()
                guard assignment.nativePrompt.utf8.count <= RPCThreadState.textLimit else {
                    throw LogicalProjectsError("invalid_execution", "Prompt plus Project context exceeds the native 16 KiB input limit.")
                }
                guard !executionPending.contains(key), executionPending.count < 32 else {
                    throw LogicalProjectsError("execution_busy", "Execution reservation is being saved. Retry the same identity.")
                }
                try validateExecutionTarget(assignment)
                guard !store.state.projectExecutions.contains(where: { $0.assignment?.reservedWorkerID == assignment.reservedWorkerID && ($0.phase.active || $0.phase == .unknown) }),
                      !executionWorkers.contains(assignment.reservedWorkerID) else {
                    throw LogicalProjectsError("execution_busy", "Worker already has an outstanding activation.")
                }
                let previous = try executionPredecessor(for: assignment)
                if let previous, let thread = rpcThread(forAgent: assignment.reservedWorkerID) {
                    if thread.session.isAlive { try validateExecutionContinuation(assignment, previous: previous, thread: thread) }
                    else if thread.piBusy || !thread.items.isEmpty || thread.inputOutcomeUnknown {
                        throw LogicalProjectsError("execution_busy", "The worker exited with unacknowledged native or manual work. Its conversation must be inspected first.")
                    }
                }
                executionPending.insert(key)
                executionWorkers.insert(assignment.reservedWorkerID)
                var receipt = ProjectExecutionReceipt(key: key, assignment: assignment, phase: .reserved)
                receipt.previousOperationID = previous?.key.operationID
                saveExecution(key, revalidate: admission, change: { current in
                    try admission()
                    guard current == nil else { throw LogicalProjectsError("execution_conflict", "Execution identity already reserved.") }
                    return receipt
                }) { result in
                    self.executionPending.remove(key)
                    if case .failure = result { self.executionWorkers.remove(assignment.reservedWorkerID) }
                    completion(result.map { ProjectExecutionResult(receipt: $0) })
                    if case .success(let saved) = result { self.launchExecution(saved) }
                }
            case .answer(_, let answer):
                guard let existing, let worker = existing.assignment?.reservedWorkerID,
                      case .answer(let session, let generation, _, let dialog, _) = answer,
                      session == existing.sessionID, generation == existing.generation,
                      existing.phase == .waiting, dialog == existing.questionID,
                      let thread = rpcThread(forAgent: worker), thread.piSessionID == session, thread.generation == generation else {
                    throw LogicalProjectsError("dialog_unavailable", "The original execution question is unavailable.")
                }
                let answered: (NativeThreadResult) -> Void = { result in
                    if case .failure(let code, let message) = result { completion(.failure(LogicalProjectsError(code, message))) }
                    else { self.executionSnapshot(self.store.state.projectExecutions.first { $0.key == key } ?? existing, completion: completion) }
                }
                if !queuePausedExecutionAnswer(agentID: worker, request: answer, completion: answered) { thread.handle(answer, completion: answered) }
            case .pause:
                if let scope = existing.flatMap(projectChildScope) { projectChildClosed.insert(scope) }
                guard let existing else {
                    // Pause before execute is a tombstone, so a delayed execute cannot start.
                    projectExecutionOnQueue(.cancel(key: key), completion: completion); return
                }
                saveExecution(key, change: { current in
                    var r = current ?? existing; r.ownerPaused = true; r.helpersStopped = false; return r
                }) { result in
                    guard case .success(let receipt) = result else { completion(result.map { .init(receipt: $0) }); return }
                    if receipt.phase == .waiting,
                       let worker = receipt.assignment?.reservedWorkerID,
                       let thread = self.rpcThread(forAgent: worker), thread.waitingOnlyForDialog,
                       thread.piSessionID == receipt.sessionID, thread.generation == receipt.generation,
                       let scope = self.projectChildScope(receipt) {
                        self.commandProjectChildren(scope, action: .stop) { error in
                            if let error { completion(.failure(LogicalProjectsError("helper_stop_unknown", error))) }
                            else {
                                self.projectChildDrained.insert(scope)
                                self.saveExecution(key, change: { current in
                                    var r = current ?? receipt; r.helpersStopped = true; return r
                                }) { completion($0.map { .init(receipt: $0) }) }
                            }
                        }
                    } else { self.projectExecutionOnQueue(.cancel(key: key), completion: completion) }
                }
            case .resume:
                guard let existing else { throw LogicalProjectsError("no_such_execution", "No retained execution; Resume does not replay assignments.") }
                guard existing.ownerPaused == true else { completion(.success(.init(receipt: existing))); return }
                guard let oldScope = projectChildScope(existing) else { throw LogicalProjectsError("project_scope", "No retained native question scope.") }
                saveExecution(key, revalidate: admission, change: { current in
                    try admission()
                    guard var r = current else { throw LogicalProjectsError("no_such_execution", "No receipt.") }
                    guard r.ownerPaused == true else { return r }
                    guard r.phase == .waiting, r.helpersStopped == true, self.projectChildScope(r) == oldScope,
                          self.canResumeProjectChildScope(oldScope) else {
                        throw LogicalProjectsError("project_scope", "Resume requires the original parked question and acknowledged helper shutdown.")
                    }
                    r.childScopeEpoch = oldScope.epoch + 1
                    r.childScopeResumedAt = Date().timeIntervalSince1970
                    r.ownerPaused = false; return r
                }) { result in
                    if case .success(let receipt) = result, receipt.ownerPaused != true,
                       receipt.childScopeEpoch == oldScope.epoch + 1, self.canResumeProjectChildScope(oldScope) {
                        self.currentProjectChildScope[oldScope.workerAgentID] = self.projectChildScope(receipt)
                        self.deliverExecutionAnswer(receipt)
                        let epoch = self.logicalProjectEpoch
                        self.queue.asyncAfter(deadline: .now() + self.executionDuration) { [weak self] in
                            guard let self, self.logicalProjectEpoch == epoch,
                                  let latest = self.store.state.projectExecutions.first(where: { $0.key == key }), latest.phase.active,
                                  latest.childScopeEpoch == receipt.childScopeEpoch else { return }
                            self.cancelExpiredExecution(key)
                        }
                    }
                    completion(result.map { .init(receipt: $0) })
                }
            case .cancel:
                executionCancelled.insert(key) // closes launch/send races while durable cancellation stages
                if let scope = existing.flatMap(projectChildScope) { projectChildClosed.insert(scope) }
                saveExecution(key, change: { current in
                    var receipt = current ?? ProjectExecutionReceipt(key: key, phase: .cancelled)
                    let takenOver = self.projectChildScope(receipt).map { self.projectChildTakenOver.contains($0) } == true
                    if receipt.phase.active || (receipt.phase == .unknown && takenOver) { receipt.phase = receipt.sessionID == nil ? .cancelled : .interruptPending }
                    return receipt
                }) { result in
                    switch result {
                    case .success(let receipt):
                        self.executionUnconfirmedStops.remove(key)
                        self.interruptExecution(receipt)
                    case .failure:
                        if let receipt = self.store.state.projectExecutions.first(where: { $0.key == key }) {
                            self.executionUnconfirmedStops.insert(key)
                            self.interruptExecution(receipt)
                        } else if !self.executionPending.contains(key) { self.executionCancelled.remove(key) }
                    }
                    completion(result.map { ProjectExecutionResult(receipt: $0) })
                }
            }
        } catch let error as ProjectValidationError {
            completion(.failure(LogicalProjectsError("invalid_execution", error.description)))
        } catch { completion(.failure(error)) }
    }

    private func validateExecutionTarget(_ assignment: ProjectExecutionAssignment) throws {
        guard store.state.spaces.contains(where: { $0.id == assignment.executorSpaceID && !$0.hidden && !$0.holdsProjects && !$0.holdsDesigns }) else {
            throw LogicalProjectsError("no_such_space", "Choose an existing visible Space on this executor.")
        }
    }

    /// Existing IDs are reusable only through retained proof of this very task's prior activation.
    private func executionPredecessor(for assignment: ProjectExecutionAssignment) throws -> ProjectExecutionReceipt? {
        let records = store.state.projectExecutions.filter { $0.assignment?.reservedWorkerID == assignment.reservedWorkerID }
        let agent = store.state.agents.first { $0.id == assignment.reservedWorkerID }
        if records.isEmpty, agent == nil { return nil }
        guard let agent, agent.coordinatorFor == nil, agent.designID == nil, agent.spaceID == assignment.executorSpaceID,
              records.allSatisfy({ r in
                  r.key.ownerID == assignment.key.ownerID && r.key.projectID == assignment.key.projectID
                      && r.assignment?.taskID == assignment.taskID && r.assignment?.executorSpaceID == assignment.executorSpaceID
              }),
              let previous = records.last(where: { ($0.phase == .settled || $0.phase == .cancelled) && $0.matchedUserEntryID != nil && $0.sessionID != nil }) else {
            throw LogicalProjectsError("execution_conflict", "Only this task's retained, acknowledged native worker may be continued; arbitrary or deleted workers cannot be adopted.")
        }
        return previous
    }

    /// Idle must include host preparations/queues, compaction and native input, not just status.
    private func validateExecutionContinuation(_ assignment: ProjectExecutionAssignment, previous: ProjectExecutionReceipt,
                                              thread: RPCThreadState) throws {
        guard thread.isServable, thread.session.isAlive, !thread.piBusy, thread.items.isEmpty,
              thread.preparingPrompts.isEmpty, !thread.inputActive, !thread.inputOutcomeUnknown,
              thread.piSteering.isEmpty, thread.piFollowUp.isEmpty, thread.dialogs.isEmpty,
              thread.compactingRun == nil, !thread.interruptAbortPending else {
            throw LogicalProjectsError("execution_busy", "The ordinary worker is busy, queued, preparing or not ready. Try a new activation only when it is idle.")
        }
        guard thread.piSessionID == previous.sessionID, !thread.historyUnread,
              thread.history.contains(where: { $0.entryID == previous.matchedUserEntryID })
                || thread.live.contains(where: { $0.value.entryID == previous.matchedUserEntryID }) else {
            throw LogicalProjectsError("execution_history", "The proven prior conversation is unavailable or changed. No new conversation will be created for this follow-up.")
        }
        if thread.generation != previous.generation {
            guard thread.history.last(where: { $0.role == "user" })?.entryID == previous.matchedUserEntryID else {
                throw LogicalProjectsError("execution_history", "This restored conversation contains later manual work without an executor settlement receipt. Continue it manually first.")
            }
        }
        guard assignment.model == nil || assignment.model == thread.model else {
            throw LogicalProjectsError("execution_model", "Follow-ups preserve the worker's current model. Change it in the ordinary thread first, or omit the requested model.")
        }
    }

    private func executionPredecessor(of receipt: ProjectExecutionReceipt) -> ProjectExecutionReceipt? {
        guard let operation = receipt.previousOperationID else { return nil }
        return store.state.projectExecutions.first {
            $0.key.ownerID == receipt.key.ownerID && $0.key.projectID == receipt.key.projectID && $0.key.operationID == operation
        }
    }

    /// Called at the common addAgent boundary too: an asynchronous app launch may have been cancelled.
    func validateExecutionAgentCreation(_ agent: Agent, tab: ShepherdCore.Tab? = nil) throws {
        guard executionWorkers.contains(agent.id) || store.state.projectExecutions.contains(where: { $0.assignment?.reservedWorkerID == agent.id }) else { return }
        try requireProjectsEnabled()
        guard let receipt = store.state.projectExecutions.first(where: { $0.assignment?.reservedWorkerID == agent.id && $0.phase == .reserved }),
              !executionCancelled.contains(receipt.key), receipt.previousOperationID == nil, let assignment = receipt.assignment,
              agent.spaceID == assignment.executorSpaceID, agent.coordinatorFor == nil else {
            throw LogicalProjectsError("execution_cancelled", "Execution launch reservation was revoked.")
        }
        try validateExecutionTarget(assignment)
        guard let space = store.state.spaces.first(where: { $0.id == assignment.executorSpaceID }),
              let layout = tab ?? store.state.tabs.first(where: { $0.id == agent.tabID }),
              layout.layout.leaves.allSatisfy({ ($0.cwd as NSString).expandingTildeInPath == (space.path as NSString).expandingTildeInPath }) else {
            throw LogicalProjectsError("execution_conflict", "Executor Space moved during launch.")
        }
    }

    private func launchExecution(_ receipt: ProjectExecutionReceipt) {
        guard projectsEnabled, receipt.phase == .reserved, !executionCancelled.contains(receipt.key),
              let assignment = receipt.assignment, let launch = onProjectExecutionLaunch else { return }
        let epoch = logicalProjectEpoch
        let remaining = executionDuration - (Date().timeIntervalSince1970 - receipt.admittedAt)
        guard remaining > 0 else {
            cancelExpiredExecution(receipt.key)
            return
        }
        queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.logicalProjectEpoch == epoch,
                  let current = self.store.state.projectExecutions.first(where: { $0.key == receipt.key }), current.phase.active,
                  current.childScopeEpoch == receipt.childScopeEpoch else { return }
            self.cancelExpiredExecution(receipt.key)
        }
        if receipt.previousOperationID != nil, let thread = rpcThread(forAgent: assignment.reservedWorkerID), thread.session.isAlive {
            executionLaunched.insert(receipt.key)
            executionReady(agentID: assignment.reservedWorkerID)
            return
        }
        hopToMain { launch(assignment) { result in
            self.queue.async {
                guard self.logicalProjectEpoch == epoch else { return }
                switch result {
                case .failure(let error):
                    self.executionEvent(receipt.key) { r in
                        guard r.phase == .reserved else { return }
                        r.phase = .failed; r.outcome = Self.executionText(String(describing: error))
                    }
                case .success(let id):
                    guard id == assignment.reservedWorkerID else {
                        self.executionEvent(receipt.key) { $0.phase = .unknown; $0.outcome = "Launcher returned a different worker identity." }; return
                    }
                    self.executionLaunched.insert(receipt.key)
                    self.executionReady(agentID: id)
                }
            }
        } }
    }

    private func cancelExpiredExecution(_ key: ProjectExecutionKey) {
        if let receipt = store.state.projectExecutions.first(where: { $0.key == key }), receipt.ownerPaused == true,
           receipt.phase == .waiting { return } // Keep the human question; helpers also enforce this deadline in their controller.
        projectExecutionOnQueue(.cancel(key: key)) { result in
            if case .failure(let error) = result {
                ShepherdLog.error("Execution deadline cancellation could not persist; interruption remains unconfirmed: \(error)")
            }
        }
    }

    func executionReady(agentID: AgentID?) {
        guard projectsEnabled, let agentID, let receipt = store.state.projectExecutions.first(where: { $0.assignment?.reservedWorkerID == agentID && $0.phase == .reserved }),
              executionLaunched.contains(receipt.key), !executionCancelled.contains(receipt.key), !executionSending.contains(receipt.key),
              let thread = rpcThread(forAgent: agentID), thread.isServable,
              let session = thread.piSessionID, let assignment = receipt.assignment else { return }
        if let previous = executionPredecessor(of: receipt) {
            do { try validateExecutionContinuation(assignment, previous: previous, thread: thread) }
            catch {
                executionEvent(receipt.key) { $0.phase = .failed; $0.outcome = Self.executionText(String(describing: error)) }
                return
            }
        } else if thread.piBusy || !thread.items.isEmpty {
            executionEvent(receipt.key) {
                $0.phase = .failed
                $0.outcome = "Manual work reached this worker before its execution launch completed. No Project prompt was sent."
            }
            return
        }
        executionSending.insert(receipt.key)
        let generation = thread.generation
        saveExecution(receipt.key, change: { current in
            guard var r = current, r.phase == .reserved else { throw LogicalProjectsError("execution_cancelled", "Reservation revoked.") }
            r.phase = .sendReserved; r.sessionID = session; r.generation = generation
            return r
        }) { result in
            self.executionSending.remove(receipt.key)
            guard self.projectsEnabled, case .success(let saved) = result, saved.phase == .sendReserved,
                  !self.executionCancelled.contains(receipt.key),
                  self.rpcThread(forAgent: agentID) === thread, thread.piSessionID == session, thread.generation == generation else { return }
            if let previous = self.executionPredecessor(of: saved) {
                do { try self.validateExecutionContinuation(assignment, previous: previous, thread: thread) }
                catch {
                    self.executionEvent(receipt.key) { $0.phase = .failed; $0.outcome = Self.executionText(String(describing: error)) }
                    return
                }
            }
            guard assignment.model == nil || assignment.model == thread.model else {
                self.executionEvent(receipt.key) { r in
                    r.phase = .failed; r.outcome = "The executor's active model differs from the owner's selected model. No Project prompt was sent."
                }
                return
            }
            self.executionInvoked.insert(receipt.key)
            thread.handle(.send(expectedSessionID: session, generation: generation, operationID: receipt.key.operationID,
                                text: assignment.nativePrompt, delivery: .followUp), isolateSend: true) { result in
                // accepted can mean queued. Only the matched native user entry proves delivery.
                if case .failure(let code, let message) = result {
                    self.executionEvent(receipt.key) { r in
                        guard r.phase == .sendReserved else { return }
                        r.phase = code == "send_cancelled" ? .cancelled : .unknown
                        r.outcome = Self.executionText(message)
                    }
                }
            }
        }
    }

    private func interruptExecution(_ receipt: ProjectExecutionReceipt) {
        guard let assignment = receipt.assignment else { return }
        let unconfirmed = executionUnconfirmedStops.contains(receipt.key)
        let oldHelpers = receipt.phase == .unknown && projectChildScope(receipt).map { projectChildAdmitted.contains($0) } == true
        guard receipt.phase == .interruptPending || (unconfirmed && receipt.phase.active) || oldHelpers else { return }
        if !executionInvoked.contains(receipt.key) {
            if !unconfirmed { executionEvent(receipt.key) { $0.phase = .cancelled } }
            return
        }
        guard let thread = rpcThread(forAgent: assignment.reservedWorkerID),
              thread.piSessionID == receipt.sessionID, thread.generation == receipt.generation else { return }
        // Target a held prompt, not all preparations/queued manual messages in this ordinary thread.
        if thread.cancelExecutionPrompt(receipt.key.operationID) {
            if !unconfirmed { executionEvent(receipt.key) { if $0.phase == .interruptPending { $0.phase = .cancelled } } }
            return
        }
        guard executionInterrupts.insert(receipt.key).inserted, let scope = projectChildScope(receipt) else { return }
        commandProjectChildren(scope, action: .stop) { error in
            if error == nil { self.projectChildDrained.insert(scope) }
            guard self.executionConsumed[assignment.reservedWorkerID] == receipt.key.operationID,
                  self.currentProjectChildScope[assignment.reservedWorkerID] == scope else {
                self.executionInterrupts.remove(receipt.key)
                if error == nil, self.projectChildTakenOver.contains(scope), !unconfirmed {
                    self.executionEvent(receipt.key) { r in
                        r.phase = .cancelled
                        r.outcome = "Original Project turn was superseded by native user input; its helpers stopped. Manual work was not interrupted or attributed to this task."
                    }
                }
                return
            }
            // Failure to reach helpers must not defeat the root's deadline. Recheck the native
            // scope across clear_queue as well; no later/manual turn is ours to abort.
            thread.stop(afterProjectChildren: error != nil, ifCurrent: {
                self.rpcThread(forAgent: assignment.reservedWorkerID) === thread
                    && thread.piSessionID == scope.sessionID && thread.generation == scope.generation
                    && self.executionConsumed[assignment.reservedWorkerID] == scope.key.operationID
                    && self.currentProjectChildScope[assignment.reservedWorkerID] == scope
            }) { result in
                guard RPCThreadState.dispatchFailure(result) == nil else {
                    self.executionInterrupts.remove(receipt.key)
                    return
                }
                if !unconfirmed {
                    self.executionEvent(receipt.key) { r in
                        if r.phase == .interruptPending { r.phase = .cancelled }
                    }
                }
            }
        }
    }

    func executionUserStarted(agentID: AgentID, session: String?, generation: String, operation: UUID?, entryID: String) {
        guard let receipt = executionReceipt(agentID, session: session, generation: generation) else {
            executionConsumed[agentID] = nil
            return
        }
        if let consumed = executionConsumed[agentID], consumed == receipt.key.operationID, operation != consumed {
            executionEvent(receipt.key) {
                $0.phase = .unknown
                $0.outcome = "Another user message took over this worker turn. The Project attempt will not interrupt later manual work."
            }
        }
        executionConsumed[agentID] = operation
        guard let operation, receipt.key.operationID == operation else { return }
        executionEvent(receipt.key) { r in
            r.matchedUserEntryID = Self.executionText(entryID, limit: 512)
            if r.phase == .sendReserved { r.phase = .sent }
        }
        if executionCancelled.contains(receipt.key) { interruptExecution(receipt) }
    }

    func executionQuestion(agentID: AgentID, thread: RPCThreadState) {
        guard let receipt = executionReceipt(agentID, session: thread.piSessionID, generation: thread.generation),
              executionConsumed[agentID] == receipt.key.operationID else { return }
        let dialog = thread.dialogs.first
        executionEvent(receipt.key) { r in
            if let dialog {
                r.questionID = Self.executionText(dialog.id, limit: 512)
                r.question = Self.executionText(dialog.title)
                r.questionKind = dialog.kind.rawValue
                r.questionOptions = dialog.options.map { $0.prefix(16).map { Self.executionText($0, limit: 256) } }
                r.questionMessage = dialog.message.map { Self.executionText($0) }
            }
            if r.phase == .sent || r.phase == .waiting { r.phase = dialog == nil ? .sent : .waiting }
            if let pending = r.pendingAnswer, pending.dialogID != dialog?.id, pending.phase == .queued { r.pendingAnswer?.phase = .failed }
        }
    }

    /// Called after the Changes capture clears busy, never from a status.running=false report.
    func executionSettled(agentID: AgentID, thread: RPCThreadState) {
        guard let receipt = executionReceipt(agentID, session: thread.piSessionID, generation: thread.generation),
              executionConsumed[agentID] == receipt.key.operationID,
              projectChildrenSettled(projectChildScope(receipt), thread: thread) else { return }
        let failed = thread.runFailed
        let entry = receipt.matchedUserEntryID ?? thread.operationsByEntry.first(where: { $0.value == receipt.key.operationID })?.key
        let assistant: NativeThreadMessage?
        if let index = thread.live.lastIndex(where: { $0.value.entryID == entry }) {
            assistant = thread.live.suffix(from: index + 1).last(where: { $0.value.role == "assistant" })?.value
        } else if let index = thread.history.lastIndex(where: { $0.entryID == entry }) {
            assistant = thread.live.last(where: { $0.value.role == "assistant" })?.value
                ?? thread.history.suffix(from: index + 1).last(where: { $0.role == "assistant" })
        } else { assistant = nil }
        let text = assistant?.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        if let scope = projectChildScope(receipt) {
            projectChildClosed.insert(scope)
            if currentProjectChildScope[agentID] == scope { currentProjectChildScope[agentID] = nil }
        }
        executionConsumed[agentID] = nil
        executionEvent(receipt.key) { r in
            guard r.matchedUserEntryID != nil else { return }
            r.phase = r.phase == .interruptPending ? .cancelled : .settled
            r.resultEntryID = assistant.map { Self.executionText($0.entryID, limit: 512) }
            r.resultText = text.map { Self.executionText($0) }
            r.outcome = failed ? "Native turn settled with an error; inspect the thread." : "Native turn settled; success was not inferred."
        }
    }

    func executionExited(agentID: AgentID, stopped: Bool = true) {
        for receipt in store.state.projectExecutions where receipt.assignment?.reservedWorkerID == agentID && receipt.phase.active {
            executionEvent(receipt.key) { r in
                let helpersUnknown = self.projectChildScope(r).map { self.projectChildAdmitted.contains($0) && !self.projectChildStopped.contains($0) } ?? false
                r.phase = r.phase == .interruptPending && stopped && !helpersUnknown ? .cancelled : .unknown
                r.outcome = stopped ? "Worker exited. No execution is automatically replayed." : "Worker metadata was removed; execution outcome is unknown."
            }
        }
        executionConsumed[agentID] = nil
    }

    private func executionReceipt(_ worker: AgentID, session: String?, generation: String) -> ProjectExecutionReceipt? {
        store.state.projectExecutions.first { $0.assignment?.reservedWorkerID == worker && $0.phase.active && $0.sessionID == session && $0.generation == generation }
    }

    private func executionSnapshot(_ receipt: ProjectExecutionReceipt,
                                   completion: @escaping @Sendable (Result<ProjectExecutionResult, Error>) -> Void) {
        guard let worker = receipt.assignment?.reservedWorkerID, let thread = rpcThread(forAgent: worker),
              thread.isServable, receipt.sessionID == thread.piSessionID, receipt.generation == thread.generation else {
            completion(.success(.init(receipt: receipt))); return
        }
        thread.handle(.snapshot()) { result in
            var response = ProjectExecutionResult(receipt: receipt,
                workerTakenOver: self.projectScopeWasTakenOver(self.projectChildScope(receipt)))
            if case .snapshot(let snapshot) = result { response.thread = snapshot }
            // Native snapshot uses almost the entire frame; receipt is extra. Omit rather than disconnect.
            if (try? NDJSON.encode(RemoteReply.projectExecution(id: 0, result: response)).count) ?? Int.max > NDJSON.maxPayloadBytes {
                response.thread = nil
            }
            completion(.success(response))
        }
    }

    static func executionText(_ text: String, limit: Int = 4_096) -> String {
        let clipped = RPCThreadState.clippedText(NativeRedaction.projectData(text), limit: limit)
        let printable = String(clipped.unicodeScalars.map { scalar -> Character in
            scalar.value < 32 && scalar != "\n" && scalar != "\t" ? "�" : Character(scalar)
        })
        return RPCThreadState.clippedText(printable, limit: limit)
    }

    private func executionEvent(_ key: ProjectExecutionKey, change: @escaping (inout ProjectExecutionReceipt) -> Void) {
        saveExecution(key, change: { current in
            guard var r = current else { throw LogicalProjectsError("no_such_execution", "Receipt missing.") }
            guard r.phase.active else { return r }
            change(&r)
            if self.executionUnconfirmedStops.contains(key) {
                r.phase = .unknown
                r.outcome = "Cancellation could not be persisted. A fenced interruption was attempted; inspect the native thread before any further Project activation."
            }
            return r
        }) { result in
            if case .failure(let error) = result {
                self.executionCancelled.insert(key)
                ShepherdLog.error("Execution evidence could not persist: \(error)")
            }
        }
    }

    /// Small receiver-only FIFO. Each stage derives from the current workspace; unrelated edits
    /// force a fresh stage, never a stale full-workspace overwrite. No I/O on the owner queue.
    func saveExecution(_ key: ProjectExecutionKey,
                               revalidate: (() throws -> Void)? = nil,
                               change: @escaping (ProjectExecutionReceipt?) throws -> ProjectExecutionReceipt,
                               completion: @escaping (Result<ProjectExecutionReceipt, Error>) -> Void) {
        guard executionSaves.count < 128 else {
            completion(.failure(LogicalProjectsError("execution_busy", "Too many receipt saves pending."))); return
        }
        let epoch = logicalProjectEpoch
        executionSaves.append {
            self.stageExecution(key, revalidate: revalidate, change: { current in
                guard self.logicalProjectEpoch == epoch else { throw LogicalProjectsError("workspace_changed", "Executor restarted while saving.") }
                return try change(current)
            }, attempt: 0, completion: completion)
        }
        if executionSaves.count == 1 { executionSaves[0]() }
    }

    private func stageExecution(_ key: ProjectExecutionKey,
                                revalidate: (() throws -> Void)? = nil,
                                change: @escaping (ProjectExecutionReceipt?) throws -> ProjectExecutionReceipt, attempt: Int,
                                completion: @escaping (Result<ProjectExecutionReceipt, Error>) -> Void) {
        let finish: (Result<ProjectExecutionReceipt, Error>) -> Void = { result in
            completion(result)
            self.executionSaves.removeFirst()
            self.executionSaves.first?()
        }
        do {
            try requireStarted()
            let before = store.state, version = store.version, epoch = logicalProjectEpoch
            let previous = before.projectExecutions.first { $0.key == key }
            var receipt = try change(previous)
            if receipt == previous { finish(.success(receipt)); return }
            if let previous { receipt.revision = previous.revision + 1 }
            guard previous != nil || before.projectExecutions.count < executionCapacity else {
                throw LogicalProjectsError("execution_capacity", "Receipt capacity is full; retained IDs are never evicted automatically.")
            }
            var candidate = before
            candidate.projectExecutions.removeAll { $0.key == key }
            candidate.projectExecutions.append(receipt)
            let snapshot = candidate, saved = receipt, url = store.url
            logicalProjectFiles.async {
                let staged = Result { try StateStore.stageLogicalProjects(snapshot, at: url) }
                self.queue.async {
                    do {
                        let file = try staged.get()
                        defer { self.logicalProjectFiles.async { _ = unlink(file.path) } }
                        try self.requireStarted()
                        guard self.logicalProjectEpoch == epoch, !self.projectFolderOperation else {
                            throw LogicalProjectsError("workspace_changed", "Executor lifecycle or Space changed while saving.")
                        }
                        if self.store.version != version, attempt < 8 {
                            self.stageExecution(key, revalidate: revalidate, change: change, attempt: attempt + 1, completion: completion)
                            return
                        }
                        try revalidate?()
                        try self.store.commitLogicalProjects(snapshot, version: version, staged: file)
                        self.stateDidCommit(before: before)
                        self.executionDidCommit(saved)
                        if !saved.phase.active, let worker = saved.assignment?.reservedWorkerID { self.executionWorkers.remove(worker) }
                        finish(.success(saved))
                    } catch { finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }
}
