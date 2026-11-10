import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The owner's existing ordinary session launcher, not a second scheduler or transcript store.
/// Project selection alone never creates or resumes a conversation.
@MainActor
final class ProjectCoordinatorController {
    private let hosting: RuntimeHosting
    private var server: SessionServer { hosting.server }
    init(hosting: RuntimeHosting) { self.hosting = hosting }

    func ensureProjectConversation(projectID: ProjectID, expectedRevision: UInt64) async throws -> AgentID {
        let project = try await server.projectRuntime(projectID, expectedRevision: expectedRevision, request: .conversation)
        guard let id = project.coordinatorAgentID else {
            throw AgentStartFailure(message: "Send the first Project message to create its conversation.")
        }
        return id
    }

    @discardableResult
    func sendProjectMessage(projectID: ProjectID, expectedRevision: UInt64, operationID: UUID, text: String) async throws -> Project {
        return try await server.projectRuntime(projectID, expectedRevision: expectedRevision,
                                                  request: .message(operationID: operationID, text: text))
    }

    @discardableResult
    func perform(projectID: ProjectID, expectedRevision: UInt64, request: ProjectRuntimeRequest) async throws -> Project {
        return try await server.projectRuntime(projectID, expectedRevision: expectedRevision, request: request)
    }

    func perform(_ request: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult {
        guard hosting.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        switch request {
        case .hosts:
            return .hosts([.init(reference: .local, name: Host.current().localizedName ?? "This Mac", spaces: server.state.spaces.filter { !$0.hidden })]
                + (await hosting.executors.hosts()))
        case .action(let id, let revision, let action): return .project(try await perform(projectID: id, expectedRevision: revision, request: action))
        case .conversation(let id, let request): return .native(try await server.projectConversation(id, request: request))
        case .worker(let id, let task, let request): return .native(try await worker(projectID: id, taskID: task, request: request))
        case .answer(let id, let revision, let task, let request): return .native(try await server.answerProjectQuestion(id, expectedRevision: revision, taskID: task, request: request))
        }
    }

    /// A viewer addresses the owning Project, never a viewer-local host or caller-supplied worker ID.
    /// The ordinary native store keeps its existing bounded snapshot polling and mutation fences.
    func worker(projectID: ProjectID, taskID: ProjectTaskID, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let project = server.state.projects.first(where: { $0.id == projectID }) else {
            throw LogicalProjectsError("not_found", "The Project or its thread is no longer available.")
        }
        let grant = try await server.projectWorkerReadGrant(projectID)
        let routed = try await server.projectRuntime(projectID, expectedRevision: project.revision, request: .worker(taskID: taskID))
        guard let task = routed.tasks.first(where: { $0.id == taskID }) else { throw LogicalProjectsError("not_found", "Worker route is unavailable.") }
        let archived = !project.tasks.contains(where: { $0.id == taskID })
        var request = request
        if archived {
            switch request {
            case .snapshot(let expected, let before, let revision):
                guard expected == nil || expected == task.workerSessionID else { throw LogicalProjectsError("stale_execution", "Archived worker session changed.") }
                request = .snapshot(expectedSessionID: task.workerSessionID, beforeEntryID: before, afterRevision: revision)
            case .image, .subagentTranscript: break
            default: throw LogicalProjectsError("project_scope", "Archived worker access is read-only; it never reactivates a task.")
            }
        }
        // Once the managed activation has ended, this is an ordinary thread. Its manual
        // questions must not be checked against the old Project delivery receipt.
        if case .answer(let session, let generation, _, _, _) = request, task.phase.occupiesSlot {
            var takenOver = false
            switch task.destination {
            case .local:
                takenOver = (try? await server.projectWorkerWasTakenOver(projectID, taskID: taskID,
                    sessionID: session, generation: generation)) == true
            case .remote:
                if let assignment = task.executionAssignment,
                   // This is the owner's shared receipt connection: watch:false would unsubscribe
                   // its placement reconciler before the answered question can settle.
                   let latest = try? await place(host: task.destination, request: .snapshot(key: assignment.key, watch: true)) {
                    takenOver = latest.workerTakenOver == true && latest.receipt.key == assignment.key
                        && latest.receipt.assignment?.reservedWorkerID == task.workerAgentID
                        && latest.receipt.sessionID == session && latest.receipt.generation == generation
                }
            }
            if !takenOver {
                return try await server.answerProjectQuestion(projectID, expectedRevision: project.revision, taskID: taskID, request: request)
            }
        }
        guard task.workerSessionID != nil else {
            return .failure(code: task.phase == .failed ? NativeThreadCode.unavailable : NativeThreadCode.starting,
                            message: "The executor has not opened this thread yet.")
        }
        switch task.destination {
        case .local:
            let result = try await hosting.nativeThread(task.workerAgentID, request)
            _ = try await server.projectRuntime(projectID, expectedRevision: routed.revision, request: .worker(taskID: taskID))
            try await server.validateProjectWorkerRead(projectID, grant: grant, task: task)
            return result
        case .remote:
            let result = try await hosting.executors.workerThread(task.destination, task.workerAgentID, request)
            _ = try await server.projectRuntime(projectID, expectedRevision: routed.revision, request: .worker(taskID: taskID))
            try await server.validateProjectWorkerRead(projectID, grant: grant, task: task)
            return result
        }
    }

    func place(host: ProjectHostReference, request: ProjectExecutionRequest) async throws -> ProjectExecutionResult {
        guard case .remote = host else {
            throw AgentStartFailure(message: "The exact executor binding is unavailable. No fallback host was selected.")
        }
        switch request {
        case .resume, .answer:
            guard server.state.projects.contains(where: { $0.id == request.key.projectID && $0.ownerID == request.key.ownerID && !$0.paused }) else {
                throw LogicalProjectsError("project_paused", "Project paused before the executor control was sent.")
            }
        default: break
        }
        if case .execute(let assignment) = request {
            guard let project = server.state.projects.first(where: { $0.id == request.key.projectID && $0.ownerID == request.key.ownerID }),
                  !project.paused, project.tasks.contains(where: { $0.executionAssignment == assignment && $0.destination == host }),
                  project.settings.hostPolicy == .anyConnected || project.settings.allowedHosts.contains(host),
                  project.linkedSpaces.contains(where: { $0.destination == host && $0.spaceID == assignment.executorSpaceID }) else {
                throw AgentStartFailure(message: "Project placement was revoked or its executor Space is unavailable.")
            }
        }
        try await server.validateProjectPlacementRequest(request)
        // The executor's own checks (its exact binding, the Space still visible there) run where
        // the connection is: here in process, in this Mac's app for a background host.
        return try await hosting.executors.place(host, request)
    }

    func conversationStore(agentID: AgentID) -> NativeThreadStore? { hosting.threadStore(agentID) }

    func launch(_ request: ProjectRuntimeLaunch) async throws -> AgentID {
        guard hosting.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        guard let project = server.state.projects.first(where: { $0.id == request.projectID }), !project.paused else {
            throw AgentStartFailure(message: "Project paused or deleted before launch")
        }
        if let model = request.model, !server.modelListing().models.contains(model) {
            throw AgentStartFailure(message: "Selected model is not available on this owner: \(model)")
        }
        let state = server.state
        if let existing = state.agents.first(where: { $0.id == request.agentID }),
           let tab = state.tabs.first(where: { $0.id == existing.tabID }), let pane = tab.layout.leaves.first {
            // Explicit restoration is idle: the server owns any queued delivery and its identity.
            try await hosting.restartAgent(existing, tab, pane, nil)
            return existing.id
        }
        return try await hosting.startAgent(NewAgentConfig(spaceID: request.spaceID, workingDirectory: request.cwd,
                                                     reservedAgentID: request.agentID,
                                                     coordinatorFor: request.coordinator ? request.projectID : nil,
                                                     // The coordinator's own choice for a task, else the owner's default level.
                                                     model: request.model,
                                                     thinking: request.thinking.flatMap(ThinkingLevel.init(rawValue:)) ?? hosting.settings.agentDefaults.thinking,
                                                     initialPrompt: nil,
                                                     initialName: request.name))
    }
}

extension ProjectCoordinatorController {
    /// Serves the owner's Project runtime on its server: requests, launches, placements, the default
    /// model, and Project-owned automation runs.
    func install() {
        let server = server, settings = hosting.settings, state = hosting.state
        server.onProjectDefaultModel = {
            let values = await MainActor.run { (settings.agentDefaults.model, server.pi.home) }
            if let model = values.0 { return model }
            return await Task.detached { PiConfig.defaultModel(in: values.1) }.value
        }
        server.onProjectPlacement = { [weak self] host, request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.place(host: host, request: request))) }
                catch { completion(.failure(error)) }
            }
        }
        server.onProjectRuntimeRequest = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.perform(request))) }
                catch { completion(.failure(error)) }
            }
        }
        server.onProjectRuntimeLaunch = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.launch(request))) }
                catch { completion(.failure(error)) }
            }
        }
        // Project-owned runs become Project tasks through the Project runtime's own `assign`, which
        // reserves the task in the Project's ledger under its threads-at-once, time and pause rules
        // and launches its worker; a repeated operation id is the same task, never a second one.
        server.onProjectAutomationRun = { [weak self] projectID, revision, automationID, title, prompt, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(AgentStartFailure(message: "Owner closed"))) }
                do {
                    let state = state()
                    guard let automation = state.automations.first(where: { $0.id == automationID }),
                          let project = state.projects.first(where: { $0.id == projectID }),
                          let space = state.projectRunSpace(project, cwd: automation.cwd) else {
                        throw LogicalProjectsError("no_such_space", "Link the automation's folder to the Project first.")
                    }
                    let operation = UUID()
                    let updated = try await self.perform(
                        projectID: projectID, expectedRevision: revision,
                        request: .assign(operationID: operation, spaceID: space, title: title, prompt: prompt,
                                         model: automation.model, thinking: automation.thinking?.rawValue))
                    guard let task = updated.tasks.first(where: { $0.operationID == operation }) else {
                        throw LogicalProjectsError("conflict", "The Project didn't keep the run's task.")
                    }
                    completion(.success(task.id))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }
}

