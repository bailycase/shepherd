import Foundation
import os
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension SessionServer {
    static let maximumStateWrites = 8
    static let maximumStateWriteAttempts = 8
    enum MetadataKind: Equatable { case failure, session, name }
    struct MetadataMutation {
        var agent: AgentID
        var kind: MetadataKind
        var epoch: UInt64
        var mutate: @Sendable (inout ShepherdState) throws -> Void
        var completed: () -> Void
    }

    /// At most one deferred intent per field per live owner, not a second write queue. Once a
    /// FIFO slot opens it uses exactly the same version-fenced writer as an awaited UI mutation.
    func scheduleMetadataMutation(agent: AgentID, kind: MetadataKind,
                                  _ mutate: @escaping @Sendable (inout ShepherdState) throws -> Void,
                                  completed: @escaping () -> Void = {}) {
        guard store.state.agents.contains(where: { $0.id == agent }) else { return }
        pendingMetadata.removeAll { $0.agent == agent && $0.kind == kind }
        pendingMetadata.append(.init(agent: agent, kind: kind, epoch: logicalProjectEpoch, mutate: mutate, completed: completed))
        drainMetadataMutations()
    }

    func drainMetadataMutations() {
        let live = Set(store.state.agents.map(\.id))
        let obsolete = pendingMetadata.filter { !live.contains($0.agent) || $0.epoch != logicalProjectEpoch }
        pendingMetadata.removeAll { !live.contains($0.agent) || $0.epoch != logicalProjectEpoch }
        obsolete.forEach { $0.completed() }
        failureIntents = failureIntents.filter { live.contains($0.key) }
        while stateWritesInFlight < Self.maximumStateWrites, !pendingMetadata.isEmpty {
            let pending = pendingMetadata.removeFirst()
            scheduleStateMutation(pending.mutate) { result in
                if case .failure(let error) = result {
                    ShepherdLog.warning("Could not persist agent metadata: \(error)")
                }
                pending.completed()
            }
        }
    }

    static let storageSignposter = OSSignposter(subsystem: "com.shepherd.app", category: "Storage")

    /// Guarded mutations stage on the file queue, in arrival order. Preparation has no effects
    /// and finds indices in current state. Commit effects run on the server queue before ack.
    func mutateStateOffQueue(_ mutate: @escaping @Sendable (inout ShepherdState) throws -> Void,
                            didCommit: @escaping (ShepherdState) -> Void = { _ in }) async throws {
        let progress = Progress(totalUnitCount: 1)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.scheduleStateMutation(mutate, cancelled: { progress.isCancelled }, didCommit: didCommit) { continuation.resume(with: $0) }
                }
            }
        } onCancel: { progress.cancel() }
    }

    /// Server-queue callers join the same bounded FIFO without spawning unordered admission tasks.
    func scheduleStateMutation(_ mutate: @escaping @Sendable (inout ShepherdState) throws -> Void,
                               cancelled: @escaping @Sendable () -> Bool = { false },
                               didCommit: @escaping (ShepherdState) -> Void = { _ in },
                               completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try requireStarted()
            guard stateWritesInFlight < Self.maximumStateWrites else {
                throw SessionServerError.persistFailed("Too many pending workspace saves. Retry shortly.")
            }
            let epoch = logicalProjectEpoch
            stateWriteQueue.append {
                Task {
                    let result: Result<Void, Error>
                    do {
                        try await self.performStateWrite(epoch: epoch, mutate: mutate, cancelled: cancelled, didCommit: didCommit)
                        result = .success(())
                    } catch { result = .failure(error) }
                    self.queue.async {
                        completion(result)
                        self.stateWriteQueue.removeFirst()
                        self.stateWriteQueue.first?()
                        self.drainMetadataMutations()
                    }
                }
            }
            if stateWriteQueue.count == 1 { stateWriteQueue[0]() }
        } catch { completion(.failure(error)) }
    }

    private func performStateWrite(epoch: UInt64,
                                   mutate: @escaping @Sendable (inout ShepherdState) throws -> Void,
                                   cancelled: @escaping @Sendable () -> Bool,
                                   didCommit: @escaping (ShepherdState) -> Void) async throws {
        for _ in 0..<Self.maximumStateWriteAttempts {
            try Task.checkCancellation()
            let preparation = try await enqueue { () -> (ShepherdState, ShepherdState, UInt64, URL)? in
                if cancelled() { throw CancellationError() }
                try self.requireStarted()
                guard self.logicalProjectEpoch == epoch else { throw SessionServerError.persistFailed("Workspace restarted while saving.") }
                guard !self.projectFolderOperation else { throw ProjectFileError("project_busy", "A project folder operation is in progress. Retry after it completes.") }
                let before = self.store.state
                var candidate = before
                try mutate(&candidate)
                Self.reconcileProjectAutomations(&candidate, before: before)
                guard candidate != before else { return nil }
                let version = self.store.version
                self.stateWritePrepared?()
                return (before, candidate, version, self.store.url)
            }
            guard let (before, candidate, version, url) = preparation else { return }
            let staged: StateStore.LogicalProjectsStage
            do {
                staged = try await withCheckedThrowingContinuation { continuation in
                    logicalProjectFiles.async {
                        let phase = Self.storageSignposter.beginInterval("State staging", id: Self.storageSignposter.makeSignpostID())
                        defer { Self.storageSignposter.endInterval("State staging", phase) }
                        do { continuation.resume(returning: try StateStore.stageUpdate(candidate, before: before, at: url)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } catch { throw SessionServerError.persistFailed(String(describing: error)) }
            // Unique staging files are consumed by rename or removed on every failure/conflict.
            defer { _ = unlink(staged.url.path) }
            try Task.checkCancellation()
            let committed = try await enqueue {
                if cancelled() { throw CancellationError() }
                try self.requireStarted()
                guard self.logicalProjectEpoch == epoch else { throw SessionServerError.persistFailed("Workspace restarted while saving.") }
                guard !self.projectFolderOperation else { throw ProjectFileError("project_busy", "A project folder operation is in progress. Retry after it completes.") }
                guard self.store.version == version else { return false }
                do { try self.store.commitLogicalProjects(candidate, version: version, staged: staged) }
                catch { throw SessionServerError.persistFailed(String(describing: error)) }
                self.stateDidCommit(before: before)
                didCommit(before)
                return true
            }
            if committed { return }
        }
        throw SessionServerError.persistFailed("Workspace kept changing while saving. Retry shortly.")
    }
}
