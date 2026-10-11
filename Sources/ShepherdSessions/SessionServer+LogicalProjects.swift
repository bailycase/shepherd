import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Host-owned configuration; Pause/Resume delegates to the installed owner runtime.
    public func logicalProjects(_ request: LogicalProjectsRequest) async throws -> LogicalProjectsResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.logicalProjectsOnQueue(request) { continuation.resume(with: $0) }
            }
        }
    }

    func logicalProjectsOnQueue(_ request: LogicalProjectsRequest,
                                completion: @escaping @Sendable (Result<LogicalProjectsResult, Error>) -> Void) {
        do {
            try requireStarted()
            try requireProjectsEnabled()
            if let id = request.projectID, !Project.validID(id.rawValue) {
                throw LogicalProjectsError("invalid_project", "Project ID must be a canonical lowercase UUID.")
            }
            if case .list = request { completion(.success(.projects(store.state.projects))); return }
            let existing = store.state.projects.first { $0.id == request.projectID }
            if case .create(let id, let name, let goal, let spaceIDs) = request {
                // Identity, not the mutable name, makes a retry idempotent (also after edits).
                if let existing { completion(.success(.project(existing))); return }
                guard !logicalProjectCreates.contains(id) else {
                    throw LogicalProjectsError("project_busy", "This project is being created. Retry with the same ID.")
                }
                guard store.state.projects.count + logicalProjectCreates.count < Project.maximumCount else {
                    throw LogicalProjectsError("project_limit", "Workspace exceeds 32 logical projects.")
                }
                let now = Date().timeIntervalSince1970 * 1_000
                let project = Project(id: id, name: name, goal: goal,
                                      linkedSpaces: spaceIDs.map { ProjectSpaceLink(spaceID: $0, linkedAt: now) })
                try validateLogicalProject(project, replacing: nil)
                try validateLocalProjectSpaces(spaceIDs)
                logicalProjectCreates.insert(id)
                let stateURL = store.url, epoch = logicalProjectEpoch, generation = projectsGeneration
                logicalProjectFiles.async {
                    let staged = Result { try LogicalProjectDirectory.create(id: id, beside: stateURL) }
                    self.queue.async {
                        do {
                            try staged.get()
                            try self.requireStarted()
                            try self.requireProjectsEnabled()
                            guard self.logicalProjectEpoch == epoch, self.projectsGeneration == generation else {
                                throw LogicalProjectsError("conflict", "Host restarted during project creation. The directory was retained.")
                            }
                            // The rest of the workspace may have changed while disk I/O ran.
                            guard !self.store.state.projects.contains(where: { $0.id == id }) else {
                                throw LogicalProjectsError("conflict", "Project identity changed during creation.")
                            }
                            try self.validateLogicalProject(project, replacing: nil)
                            try self.validateLocalProjectSpaces(spaceIDs)
                            self.saveLogicalProjects(self.store.state.projects + [project], request: request,
                                                     result: .project(project)) { result in
                                self.logicalProjectCreates.remove(id)
                                completion(result)
                            }
                        } catch let error as ProjectValidationError {
                            self.logicalProjectCreates.remove(id)
                            completion(.failure(LogicalProjectsError("invalid_project", error.description)))
                        } catch {
                            self.logicalProjectCreates.remove(id)
                            completion(.failure(error))
                        }
                    }
                }
                return
            }
            guard var project = existing else {
                throw LogicalProjectsError("no_such_project", "Project no longer exists on this host.")
            }
            if case .get = request { completion(.success(.project(project))); return }
            if request.requiresProjectFiles {
                guard logicalProjectReadCount < 8 else { throw LogicalProjectsError("project_busy", "Too many artifact reads are pending.") }
                logicalProjectReadCount += 1
                let epoch = logicalProjectEpoch, stateURL = store.url, captured = project
                logicalProjectFiles.async {
                    let result = Result<LogicalProjectsResult, Error> {
                        switch request {
                        case .files(let id, let path): try LogicalProjectDirectory.files(id: id, path: path, beside: stateURL, receipts: captured.artifacts)
                        case .read(let id, let path): try LogicalProjectDirectory.read(id: id, path: path, beside: stateURL)
                        default: preconditionFailure("Artifact request required")
                        }
                    }
                    self.queue.async {
                        self.logicalProjectReadCount -= 1
                        do {
                            try self.requireStarted()
                            guard self.logicalProjectEpoch == epoch else { throw LogicalProjectsError("conflict", "Host restarted during artifact read.") }
                            guard let current = self.store.state.projects.first(where: { $0.id == captured.id }) else {
                                throw LogicalProjectsError("no_such_project", "Project no longer exists on this host.")
                            }
                            guard current == captured else { throw LogicalProjectsError("stale_project", "Project changed during artifact read. Refresh and retry.") }
                            completion(.success(try result.get()))
                        } catch { completion(.failure(error)) }
                    }
                }
                return
            }
            if case .setPaused(_, let revision, let paused) = request, onProjectRuntimeLaunch != nil,
               project.coordinatorAgentID != nil || !project.tasks.isEmpty || !project.messages.isEmpty {
                let id = project.id
                Task {
                    let result: Result<LogicalProjectsResult, Error>
                    do { result = .success(.project(try await self.projectRuntime(id, expectedRevision: revision, request: paused ? .pause : .resume))) }
                    catch { result = .failure(error) }
                    self.queue.async { completion(result) }
                }
                return
            }
            guard request.expectedRevision == project.revision else {
                throw LogicalProjectsError("stale_project", "Project changed. Refresh before trying again.")
            }
            guard project.revision < UInt64.max - 1 else {
                throw LogicalProjectsError("invalid_project", "Project revision exhausted.")
            }
            let now = Date().timeIntervalSince1970 * 1_000
            var automations: [Automation]?
            switch request {
            case .automation(_, _, let id, let action):
                var candidate = store.state
                try applyProjectAutomation(action, id: id, projectID: project.id, to: &candidate)
                automations = candidate.automations
            case .edit(_, _, let name, let goal):
                project.name = name
                project.goal = goal
            case .settings(_, _, let settings):
                guard settings.allowedHosts.allSatisfy({ project.settings.allowedHosts.contains($0) || projectEligibleHosts.contains($0) }) else {
                    throw LogicalProjectsError("invalid_host", "Choose a currently connected host binding configured on the Project owner.")
                }
                project.settings = settings
                if !settings.canRequestSpaceLinks {
                    for i in project.spaceProposals.indices where project.spaceProposals[i].phase == .pending {
                        project.spaceProposals[i].phase = .denied; project.spaceProposals[i].revision += 1
                    }
                }
            case .setPaused(_, _, let paused): project.paused = paused
            case .addMemory(_, _, let id, let text, let source):
                guard !project.memory.contains(where: { $0.id == id }) else {
                    throw LogicalProjectsError("conflict", "Memory ID already exists.")
                }
                project.memory.append(ProjectMemory(id: id, text: text, source: source, createdAt: now))
            case .forgetMemory(_, _, let id):
                guard project.memory.contains(where: { $0.id == id }) else {
                    throw LogicalProjectsError("no_such_memory", "Memory entry no longer exists.")
                }
                project.memory.removeAll { $0.id == id }
            case .linkSpace(_, _, let spaceID, let host):
                let destination = host ?? .local
                try validateProjectDestination(destination, spaceID: spaceID)
                guard !project.linkedSpaces.contains(where: { $0.spaceID == spaceID && $0.destination == destination }) else {
                    throw LogicalProjectsError("conflict", "Space is already linked.")
                }
                project.linkedSpaces.append(ProjectSpaceLink(spaceID: spaceID, linkedAt: now, host: host))
            case .unlinkSpace(_, _, let spaceID, let host):
                guard project.linkedSpaces.contains(where: { $0.spaceID == spaceID && $0.destination == (host ?? .local) }) else {
                    throw LogicalProjectsError("no_such_space", "Space is not linked.")
                }
                project.linkedSpaces.removeAll { $0.spaceID == spaceID && $0.destination == (host ?? .local) }
            case .delete:
                // Revoke native artifact authority before the deletion's off-queue write.
                // A failed delete remains fail-closed; it never reopens the consumed scope.
                projectChildClosed.formUnion(currentProjectChildScope.values.filter {
                    $0.key.projectID == project.id && $0.key.ownerID == project.ownerID
                })
                if project.tasks.contains(where: { $0.executionAssignment != nil && $0.phase.occupiesSlot }) {
                    let id = project.id, revision = project.revision
                    Task {
                        do {
                            let paused = try await self.projectRuntime(id, expectedRevision: revision, request: .pause)
                            self.queue.async {
                                for task in paused.tasks where task.phase.occupiesSlot {
                                    if let assignment = task.executionAssignment { self.requestProjectPlacement(task, request: .cancel(key: assignment.key)) }
                                }
                                completion(.failure(LogicalProjectsError("project_interrupt_pending", "Executor cancellation is pending. The paused Project and its reservation are retained; retry Delete after acknowledgement or reconnect.")))
                            }
                        } catch { self.queue.async { completion(.failure(error)) } }
                    }
                    return
                }
                // A soft reference alone is not ownership: only a reciprocal coordinator
                // marker authorizes removing an agent. Ordinary workers and files survive.
                saveLogicalProjects(store.state.projects.filter { $0.id != project.id }, request: request,
                                    result: .deleted(projectID: project.id), completion: completion)
                return
            case .list, .get, .create, .files, .read: preconditionFailure("Handled above")
            }
            project.revision += 1
            try validateLogicalProject(project, replacing: project.id)
            let projects = store.state.projects.map { $0.id == project.id ? project : $0 }
            saveLogicalProjects(projects, automations: automations, request: request, result: .project(project), completion: completion)
        } catch let error as ProjectValidationError {
            completion(.failure(LogicalProjectsError("invalid_project", error.description)))
        } catch let error as AutomationDraftError {
            completion(.failure(LogicalProjectsError(error.code, error.message)))
        } catch { completion(.failure(error)) }
    }

    private func saveLogicalProjects(_ projects: [Project], automations: [Automation]? = nil, request: LogicalProjectsRequest,
                                     result: LogicalProjectsResult,
                                     completion: @escaping @Sendable (Result<LogicalProjectsResult, Error>) -> Void) {
        guard logicalProjectSaveCount < 8 else {
            completion(.failure(LogicalProjectsError("project_busy", "Too many project saves are pending. Retry after they finish.")))
            return
        }
        logicalProjectSaveCount += 1
        let before = store.state, version = store.version, epoch = logicalProjectEpoch, generation = projectsGeneration, url = store.url
        var candidate = before
        candidate.projects = projects
        if let automations { candidate.automations = automations }
        Self.reconcileProjectAutomations(&candidate, before: before)
        for removed in before.projects where !projects.contains(where: { $0.id == removed.id }) {
            if let coordinator = before.agents.first(where: { $0.id == removed.coordinatorAgentID && $0.coordinatorFor == removed.id }) {
                candidate.agents.removeAll { $0.id == coordinator.id }
                candidate.tabs.removeAll { $0.id == coordinator.tabID || $0.inspectorFor == coordinator.id }
                candidate.automations.removeAll { $0.agentID == coordinator.id }
            }
        }
        let snapshot = candidate
        logicalProjectFiles.async {
            let staged = Result { try StateStore.stageLogicalProjects(snapshot, at: url) }
            self.queue.async {
                self.logicalProjectSaveCount -= 1
                do {
                    let file = try staged.get()
                    defer { self.logicalProjectFiles.async { _ = unlink(file.path) } }
                    try self.requireStarted()
                    try self.requireProjectsEnabled()
                    guard self.logicalProjectEpoch == epoch, self.projectsGeneration == generation, !self.projectFolderOperation else {
                        throw LogicalProjectsError("workspace_changed", "Host restarted or a Space folder operation is in progress. Refresh and retry.")
                    }
                    if let expected = request.expectedRevision {
                        guard self.store.state.projects.first(where: { $0.id == request.projectID })?.revision == expected else {
                            throw LogicalProjectsError("stale_project", "Project changed. Refresh before trying again.")
                        }
                    }
                    if case .automation(_, _, let id, .link) = request, self.automationStarts.contains(id) {
                        throw LogicalProjectsError("conflict", "Stop the automation before linking it to a Project.")
                    }
                    try self.store.commitLogicalProjects(snapshot, version: version, staged: file)
                    self.stateDidCommit(before: before)
                    completion(.success(result))
                } catch let error as ProjectValidationError {
                    completion(.failure(LogicalProjectsError("invalid_project", error.description)))
                } catch { completion(.failure(error)) }
            }
        }
    }

    private func validateLocalProjectSpaces(_ ids: [SpaceID]) throws {
        guard ids.allSatisfy({ id in
            Project.validID(id.rawValue) && store.state.spaces.contains { $0.id == id && !$0.hidden }
        }) else {
            throw LogicalProjectsError("no_such_space", "Choose an existing visible Space on the Project owner.")
        }
    }

    private func validateLogicalProject(_ project: Project, replacing id: ProjectID?) throws {
        var candidate = store.state
        candidate.projects.removeAll { $0.id == id }
        candidate.projects.append(project)
        try candidate.validate()
    }
}
