import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Called only for native role=user consumption. Pi child notices have role=custom, so
    /// their continuations preserve this scope; no text or custom-type string grants authority.
    func projectChildUserStarted(agentID: AgentID, thread: RPCThreadState, operation: UUID?) {
        let previous = currentProjectChildScope[agentID]
        defer {
            if let previous, currentProjectChildScope[agentID] != previous { projectChildTakenOver.insert(previous) }
        }
        if let previous = currentProjectChildScope[agentID], operation != previous.key.operationID,
           let project = store.state.projects.first(where: { $0.id == previous.key.projectID }),
           let task = project.tasks.first(where: { $0.workerAgentID == agentID && $0.operationID == previous.key.operationID && $0.phase.occupiesSlot }),
           operation != (task.nativeDeliveryID ?? task.operationID) {
            projectStartedPrompts.remove(agentID)
            changeRuntimeProject(project.id, { p in
                if let i = p.tasks.firstIndex(where: { $0.id == task.id && $0.operationID == task.operationID && $0.phase.occupiesSlot }) {
                    p.tasks[i].phase = .unknown
                    p.tasks[i].question = nil
                    p.tasks[i].error = "A manual turn took over this worker. Project cancellation targets only the original helpers."
                }
            })
        }
        currentProjectChildScope[agentID] = nil
        guard let operation, let session = thread.piSessionID else { return }
        let key: ProjectExecutionKey?
        let scopeEpoch: UInt64
        if let receipt = store.state.projectExecutions.first(where: {
            $0.assignment?.reservedWorkerID == agentID && $0.key.operationID == operation && $0.phase.active
                && $0.sessionID == session && $0.generation == thread.generation
        }) { key = receipt.key; scopeEpoch = receipt.childScopeEpoch ?? 0 }
        else if let project = store.state.projects.first(where: { p in p.tasks.contains {
            $0.workerAgentID == agentID && ($0.nativeDeliveryID ?? $0.operationID) == operation && $0.phase.occupiesSlot
        } }), let task = project.tasks.first(where: { $0.workerAgentID == agentID }) {
            key = .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID)
            scopeEpoch = task.childScopeEpoch ?? 0
        } else { key = nil; scopeEpoch = 0 }
        guard let key else { return }
        let scope = ProjectChildScope(key: key, workerAgentID: agentID, sessionID: session, generation: thread.generation, epoch: scopeEpoch)
        currentProjectChildScope[agentID] = scope
        if executionCancelled.contains(key) || store.state.projects.first(where: { $0.id == key.projectID })?.paused == true {
            projectChildClosed.insert(scope)
        }
    }

    func projectChildScope(_ project: Project, task: ProjectTask, thread: RPCThreadState) -> ProjectChildScope? {
        guard let session = task.workerSessionID, session == thread.piSessionID else { return nil }
        return .init(key: .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID),
                     workerAgentID: task.workerAgentID, sessionID: session, generation: thread.generation, epoch: task.childScopeEpoch ?? 0)
    }

    func projectChildScope(_ receipt: ProjectExecutionReceipt) -> ProjectChildScope? {
        guard let worker = receipt.assignment?.reservedWorkerID, let session = receipt.sessionID, let generation = receipt.generation else { return nil }
        return .init(key: receipt.key, workerAgentID: worker, sessionID: session, generation: generation, epoch: receipt.childScopeEpoch ?? 0)
    }

    /// A durable Resume may rotate only this exact, positively stopped native question.
    /// Recheck after persistence: a manual consumption while saving must win.
    func canResumeProjectChildScope(_ scope: ProjectChildScope) -> Bool {
        guard currentProjectChildScope[scope.workerAgentID] == scope,
              projectChildClosed.contains(scope), projectChildStopped.contains(scope), projectChildDrained.contains(scope),
              !projectChildTakenOver.contains(scope), !executionCancelled.contains(scope.key), scope.epoch < UInt64.max,
              let thread = rpcThread(forAgent: scope.workerAgentID), thread.piSessionID == scope.sessionID,
              thread.generation == scope.generation, thread.waitingOnlyForDialog else { return false }
        return executionConsumed[scope.workerAgentID] == scope.key.operationID
            || (projectPromptInFlight[scope.workerAgentID] == scope.key.operationID && projectStartedPrompts.contains(scope.workerAgentID))
    }

    /// Drain is event-driven inside the existing child controller, independent of the display's
    /// twenty-row cap. No reservation is released from an idle parent alone.
    func projectChildrenSettled(_ scope: ProjectChildScope?, thread: RPCThreadState) -> Bool {
        if let scope, projectChildClosed.contains(scope), !projectChildStopped.contains(scope) { return false }
        guard let scope, projectChildAdmitted.contains(scope), !projectChildDrained.contains(scope) else { return true }
        guard projectChildDraining.insert(scope).inserted else { return false }
        commandProjectChildren(scope, action: .drain) { [weak thread] error in
            self.projectChildDraining.remove(scope)
            guard error == nil, let thread, self.rpcThread(forAgent: scope.workerAgentID) === thread else { return }
            self.projectChildDrained.insert(scope)
            guard !thread.piBusy, self.currentProjectChildScope[scope.workerAgentID] == scope else { return }
            self.projectWorkerSettled(agentID: scope.workerAgentID)
            self.executionSettled(agentID: scope.workerAgentID, thread: thread)
        }
        return false
    }
}