extension RemoteHostStore {
    /// The connected paired hosts, with their visible Spaces when they take Project placements.
    var projectHostOptions: [ProjectHostOption] {
        pairedConnections.filter { $0.phase == .connected }.map {
            let capable = $0.browserClient?.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability]) == true
            return ProjectHostOption(reference: .remote(hostID: $0.config.id, bindingID: $0.config.bindingID), name: $0.config.name,
                                     spaces: capable ? $0.state.spaces.filter { !$0.hidden } : nil)
        }
    }

    /// The paired hosts that may run a Project's work, each reached only by its exact host id and
    /// binding: the app's own Projects in process, and its background host's through the app.
    var projectExecutors: RuntimeHosting.ProjectExecutors {
        func capable(_ connection: Connection) -> RemoteHostClient? {
            guard let client = connection.browserClient,
                  client.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability])
            else { return nil }
            return client
        }
        func exact(_ host: ProjectHostReference) -> Connection? {
            guard case .remote(let hostID, let bindingID) = host else { return nil }
            return pairedConnections.first { $0.id == hostID && $0.config.bindingID == bindingID }
        }
        return RuntimeHosting.ProjectExecutors(
            hosts: { [weak self] in self?.projectHostOptions ?? [] },
            place: { host, request in
                guard let connection = exact(host), let client = capable(connection) else {
                    throw AgentStartFailure(message: "The exact executor binding is unavailable. No fallback host was selected.")
                }
                if case .execute(let assignment) = request,
                   !connection.state.spaces.contains(where: { $0.id == assignment.executorSpaceID && !$0.hidden }) {
                    throw AgentStartFailure(message: "Project placement was revoked or its executor Space is unavailable.")
                }
                return try await client.projectExecution(request)
            },
            workerThread: { host, agentID, request in
                guard let connection = exact(host), connection.phase == .connected, let client = capable(connection) else {
                    throw LogicalProjectsError("executor_unavailable", "The thread's exact executor binding is unavailable. No fallback host was selected.")
                }
                do { return try await client.nativeThread(agentID: agentID, request: request) }
                catch RemoteHostClientError.outcomeUnknown(let message) { throw LogicalProjectsError("outcome_unknown", message) }
                catch RemoteHostClientError.rejected(let code, let message) { throw LogicalProjectsError(code, message) }
            })
    }
}

