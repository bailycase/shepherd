import Foundation
import CryptoKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

public struct ProjectHistoryReadGrant: Sendable {
    var epoch: UInt64
    var generation: UInt64
    var authority: UUID
    var caller: AgentID?
    var routes: [ProjectHostReference: [SpaceID: UUID]]
}

extension SessionServer {
    func historyReadGrant(_ project: Project, caller: AgentID? = nil) throws -> ProjectHistoryReadGrant {
        let current = try runtimeProject(project.id)
        guard current.ownerID == project.ownerID else { throw LogicalProjectsError("project_scope", "Project ownership changed.") }
        if projectReadAuthority[project.id] == nil { projectReadAuthority[project.id] = UUID() }
        return .init(epoch: logicalProjectEpoch, generation: projectsGeneration, authority: projectReadAuthority[project.id]!, caller: caller, routes: projectExecutionSpaceAuthority)
    }

    func validateHistoryRead(_ project: Project, grant: ProjectHistoryReadGrant, taskID: ProjectTaskID? = nil) throws -> Project {
        let current = try runtimeProject(project.id)
        guard logicalProjectEpoch == grant.epoch, projectsGeneration == grant.generation,
              projectReadAuthority[project.id] == grant.authority, current.ownerID == project.ownerID else {
            throw LogicalProjectsError("project_scope", "Project read permission was revoked.")
        }
        if let caller = grant.caller {
            let coordinator = current.coordinatorAgentID == caller && store.state.agents.contains { $0.id == caller && $0.coordinatorFor == current.id }
            let worker = current.tasks.contains { $0.workerAgentID == caller && (taskID == nil || $0.id == taskID) }
            guard coordinator || worker else { throw LogicalProjectsError("project_scope", "The caller no longer owns this read grant.") }
        }
        return current
    }
    /// Keeps the original viewer permission across routing/native I/O. Re-enable cannot revive it.
    public func projectWorkerReadGrant(_ id: ProjectID) async throws -> ProjectHistoryReadGrant {
        try await enqueue {
            _ = try self.runtimeProject(id)
            if self.projectReadAuthority[id] == nil { self.projectReadAuthority[id] = UUID() }
            return .init(epoch: self.logicalProjectEpoch, generation: self.projectsGeneration, authority: self.projectReadAuthority[id]!, caller: nil, routes: self.projectExecutionSpaceAuthority)
        }
    }

    public func validateProjectWorkerRead(_ id: ProjectID, grant: ProjectHistoryReadGrant, task: ProjectTask? = nil) async throws {
        try await enqueue {
            _ = try self.validateHistoryRead(try self.runtimeProject(id), grant: grant)
            if let task { try self.validateDirectoryRead(task, grant: grant) }
        }
    }

    private func validateDirectoryRead(_ task: ProjectTask, grant: ProjectHistoryReadGrant) throws {
        guard task.destination != .local else { return }
        guard let token = grant.routes[task.destination]?[task.spaceID],
              projectExecutionSpaceAuthority[task.destination]?[task.spaceID] == token else {
            throw LogicalProjectsError("project_scope", "The original executor Space route was revoked.")
        }
    }

    /// Recheck at each outer release, not just inside the history reader. Its result can cross more awaits and a reply queue.
    func validateProjectToolResponse(_ response: Project, request: ProjectRuntimeRequest, grant: ProjectHistoryReadGrant) throws -> UInt64 {
        let current = try validateHistoryRead(response, grant: grant, taskID: request.targetTaskID)
        if let taskID = request.targetTaskID, let task = response.tasks.first(where: { $0.id == taskID }) {
            _ = try authorizedResultProject(response, task: task, archivedResolved: task.phase == .resolved, grant: grant)
        }
        return current.revision
    }

    func projectHistoryRead<T: Sendable>(_ read: @escaping @Sendable (ProjectHistoryStore) throws -> T) async throws -> T {
        let url = try await enqueue { self.store.url }
        return try await withCheckedThrowingContinuation { continuation in
            projectHistoryReads.async {
                continuation.resume(with: Result { try read(ProjectHistoryStore(beside: url)) })
            }
        }
    }

