import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension SessionServer {
    /// Pure queue-owned mutations, off-queue validation/encoding/write, atomic version-fenced
    /// publication. Workspace-only churn is rebased; a caller's Project revision is never rebased.
    func updateRuntimeProject(_ id: ProjectID, expectedRevision: UInt64? = nil, expectedEpoch: UInt64? = nil,
                              workspace: (@Sendable (inout ShepherdState) throws -> Void)? = nil,
                              revalidate: (@Sendable () throws -> Void)? = nil,
                              change: @escaping @Sendable (inout Project) throws -> Void) async throws -> Project {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if !self.projectRuntimeWriterBusy {
                    self.projectRuntimeWriterBusy = true; continuation.resume()
                } else if self.projectRuntimeWriters.count < 32 {
                    self.projectRuntimeWriters.append(continuation)
                } else { continuation.resume(throwing: LogicalProjectsError("project_busy", "Project write backlog is full.")) }
            }
        }
        defer {
            queue.async {
                if self.projectRuntimeWriters.isEmpty { self.projectRuntimeWriterBusy = false }
                else { self.projectRuntimeWriters.removeFirst().resume() }
            }
        }
        for attempt in 0..<8 {
            let staged = try await enqueue { () -> (ShepherdState, UInt64, UInt64, URL, Project) in
                try self.requireStarted()
                guard expectedEpoch == nil || expectedEpoch == self.logicalProjectEpoch else { throw LogicalProjectsError("conflict", "Project owner restarted.") }
                guard self.logicalProjectSaveCount < 8, !self.projectFolderOperation else {
                    throw LogicalProjectsError("project_busy", "Project storage is busy. Retry with the same operation identity.")
                }
                guard let index = self.store.state.projects.firstIndex(where: { $0.id == id }) else {
                    throw LogicalProjectsError("no_such_project", "Project no longer exists.")
                }
                let before = self.store.state.projects[index]
                guard expectedRevision == nil || before.revision == expectedRevision else {
                    throw LogicalProjectsError("stale_project", "Refresh the Project before trying again.")
                }
                var project = before
                try change(&project)
                if project != before { project.revision += 1 }
                var candidate = self.store.state
                try workspace?(&candidate)
                candidate.projects[index] = project
                Self.reconcileProjectAutomations(&candidate, before: self.store.state)
                self.logicalProjectSaveCount += 1
                return (candidate, self.store.version, self.logicalProjectEpoch, self.store.url, project)
            }
            let file: Result<URL, Error> = await withCheckedContinuation { continuation in
                logicalProjectFiles.async { continuation.resume(returning: Result { try StateStore.stageLogicalProjects(staged.0, at: staged.3) }) }
            }
            do {
                return try await enqueue {
                    self.logicalProjectSaveCount -= 1
                    let url = try file.get()
                    defer { self.logicalProjectFiles.async { _ = unlink(url.path) } }
                    try self.requireStarted()
                    guard self.logicalProjectEpoch == staged.2 else { throw LogicalProjectsError("conflict", "Project owner restarted.") }
                    guard !self.projectFolderOperation else { throw LogicalProjectsError("project_busy", "A Space folder operation is in progress.") }
                    try revalidate?()
                    let before = self.store.state
                    try self.store.commitLogicalProjects(staged.0, version: staged.1, staged: url)
                    self.stateDidCommit(before: before)
                    return staged.4
                }
            } catch let error as LogicalProjectsError where error.code == "workspace_changed" && attempt < 7 {
                continue
            }
        }
        throw LogicalProjectsError("project_busy", "Workspace keeps changing; retry with the same operation identity.")
    }

    func runtimeFailure(_ id: ProjectID, _ error: Error) {
        if (error as? LogicalProjectsError)?.code == "project_paused" {
            if let project = store.state.projects.first(where: { $0.id == id }) {
                if project.paused { finishProjectInterruption(id) } else { pumpProject(id) }
            }
            return
        }
        guard (try? requireStarted()) != nil, store.state.projects.contains(where: { $0.id == id }),
              projectPersistenceFailed.insert(id).inserted else { return }
        ShepherdLog.error("Project runtime stopped: \(error)")
        projectRunStarts[id] = nil
        projectActivations[id] = nil
        projectAnswersInFlight.subtract(store.state.projects.first(where: { $0.id == id })?.tasks.map(\.id) ?? [])
        interruptProject(id)
        let epoch = logicalProjectEpoch
        Task { _ = try? await updateRuntimeProject(id, expectedEpoch: epoch) { $0.paused = true; $0.interruptPending = true } }
    }
}