extension ShepherdViewModel {
    /// The paired hosts a Project may place work on: the in-process server's, or, as the
    /// background host's client, the host's (`projectExecutors`), sent when they change.
    func refreshProjectHosts() {
        let options = remoteHosts.projectHostOptions
        guard let host = localHost else {
            server.setProjectEligibleHosts([.local] + options.map(\.reference))
            server.setProjectExecutionSpaces(Dictionary(options.compactMap { option in option.spaces.map { (option.reference, $0) } },
                                                        uniquingKeysWith: { first, _ in first }))
            return
        }
        guard host.phase == .connected, let client = host.browserClient else { return }
        let sent = (ObjectIdentifier(client), options)
        guard sentProjectHosts.map({ $0.0 != sent.0 || $0.1 != sent.1 }) ?? true else { return }
        sentProjectHosts = sent
        Task { [weak self] in
            do { try await client.projectExecutors(.hosts(options)) } catch { self?.sentProjectHosts = nil }
        }
    }

    func installProjectRuntime() {
        refreshProjectHosts()
        remoteHosts.onProjectExecutionChanged = { [weak self] host, key in
            self?.projectExecutionChanged(host, key: key)
        }
        remoteHosts.onProjectExecutorConnected = { [weak self] host in
            self?.refreshProjectHosts()
            self?.projectExecutionChanged(host, key: nil)
        }
    }

    /// A paired host's execution changed, or it connected again: its receipts are read again by
    /// whoever owns this Mac's Projects.
    private func projectExecutionChanged(_ host: ProjectHostReference, key: ProjectExecutionKey?) {
        guard let local = localHost else { return server.reconcileProjectExecutions(host: host, key: key) }
        guard case .remote(let hostID, _) = host, hostID != local.id, let client = local.browserClient else { return }
        Task { try? await client.projectExecutors(.changed(host: host, key: key)) }
    }
}
