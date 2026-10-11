import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Change notifications/reconnect pull already-produced bytes only during an authorized
    /// owner run. Restart needs explicit Resume; no transfer reissues a model operation.
    func reconcileProjectPublications(_ execution: ProjectExecutionReceipt, task: ProjectTask) {
        guard let assignment = execution.assignment, assignment.taskID == task.id,
              assignment.reservedWorkerID == task.workerAgentID,
              assignment == task.executionAssignment,
              ([task.operationID] + (task.previousOperations ?? [])).contains(assignment.key.operationID),
              (try? execution.validate()) != nil else { return }
        for artifact in execution.publications ?? [] {
            var owned = artifact; owned.executor = task.destination
            startPublicationTransfer(owned)
        }
    }

    func publicationOwner(_ artifact: ProjectArtifactReceipt, epoch: UInt64) throws -> Project {
        try requireStarted()
        try requireProjectsEnabled()
        guard logicalProjectEpoch == epoch, let host = artifact.executor, host != .local,
              let project = store.state.projects.first(where: { $0.id == artifact.key.projectID && $0.ownerID == artifact.key.ownerID }),
              !project.paused, projectRunStarts[project.id] != nil,
              let task = project.tasks.first(where: { $0.id == artifact.taskID && $0.workerAgentID == artifact.workerAgentID }),
              task.destination == host, ([task.operationID] + (task.previousOperations ?? [])).contains(artifact.key.operationID),
              projectExecutionSpaces[host] != nil,
              project.linkedSpaces.contains(where: { $0.destination == host && $0.spaceID == task.spaceID }),
              project.settings.hostPolicy == .anyConnected || project.settings.allowedHosts.contains(host) else {
            throw LogicalProjectsError("publication_binding", "Original owner, task or authenticated executor binding is unavailable.")
        }
        try validateProjectPlacement(project, host: host, spaceID: task.spaceID)
        return project
    }

    func startPublicationTransfer(_ artifact: ProjectArtifactReceipt) {
        let epoch = logicalProjectEpoch
        guard let project = try? publicationOwner(artifact, epoch: epoch),
              !project.artifacts.contains(where: { $0.id == artifact.id && $0.state != .staged }),
              !publicationTransfers.contains(artifact.id) else { return }
        if publicationTransfers.count == 4 {
            if publicationTransferQueue.count < 128, !publicationTransferQueue.contains(where: { $0.id == artifact.id }) {
                publicationTransferQueue.append(artifact)
            }
            return
        }
        publicationTransfers.insert(artifact.id)
        Task {
            defer {
                self.queue.async {
                    self.publicationTransfers.remove(artifact.id)
                    while self.publicationTransfers.count < 4, !self.publicationTransferQueue.isEmpty {
                        self.startPublicationTransfer(self.publicationTransferQueue.removeFirst())
                    }
                }
            }
            do { try await self.transferPublication(artifact, epoch: epoch) }
            catch {
                // Definite refusal is public and terminal; transport uncertainty stays staged.
                // Reconnect may reconcile produced bytes but never reissues a model operation.
                guard let code = (error as? LogicalProjectsError)?.code,
                      ["artifact_collision", "publication_corrupt", "publication_conflict", "publication_capacity"].contains(code) else { return }
                _ = try? await self.updateRuntimeProject(artifact.key.projectID, expectedEpoch: epoch) { project in
                    guard let index = project.artifacts.firstIndex(where: { $0.id == artifact.id && $0.state == .staged }) else { return }
                    project.artifacts[index].state = .refused
                    project.artifacts[index].refusal = code
                }
            }
        }
    }

    private func transferPublication(_ artifact: ProjectArtifactReceipt, epoch: UInt64) async throws {
        try artifact.validate()
        let (url, run, deadline) = try await enqueue { () -> (URL, Date?, Date) in
            let project = try self.publicationOwner(artifact, epoch: epoch)
            return (self.store.url, self.projectRunStarts[project.id], Date().addingTimeInterval(self.publicationTransferDuration))
        }
        let revalidate: @Sendable () throws -> Void = {
            guard Date() < deadline else { throw LogicalProjectsError("publication_timeout", "Owner transfer deadline exceeded.") }
            let project = try self.publicationOwner(artifact, epoch: epoch)
            guard self.projectRunStarts[project.id] == run else {
                throw LogicalProjectsError("publication_paused", "Owner run changed during transfer; staged bytes remain retained.")
            }
        }
        _ = try await updateRuntimeProject(artifact.key.projectID, expectedEpoch: epoch, revalidate: revalidate) { project in
            _ = try self.publicationOwner(artifact, epoch: epoch)
            if let previous = project.artifacts.first(where: { $0.id == artifact.id }) {
                var staged = previous; staged.state = .staged
                guard staged == artifact else { throw LogicalProjectsError("publication_conflict", "Immutable owner receipt changed.") }
            } else { project.artifacts.append(artifact) }
            try ProjectArtifactReceipt.validateCollection(project.artifacts)
        }
        let retained = try await publicationIO { try ProjectPublicationFiles.retained(artifact.id, beside: url) }
        if let retained {
            guard retained == artifact else { throw LogicalProjectsError("publication_conflict", "Private snapshot identity changed.") }
        } else {
            var bytes = Data()
            while bytes.count < artifact.size {
                guard Date() < deadline else { throw LogicalProjectsError("publication_timeout", "Owner transfer deadline exceeded; staged bytes remain on the executor.") }
                let offset = Int64(bytes.count)
                let result: ProjectExecutionResult = try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        do {
                            try revalidate()
                            guard let transport = self.onProjectPlacement, let host = artifact.executor else { throw LogicalProjectsError("publication_binding", "Placement transport unavailable.") }
                            var finished = false // accessed only on the state queue
                            self.queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) {
                                guard !finished else { return }; finished = true
                                continuation.resume(throwing: LogicalProjectsError("publication_timeout", "Owner transfer deadline exceeded."))
                            }
                            self.hopToMain {
                                transport(host, .publicationRead(key: artifact.key, publicationID: artifact.id, offset: offset)) { result in
                                    self.queue.async {
                                        guard !finished else { return }; finished = true
                                        continuation.resume(with: result)
                                    }
                                }
                            }
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                var remote = artifact; remote.executor = nil
                guard result.receipt.key == artifact.key, result.receipt.publications?.contains(remote) == true,
                      let chunk = result.publication, chunk.publicationID == artifact.id, chunk.offset == offset,
                      !chunk.data.isEmpty, chunk.data.count <= ProjectArtifactReceipt.chunkBytes,
                      Int64(chunk.data.count) <= artifact.size - offset else {
                    throw LogicalProjectsError("publication_corrupt", "Executor returned mismatched publication metadata or an invalid chunk.")
                }
                bytes.append(chunk.data)
            }
            let snapshot = bytes
            try await publicationIO { try ProjectPublicationFiles.stage(snapshot, receipt: artifact, beside: url) }
        }
        try await commitPublication(artifact, beside: url, revalidate: revalidate)
        var ready = artifact; ready.state = .ready
        let committed = ready
        _ = try await updateRuntimeProject(artifact.key.projectID, expectedEpoch: epoch, revalidate: revalidate) { project in
            _ = try self.publicationOwner(artifact, epoch: epoch)
            guard let index = project.artifacts.firstIndex(where: { $0.id == artifact.id }) else { throw LogicalProjectsError("publication_conflict", "Owner staging receipt disappeared.") }
            project.artifacts[index] = committed
        }
    }
}