    func readProjectHistory(_ project: Project, request: ProjectRuntimeRequest, grant: ProjectHistoryReadGrant) async throws -> Project {
        if case .result(let task, let operation, let offset, let hash) = request {
            return try await readProjectResult(project, taskID: task, operation: operation, offset: offset, hash: hash, grant: grant)
        }
        if case .outcomes(let task, let operation, let before) = request {
            return try await readProjectOutcomes(project, taskID: task, operation: operation, before: before, grant: grant)
        }
        let value: Project = try await projectHistoryRead { history in
            try history.captureCommitted(project)
            var response = project
            switch request {
            case .worker(let id):
                guard let task = try history.taskByID(project, id: id) else { throw LogicalProjectsError("not_found", "No historical worker route exists.") }
                response.tasks = [task]; response.messages = []
            case .inspect(let task, let operation):
                guard let selectedTask = try history.taskByID(project, id: task) else { throw LogicalProjectsError("project_scope", "Task is not in this Project.") }
                response.tasks = [selectedTask]
                let messages = try history.messages(project, task: task, operation: operation)
                let live = project.messages.filter { $0.source?.taskID == task && (operation == nil || $0.source?.operationID == operation) }
                let liveIDs = Set(live.map(\.id))
                response.messages = Array((messages.filter { !liveIDs.contains($0.id) } + live).suffix(3))
                response.messages += project.messages.filter { $0.humanSubmitted == true && $0.phase == .delivered }
                response.tasks = response.tasks.filter { $0.id == task }
                let selected = operation ?? response.tasks.first?.operationID
                if let selected { response.resultPage = try history.resultDescriptor(project, task: task, operation: selected) }
            case .history(let task, let before, let bodies):
                response.tasks = try task.flatMap { try history.taskByID(project, id: $0) }.map { [$0] } ?? []
                if task != nil, response.tasks.isEmpty { throw LogicalProjectsError("project_scope", "Task is not in this Project.") }
                let entries = try history.history(project, task: task, before: before, includeBodies: bodies == true)
                response.tasks = response.tasks.filter { $0.id == task }; response.messages = []
                response.historyPage = entries
                response.historyNext = entries.last?.sequence
            default: break
            }
            return response
        }
        if case .worker = request, let task = value.tasks.first, task.destination != .local {
            let handler = try await enqueue {
                _ = try self.authorizedResultProject(project, task: task, archivedResolved: task.phase == .resolved, grant: grant)
                guard let handler = self.onProjectPlacement else { throw LogicalProjectsError("execution_host_unavailable", "The original executor is unavailable.") }
                return handler
            }
            guard let assignment = task.executionAssignment else { throw LogicalProjectsError("stale_execution", "No exact assignment is retained.") }
            let remote: ProjectExecutionResult = try await withCheckedThrowingContinuation { continuation in
                self.hopToMain { handler(task.destination, .worker(key: assignment.key)) { continuation.resume(with: $0) } }
            }
            guard remote.receipt.key == assignment.key, remote.receipt.assignment == assignment,
                  remote.receipt.sessionID == task.executionReceipt?.sessionID,
                  remote.receipt.generation == task.executionReceipt?.generation,
                  let thread = remote.thread,
                  thread.piSessionID == remote.receipt.sessionID, thread.generation == remote.receipt.generation else {
                throw LogicalProjectsError("stale_execution", "The original executor cannot provide the exact native worker source.")
            }
        }
        return try await enqueue {
            try self.requireStarted()
            let current = try self.validateHistoryRead(project, grant: grant, taskID: request.targetTaskID)
            if case .worker = request {
                guard let task = value.tasks.first else { throw LogicalProjectsError("project_scope", "Missing worker route.") }
                _ = try self.authorizedResultProject(project, task: task, archivedResolved: task.phase == .resolved, grant: grant)
                if task.destination == .local {
                    guard let agent = self.store.state.agents.first(where: { $0.id == task.workerAgentID }),
                          current.tasks.contains(where: { $0.id == task.id }) || agent.projectWorkerFor == current.id,
                          task.workerSessionID != nil, (self.rpcThread(forAgent: task.workerAgentID)?.piSessionID ?? agent.piSessionID) == task.workerSessionID else {
                        throw LogicalProjectsError("stale_execution", "The exact historical worker session is unavailable.")
                    }
                } else {
                    guard let receipt = task.executionReceipt, receipt.key.ownerID == current.ownerID,
                          receipt.key.projectID == current.id, receipt.key.operationID == task.operationID,
                          receipt.assignment == task.executionAssignment, receipt.assignment?.reservedWorkerID == task.workerAgentID,
                          receipt.sessionID != nil else { throw LogicalProjectsError("stale_execution", "The exact remote worker receipt is unavailable.") }
                }
            }
            var fresh = value; fresh.revision = current.revision
            return fresh
        }
    }

