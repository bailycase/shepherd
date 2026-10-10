import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension SessionServer {
    struct PublicationAuthority: Equatable, Sendable {
        var scope: ProjectChildScope
        var taskID: ProjectTaskID
        var cwd: String
        var local: Bool
        var epoch: UInt64
    }

    /// One admission/revalidation boundary. Native consumed-operation scope is authority;
    /// project context, a started-agent set, status text and model IDs are not.
    func publicationAuthority(_ worker: AgentID) throws -> PublicationAuthority {
        try requireStarted()
        try requireProjectsEnabled()
        guard let scope = currentProjectChildScope[worker], !projectChildClosed.contains(scope),
              scope.workerAgentID == worker, let thread = rpcThread(forAgent: worker),
              thread.isServable, thread.session.isAlive, thread.piBusy, !thread.stopRequested,
              thread.piSessionID == scope.sessionID, thread.generation == scope.generation else {
            throw LogicalProjectsError("publication_scope", "Only an active native-scoped Project worker may publish.")
        }
        if let project = store.state.projects.first(where: { $0.id == scope.key.projectID && $0.ownerID == scope.key.ownerID }) {
            guard !project.paused, project.coordinatorAgentID != worker, projectRunStarts[project.id] != nil,
                  let task = project.tasks.first(where: { $0.workerAgentID == worker && $0.operationID == scope.key.operationID }),
                  task.executionAssignment == nil, [.running, .waiting].contains(task.phase), task.workerSessionID == scope.sessionID else {
                throw LogicalProjectsError("publication_scope", "The original Project task is no longer active.")
            }
            return .init(scope: scope, taskID: task.id, cwd: thread.session.cwd, local: true, epoch: logicalProjectEpoch)
        }
        guard let execution = store.state.projectExecutions.first(where: { $0.key == scope.key }),
              execution.assignment?.reservedWorkerID == worker, let task = execution.assignment?.taskID,
              execution.assignment?.publicationsEnabled == true, execution.ownerPaused != true,
              [.sent, .waiting].contains(execution.phase), !executionCancelled.contains(scope.key),
              execution.sessionID == scope.sessionID, execution.generation == scope.generation,
              execution.matchedUserEntryID != nil else {
            throw LogicalProjectsError("publication_scope", "Execution has no active publication-capable owner assignment.")
        }
        return .init(scope: scope, taskID: task, cwd: thread.session.cwd, local: false, epoch: logicalProjectEpoch)
    }

    func projectPublish(_ worker: AgentID, request: ProjectPublicationRequest) async throws -> ProjectPublicationResult {
        if case .eligibility = request {
            return try await enqueue { .init(active: (try? self.publicationAuthority(worker)) != nil) }
        }
        guard case .publish(let id, let path, let name) = request else { preconditionFailure() }
        guard ProjectArtifactReceipt.safeComponent(name), NativeRedaction.projectData(name) == name else { throw LogicalProjectsError("invalid_path", "Artifact name must be one safe filename.") }
        _ = try ProjectPublicationFiles.sourceParts(path)
        let captured = try await enqueue { () -> (PublicationAuthority, URL, [String]) in
            let authority = try self.publicationAuthority(worker)
            let receipts = authority.local
                ? self.store.state.projects.first(where: { $0.id == authority.scope.key.projectID })?.artifacts ?? []
                : self.store.state.projectExecutions.first(where: { $0.key == authority.scope.key })?.publications ?? []
            guard receipts.contains(where: { $0.id == id }) || receipts.count < ProjectArtifactReceipt.maximumCount else {
                throw LogicalProjectsError("publication_capacity", "Publication receipt ledger is full.")
            }
            guard self.publicationPending.count < 4, self.publicationPending.insert(id).inserted else {
                throw LogicalProjectsError("publication_busy", "Publication is pending; retry the same tool call identity.")
            }
            return (authority, self.store.url, [self.store.url.deletingLastPathComponent().path, self.pi.home.path,
                NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.pi", NSHomeDirectory() + "/.agents"])
        }
        defer { queue.async { self.publicationPending.remove(id) } }
        let authority = captured.0, scope = authority.scope, stateURL = captured.1
        let deadline = Date().addingTimeInterval(ProjectArtifactReceipt.transferSeconds)
        let revalidate: @Sendable () throws -> Void = {
            guard Date() < deadline else { throw LogicalProjectsError("publication_timeout", "Publication deadline exceeded; retained receipts are not silently replayed.") }
            guard try self.publicationAuthority(worker) == authority else { throw LogicalProjectsError("publication_scope", "Native publication authority expired.") }
        }
        let identity = ProjectPublicationFiles.hash(Data(path.utf8))
        let receipt: ProjectArtifactReceipt = try await publicationIO(revalidate: revalidate) {
            if let retained = try ProjectPublicationFiles.retained(id, beside: stateURL) {
                guard retained.key == scope.key, retained.taskID == authority.taskID,
                      retained.workerAgentID == worker, retained.sessionID == scope.sessionID,
                      retained.generation == scope.generation, retained.artifactName == name, retained.sourceIdentity == identity else {
                    throw LogicalProjectsError("publication_conflict", "Publication identity is immutable; retry the original arguments.")
                }
                return retained
            }
            let bytes = try ProjectPublicationFiles.source(path, cwd: authority.cwd, protected: captured.2)
            let receipt = ProjectArtifactReceipt(id: id, key: scope.key, taskID: authority.taskID, workerAgentID: worker,
                sessionID: scope.sessionID, generation: scope.generation, artifactName: name, size: Int64(bytes.count),
                sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: identity)
            try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: stateURL)
            return receipt
        }
        try await enqueue { try revalidate() }
        if !authority.local {
            _ = try await savePublicationExecution(receipt, revalidate: revalidate)
            return .init(active: true, artifact: receipt) // honest staged/waiting, never published
        }
        _ = try await updateRuntimeProject(scope.key.projectID, expectedEpoch: authority.epoch, revalidate: revalidate) { project in
            guard try self.publicationAuthority(worker) == authority else { throw LogicalProjectsError("publication_scope", "Worker authority changed before staging receipt.") }
            if let previous = project.artifacts.first(where: { $0.id == id }) {
                if previous.state == .refused { throw LogicalProjectsError(previous.refusal ?? "publication_refused", "Publication was definitively refused; no side effect was retried.") }
                var staged = previous; staged.state = .staged
                guard staged == receipt else { throw LogicalProjectsError("publication_conflict", "Publication identity was reused.") }
            } else { project.artifacts.append(receipt) }
            try ProjectArtifactReceipt.validateCollection(project.artifacts)
        }
        do { try await commitPublication(receipt, beside: stateURL, revalidate: revalidate) }
        catch {
            if let code = (error as? LogicalProjectsError)?.code, ["artifact_collision", "publication_corrupt"].contains(code) {
                _ = try? await updateRuntimeProject(scope.key.projectID, expectedEpoch: authority.epoch) { project in
                    guard let index = project.artifacts.firstIndex(where: { $0.id == id && $0.state == .staged }) else { return }
                    project.artifacts[index].state = .refused; project.artifacts[index].refusal = code
                }
            }
            throw error
        }
        var ready = receipt; ready.state = .ready
        let committed = ready
        _ = try await updateRuntimeProject(scope.key.projectID, expectedEpoch: authority.epoch, revalidate: revalidate) { project in
            guard try self.publicationAuthority(worker) == authority,
                  let index = project.artifacts.firstIndex(where: { $0.id == id }) else {
                throw LogicalProjectsError("publication_scope", "Publication receipt not acknowledged: worker authority changed.")
            }
            project.artifacts[index] = committed
        }
        return .init(active: true, artifact: committed)
    }

    /// Recover only an already committed inode plus its durable provenance manifest. Restart never
    /// opens a worker source or commits bytes left merely staged by an interrupted turn.
    func recoverCommittedProjectPublications() {
        let epoch = logicalProjectEpoch, url = store.url
        let staged = store.state.projects.flatMap(\.artifacts).filter { $0.state == .staged }
        Task {
            for receipt in staged {
                var ready = receipt; ready.state = .ready
                let artifact = ready
                guard (try? await self.publicationIO { try ProjectPublicationFiles.verifyCommitted(artifact, beside: url) }) == true else { continue }
                _ = try? await self.updateRuntimeProject(artifact.key.projectID, expectedEpoch: epoch) { current in
                    guard current.ownerID == artifact.key.ownerID,
                          let index = current.artifacts.firstIndex(of: receipt) else { return }
                    current.artifacts[index] = artifact
                }
            }
        }
    }

    /// Preparation may wait on disk; the final authority check and rename cannot yield to Pause,
    /// takeover, deletion, session replacement or restart. Durability work follows off-queue.
    func commitPublication(_ receipt: ProjectArtifactReceipt, beside url: URL,
                           revalidate: @escaping @Sendable () throws -> Void) async throws {
        let beforeCommit = try await enqueue { self.publicationBeforeCommit }
        let prepared = try await publicationIO(revalidate: revalidate) {
            try ProjectPublicationFiles.prepareCommit(receipt, beside: url)
        }
        await beforeCommit?()
        try await enqueue {
            try self.requireProjectsEnabled()
            try revalidate()
            try prepared.rename()
        }
        try await publicationIO { try prepared.finish() }
    }

    func publicationIO<T: Sendable>(revalidate: (@Sendable () throws -> Void)? = nil,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            logicalProjectFiles.async {
                guard let revalidate else { continuation.resume(with: Result { try body() }); return }
                // Recheck after the file-queue backlog, not merely when the request was admitted.
                self.queue.async {
                    do {
                        try revalidate()
                        self.logicalProjectFiles.async { continuation.resume(with: Result { try body() }) }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private func savePublicationExecution(_ publication: ProjectArtifactReceipt, revalidate: @escaping @Sendable () throws -> Void) async throws -> ProjectExecutionReceipt {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.saveExecution(publication.key, revalidate: revalidate, change: { current in
                    try revalidate()
                    guard var current else {
                        throw LogicalProjectsError("publication_scope", "Worker authority changed before publication receipt.")
                    }
                    var publications = current.publications ?? []
                    if let old = publications.first(where: { $0.id == publication.id }) {
                        guard old == publication else { throw LogicalProjectsError("publication_conflict", "Publication identity was reused.") }
                    } else { publications.append(publication) }
                    try ProjectArtifactReceipt.validateCollection(publications)
                    current.publications = publications
                    return current
                }) { continuation.resume(with: $0) }
            }
        }
    }

    func readExecutionPublication(_ execution: ProjectExecutionReceipt, id: UUID, offset: Int64,
                                  completion: @escaping @Sendable (Result<ProjectExecutionResult, Error>) -> Void) throws {
        guard let publication = execution.publications?.first(where: { $0.id == id }),
              publicationPending.count < 4, logicalProjectReadCount < 8 else {
            throw LogicalProjectsError("publication_unavailable", "Publication is not retained or its read budget is busy.")
        }
        try publication.validate()
        let url = store.url, epoch = logicalProjectEpoch
        logicalProjectReadCount += 1
        logicalProjectFiles.async {
            let result = Result { try ProjectPublicationFiles.chunk(publication, offset: offset, beside: url) }
            self.queue.async {
                self.logicalProjectReadCount -= 1
                do {
                    try self.requireStarted()
                    guard self.logicalProjectEpoch == epoch,
                          self.store.state.projectExecutions.first(where: { $0.key == execution.key })?.publications?.contains(publication) == true else {
                        throw LogicalProjectsError("publication_unavailable", "Retained publication changed during read.")
                    }
                    var response = ProjectExecutionResult(receipt: execution)
                    response.publication = .init(publicationID: id, offset: offset, data: try result.get())
                    completion(.success(response))
                } catch { completion(.failure(error)) }
            }
        }
    }
}
