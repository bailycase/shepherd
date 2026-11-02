import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    static let maximumStateWrites = 8
    static let maximumStateWriteAttempts = 8

    /// Guarded UI mutations stage their JSON on the file queue. A conflicting live or durable
    /// update reruns preparation against current state; no candidate is published before rename.
    /// Preparation must have no effects and must find indices in the state passed to it.
    func mutateStateOffQueue(_ mutate: @escaping @Sendable (inout ShepherdState) throws -> Void) async throws {
        let epoch: UInt64 = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.requireStarted()
                    guard self.stateWritesInFlight < Self.maximumStateWrites else {
                        throw SessionServerError.persistFailed("Too many pending workspace saves. Retry shortly.")
                    }
                    let epoch = self.logicalProjectEpoch
                    self.stateWriteQueue.append { continuation.resume(returning: epoch) }
                    if self.stateWriteQueue.count == 1 { self.stateWriteQueue[0]() }
                } catch { continuation.resume(throwing: error) }
            }
        }
        // Retrying an earlier UI edit must never overwrite a later edit to the same field.
        defer {
            queue.async {
                self.stateWriteQueue.removeFirst()
                self.stateWriteQueue.first?()
            }
        }
        for _ in 0..<Self.maximumStateWriteAttempts {
            try Task.checkCancellation()
            let preparation = try await enqueue { () -> (ShepherdState, ShepherdState, UInt64, URL)? in
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
                        do { continuation.resume(returning: try StateStore.stageUpdate(candidate, before: before, at: url)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } catch { throw SessionServerError.persistFailed(String(describing: error)) }
            // A unique staging file is never shared with another operation. Rename consumes it
            // on success; cancellation, conflict and errors must also remove it.
            defer { _ = unlink(staged.url.path) }
            try Task.checkCancellation()
            let committed = try await enqueue {
                try self.requireStarted()
                guard self.logicalProjectEpoch == epoch else { throw SessionServerError.persistFailed("Workspace restarted while saving.") }
                guard !self.projectFolderOperation else { throw ProjectFileError("project_busy", "A project folder operation is in progress. Retry after it completes.") }
                guard self.store.version == version else { return false }
                do { try self.store.commitLogicalProjects(candidate, version: version, staged: staged) }
                catch { throw SessionServerError.persistFailed(String(describing: error)) }
                self.stateDidCommit(before: before)
                return true
            }
            if committed { return }
        }
        throw SessionServerError.persistFailed("Workspace kept changing while saving. Retry shortly.")
    }
}