    func replayProjectCommand(_ project: Project, request: ProjectRuntimeRequest) async throws -> Project? {
        guard let operation = request.operationID else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
        let receipt: ProjectOperationReceipt? = try await projectHistoryRead { history in
            if let command = try history.command(project, operation: operation) {
                let originalMessage = try project.messages.first(where: { $0.id == operation }) ?? history.record(project, kind: "message", id: operation.uuidString, as: ProjectMessage.self)
                // Message retries retain the original admitted turn, never the replacement text.
                let messageRetry: Bool
                if case .message = request { messageRetry = originalMessage != nil } else { messageRetry = false }
                guard command.sha256 == digest || messageRetry else { throw LogicalProjectsError("operation_conflict", "A retained operation cannot change its payload.") }
                let archivedOutcome = try history.outcome(project, id: operation)
                let task = try history.task(project, operation: operation) ?? archivedOutcome.flatMap { try history.taskByID(project, id: $0.taskID) }
                let proposal = try project.spaceProposals.first(where: { $0.operationID == operation })
                    ?? history.record(project, kind: "proposal", id: operation.uuidString, as: ProjectSpaceProposal.self)
                return .init(operationID: operation, task: task, proposal: proposal, message: originalMessage)
            }
            let hot = project.messages.contains { $0.id == operation } || project.tasks.contains { $0.operationID == operation || ($0.previousOperations ?? []).contains(operation) || ($0.resolutionOperations ?? []).contains(operation) || ($0.outcomes ?? []).contains { $0.id == operation } }
                || project.memoryOperations.contains(operation) || project.spaceProposals.contains { $0.operationID == operation }
            if !hot, try history.legacyOperation(project, operation: operation) {
                throw LogicalProjectsError("operation_retained", "Legacy replay proof exists but its original payload cannot be verified. No work was resent.")
            }
            return nil
        }
        guard let receipt else { return nil }
        return try await enqueue {
            var fresh = try self.runtimeProject(project.id)
            guard fresh.ownerID == project.ownerID, fresh.coordinatorAgentID == project.coordinatorAgentID else { throw LogicalProjectsError("project_scope", "Project authority changed.") }
            fresh.operationReceipt = receipt
            return fresh
        }
    }

    private func readProjectResult(_ project: Project, taskID: ProjectTaskID, operation: UUID, offset: Int64, hash: String?, grant: ProjectHistoryReadGrant) async throws -> Project {
        guard offset >= 0, offset == 0 || hash != nil else { throw LogicalProjectsError("invalid_result_page", "Continuation requires its immutable digest and a nonnegative byte offset.") }
        let selection = try await projectHistoryRead { history in
            let task = try history.task(project, operation: operation)
            let legacy = try history.record(project, kind: "legacy_activation", id: operation.uuidString, as: ProjectTaskID.self) == taskID
                || !history.messages(project, task: taskID, operation: operation).isEmpty
            let archivedResolved = try history.taskByID(project, id: taskID)?.phase == .resolved
            return (task, legacy, archivedResolved)
        }
        guard let task = selection.0 else {
            guard selection.1 else { throw LogicalProjectsError("project_scope", "No exact task/operation evidence is retained.") }
            return try await enqueue {
                var fresh = try self.validateHistoryRead(project, grant: grant, taskID: taskID)
                guard fresh.ownerID == project.ownerID, fresh.coordinatorAgentID == project.coordinatorAgentID,
                      fresh.tasks.contains(where: { $0.id == taskID }) else { throw LogicalProjectsError("project_scope", "Result authority changed.") }
                fresh.tasks = fresh.tasks.filter { $0.id == taskID }; fresh.messages = []
                fresh.resultPage = .init(availability: .unavailable, reason: "Legacy receipt lacks a provable complete capture and immutable original assignment. No current session or host was substituted.")
                return fresh
            }
        }
        guard task.id == taskID else { throw LogicalProjectsError("project_scope", "Operation belongs to another task.") }
        var page = try await projectHistoryRead { try $0.result(project, task: taskID, operation: operation, offset: offset, hash: hash) }
        if task.destination != .local {
            try await authorizeResultRoute(project, task: task, archivedResolved: selection.2, grant: grant)
            guard let assignment = task.executionAssignment, let expected = task.executionReceipt,
                  assignment.key.operationID == operation else { throw LogicalProjectsError("unavailable_result", "No exact executor identity was retained.") }
            let handler = try await enqueue { self.onProjectPlacement }
            guard let handler else { throw LogicalProjectsError("remote_offline", "No executor route is available.") }
            let reply: ProjectExecutionResult = try await withCheckedThrowingContinuation { continuation in
                self.hopToMain { handler(task.destination, .result(key: assignment.key, offset: offset, sha256: hash)) { continuation.resume(with: $0) } }
            }
            guard reply.receipt.key == assignment.key, reply.receipt.assignment == assignment,
                  reply.receipt.sessionID == expected.sessionID, reply.receipt.generation == expected.generation else {
                throw LogicalProjectsError("stale_result", "Executor receipt does not match the original operation/session.")
            }
            guard var remote = reply.resultPage else { throw LogicalProjectsError("unsupported_result", "Executor does not offer exact result pages.") }
            if let identity = remote.identity {
                guard identity.ownerID == project.ownerID, identity.projectID == project.id,
                      identity.source.taskID == task.id, identity.source.operationID == operation,
                      identity.source.workerAgentID == task.workerAgentID, identity.source.sessionID == expected.sessionID,
                      identity.source.generation == expected.generation, identity.deliveryID == operation,
                      identity.source.kind == .settled, identity.host == .local else { throw LogicalProjectsError("project_scope", "Remote result has the wrong native identity.") }
                guard remote.redacted, remote.totalBytes >= 0, remote.totalBytes <= Int64(Int32.max),
                      remote.data.count <= ProjectHistoryStore.chunkBytes, remote.offset == offset,
                      !remote.data.isEmpty || offset == remote.totalBytes,
                      remote.sha256?.utf8.count == 64, remote.sha256?.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) == true,
                      remote.totalBytes >= offset + Int64(remote.data.count), hash == nil || hash == remote.sha256,
                      remote.nextOffset == (offset + Int64(remote.data.count) < remote.totalBytes ? offset + Int64(remote.data.count) : nil),
                      String(data: remote.data, encoding: .utf8) != nil else { throw LogicalProjectsError("invalid_result_page", "Executor returned invalid page boundaries.") }
                try await authorizeResultRoute(project, task: task, archivedResolved: selection.2, grant: grant)
                let descriptor = remote
                try await projectHistoryRead { try $0.adoptRemoteDescriptor(project, task: task, page: descriptor) }
                page = try await projectHistoryRead { try $0.result(project, task: taskID, operation: operation, offset: offset, hash: hash) }
                remote.originEventID = identity.eventID; remote.originIdentity = identity; remote.identity = page.identity
            } else if remote.availability == .complete || remote.availability == .incomplete || !remote.data.isEmpty || remote.totalBytes != 0 || remote.sha256 != nil {
                throw LogicalProjectsError("invalid_result_page", "Content without an exact native identity is not a result.")
            }
            page = remote
        }
        let finalPage = page
        return try await enqueue {
            var fresh = try self.authorizedResultProject(project, task: task, archivedResolved: selection.2, grant: grant)
            fresh.tasks = fresh.tasks.filter { $0.id == taskID }; fresh.messages = []
            fresh.resultPage = finalPage
            return fresh
        }
    }

    /// Outcome facts are owner-stored, but an executor task's facts follow its captured route grant exactly as its result does:
    /// select the task, authorize it before any page I/O, page in SQL, then authorize again at return. Removing or replacing that
    /// Space at any point (including remove/restore while this read is suspended) permanently revokes the captured grant; a fresh
    /// read with a fresh grant may succeed. Other Spaces' changes never revoke it.
    private func readProjectOutcomes(_ project: Project, taskID: ProjectTaskID, operation: UUID?, before: Int64?, grant: ProjectHistoryReadGrant) async throws -> Project {
        let boundary = try await enqueue { self.historyReadBoundary }
        await boundary?("initial")
        // A working-set task is authorized before any history I/O; an archived one right after its record is selected.
        if let hot = project.tasks.first(where: { $0.id == taskID }) { try await authorizeResultRoute(project, task: hot, archivedResolved: false, grant: grant) }
        let task: ProjectTask = try await projectHistoryRead { history in
            try history.captureCommitted(project)
            guard let task = try history.taskByID(project, id: taskID) else { throw LogicalProjectsError("project_scope", "Task is not in this Project.") }
            if let operation, operation != task.operationID, !(task.previousOperations ?? []).contains(operation),
               try history.record(project, kind: "activation", id: operation.uuidString, as: ProjectTask.self)?.id != taskID,
               try history.record(project, kind: "legacy_activation", id: operation.uuidString, as: ProjectTaskID.self) != taskID {
                throw LogicalProjectsError("project_scope", "Operation is not a run of this task.")
            }
            return task
        }
        let archived = task.phase == .resolved && !project.tasks.contains { $0.id == taskID }
        try await authorizeResultRoute(project, task: task, archivedResolved: archived, grant: grant)
        let (page, next) = try await projectHistoryRead { try $0.outcomes(project, task: taskID, operation: operation, before: before) }
        await boundary?("final")
        return try await enqueue {
            try self.requireStarted()
            var fresh = try self.authorizedResultProject(project, task: task, archivedResolved: archived, grant: grant)
            fresh.tasks = [task]; fresh.messages = []
            fresh.outcomePage = page; fresh.historyNext = next
            return fresh
        }
    }

    private func authorizeResultRoute(_ project: Project, task: ProjectTask, archivedResolved: Bool, grant: ProjectHistoryReadGrant) async throws {
        try await enqueue { _ = try self.authorizedResultProject(project, task: task, archivedResolved: archivedResolved, grant: grant) }
    }

    func authorizedResultProject(_ project: Project, task: ProjectTask, archivedResolved: Bool, grant: ProjectHistoryReadGrant) throws -> Project {
        let current = try validateHistoryRead(project, grant: grant, taskID: task.id)
        guard
              current.ownerID == project.ownerID, current.coordinatorAgentID == project.coordinatorAgentID,
              current.tasks.contains(where: { $0.id == task.id && $0.workerAgentID == task.workerAgentID })
                || (archivedResolved && !current.tasks.contains(where: { $0.id == task.id }) && (current.archivedResolvedTaskCount ?? 0) > 0) else {
            throw LogicalProjectsError("project_scope", "Result authority was revoked.")
        }
        if task.destination != .local {
            try validateDirectoryRead(task, grant: grant)
            try validateProjectDestination(task.destination, spaceID: task.spaceID)
            guard current.linkedSpaces.contains(where: { $0.spaceID == task.spaceID && $0.destination == task.destination }),
                  current.settings.hostPolicy == .anyConnected || current.settings.allowedHosts.contains(task.destination) else {
                throw LogicalProjectsError("project_host_policy", "The original executor binding is no longer authorized.")
            }
        }
        return current
    }
}
