import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The owner's existing ordinary session launcher, not a second scheduler or transcript store.
/// Project selection alone never creates or resumes a conversation.
@MainActor
final class ProjectCoordinatorController {
    private weak var vm: ShepherdViewModel?
    init(vm: ShepherdViewModel) { self.vm = vm }

    func ensureProjectConversation(projectID: ProjectID, expectedRevision: UInt64) async throws -> AgentID {
        guard let vm else { throw AgentStartFailure(message: "Owner closed") }
        let project = try await vm.server.projectRuntime(projectID, expectedRevision: expectedRevision, request: .conversation)
        guard let id = project.coordinatorAgentID else {
            throw AgentStartFailure(message: "Send the first Project message to create its conversation.")
        }
        return id
    }

    @discardableResult
    func sendProjectMessage(projectID: ProjectID, expectedRevision: UInt64, operationID: UUID, text: String) async throws -> Project {
        guard let vm else { throw AgentStartFailure(message: "Owner closed") }
        return try await vm.server.projectRuntime(projectID, expectedRevision: expectedRevision,
                                                  request: .message(operationID: operationID, text: text))
    }

    @discardableResult
    func perform(projectID: ProjectID, expectedRevision: UInt64, request: ProjectRuntimeRequest) async throws -> Project {
        guard let vm else { throw AgentStartFailure(message: "Owner closed") }
        return try await vm.server.projectRuntime(projectID, expectedRevision: expectedRevision, request: request)
    }

    func perform(_ request: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult {
        guard let vm else { throw AgentStartFailure(message: "Owner closed") }
        guard vm.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        switch request {
        case .hosts:
            return .hosts([.init(reference: .local, name: Host.current().localizedName ?? "This Mac", spaces: vm.server.state.spaces.filter { !$0.hidden })]
                + vm.remoteHosts.connections.filter { $0.phase == .connected }.map {
                    let capable = $0.browserClient?.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability]) == true
                    return .init(reference: .remote(hostID: $0.config.id, bindingID: $0.config.bindingID), name: $0.config.name,
                                 spaces: capable ? $0.state.spaces.filter { !$0.hidden } : nil)
                })
        case .action(let id, let revision, let action): return .project(try await perform(projectID: id, expectedRevision: revision, request: action))
        case .conversation(let id, let request): return .native(try await vm.server.projectConversation(id, request: request))
        case .worker(let id, let task, let request): return .native(try await worker(projectID: id, taskID: task, request: request))
        case .answer(let id, let revision, let task, let request): return .native(try await vm.server.answerProjectQuestion(id, expectedRevision: revision, taskID: task, request: request))
        }
    }

    /// A viewer addresses the owning Project, never a viewer-local host or caller-supplied worker ID.
    /// The ordinary native store keeps its existing bounded snapshot polling and mutation fences.
    func worker(projectID: ProjectID, taskID: ProjectTaskID, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let vm, let project = vm.server.state.projects.first(where: { $0.id == projectID }),
              let task = project.tasks.first(where: { $0.id == taskID }) else {
            throw LogicalProjectsError("not_found", "The Project or its thread is no longer available.")
        }
        // Once the managed activation has ended, this is an ordinary thread. Its manual
        // questions must not be checked against the old Project delivery receipt.
        if case .answer(let session, let generation, _, _, _) = request, task.phase.occupiesSlot {
            var takenOver = false
            switch task.destination {
            case .local:
                takenOver = (try? await vm.server.projectWorkerWasTakenOver(projectID, taskID: taskID,
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
                return try await vm.server.answerProjectQuestion(projectID, expectedRevision: project.revision, taskID: taskID, request: request)
            }
        }
        guard task.workerSessionID != nil else {
            return .failure(code: task.phase == .failed ? NativeThreadCode.unavailable : NativeThreadCode.starting,
                            message: "The executor has not opened this thread yet.")
        }
        switch task.destination {
        case .local:
            return try await vm.server.nativeThread(agentID: task.workerAgentID, request: request)
        case .remote(let hostID, let bindingID):
            guard let connection = vm.remoteHosts.connections.first(where: { $0.id == hostID && $0.config.bindingID == bindingID }),
                  connection.phase == .connected, let client = connection.browserClient,
                  client.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability]) else {
                throw LogicalProjectsError("executor_unavailable", "The thread's exact executor binding is unavailable. No fallback host was selected.")
            }
            do { return try await client.nativeThread(agentID: task.workerAgentID, request: request) }
            catch RemoteHostClientError.outcomeUnknown(let message) { throw LogicalProjectsError("outcome_unknown", message) }
            catch RemoteHostClientError.rejected(let code, let message) { throw LogicalProjectsError(code, message) }
        }
    }

    func place(host: ProjectHostReference, request: ProjectExecutionRequest) async throws -> ProjectExecutionResult {
        guard let vm, case .remote(let hostID, let bindingID) = host,
              let connection = vm.remoteHosts.connections.first(where: { $0.id == hostID && $0.config.bindingID == bindingID }),
              let client = connection.browserClient,
              client.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability]) else {
            throw AgentStartFailure(message: "The exact executor binding is unavailable. No fallback host was selected.")
        }
        switch request {
        case .resume, .answer:
            guard vm.server.state.projects.contains(where: { $0.id == request.key.projectID && $0.ownerID == request.key.ownerID && !$0.paused }) else {
                throw LogicalProjectsError("project_paused", "Project paused before the executor control was sent.")
            }
        default: break
        }
        if case .execute(let assignment) = request {
            guard let project = vm.server.state.projects.first(where: { $0.id == request.key.projectID && $0.ownerID == request.key.ownerID }),
                  !project.paused, project.tasks.contains(where: { $0.executionAssignment == assignment && $0.destination == host }),
                  project.settings.hostPolicy == .anyConnected || project.settings.allowedHosts.contains(host),
                  project.linkedSpaces.contains(where: { $0.destination == host && $0.spaceID == assignment.executorSpaceID }),
                  connection.state.spaces.contains(where: { $0.id == assignment.executorSpaceID && !$0.hidden }) else {
                throw AgentStartFailure(message: "Project placement was revoked or its executor Space is unavailable.")
            }
        }
        try await vm.server.validateProjectPlacementRequest(request)
        return try await client.projectExecution(request)
    }

    func conversationStore(agentID: AgentID) -> NativeThreadStore? { vm?.threadStores.store(for: agentID) }

    func launch(_ request: ProjectRuntimeLaunch) async throws -> AgentID {
        guard let vm else { throw AgentStartFailure(message: "Owner closed") }
        guard vm.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        guard let project = vm.server.state.projects.first(where: { $0.id == request.projectID }), !project.paused else {
            throw AgentStartFailure(message: "Project paused or deleted before launch")
        }
        if let model = request.model, !vm.server.modelListing().models.contains(model) {
            throw AgentStartFailure(message: "Selected model is not available on this owner: \(model)")
        }
        vm.sessions.stateDidChange(vm.server.state)
        vm.state = vm.server.state
        if let existing = vm.state.agents.first(where: { $0.id == request.agentID }),
           let tab = vm.state.tabs.first(where: { $0.id == existing.tabID }), let pane = tab.layout.leaves.first {
            // Explicit restoration is idle: the server owns any queued delivery and its identity.
            try await vm.sessions.createAgentSession(pane: pane, tab: tab, agent: existing, openingPrompt: nil)
            return existing.id
        }
        return try await vm.startAgent(NewAgentConfig(spaceID: request.spaceID, workingDirectory: request.cwd,
                                                     reservedAgentID: request.agentID,
                                                     coordinatorFor: request.coordinator ? request.projectID : nil,
                                                     model: request.model, thinking: .medium, initialPrompt: nil,
                                                     initialName: request.name), selectAfter: false, focusWindow: false)
    }
}

extension ShepherdViewModel {
    func refreshProjectHosts() {
        let hosts: [ProjectHostReference] = [.local] + remoteHosts.connections.filter { $0.phase == .connected }.map {
            .remote(hostID: $0.config.id, bindingID: $0.config.bindingID)
        }
        server.setProjectEligibleHosts(hosts)
        var spaces: [ProjectHostReference: [Space]] = [:]
        for connection in remoteHosts.connections where connection.phase == .connected {
            guard connection.browserClient?.capabilities.isSuperset(of: [RemoteProtocol.projectExecutionCapability, RemoteProtocol.projectPlacementCapability]) == true else { continue }
            spaces[.remote(hostID: connection.config.id, bindingID: connection.config.bindingID)] = connection.state.spaces
        }
        server.setProjectExecutionSpaces(spaces)
    }

    func installProjectRuntime() {
        refreshProjectHosts()
        remoteHosts.onProjectExecutionChanged = { [weak self] host, key in
            self?.server.reconcileProjectExecutions(host: host, key: key)
        }
        remoteHosts.onProjectExecutorConnected = { [weak self] host in
            self?.refreshProjectHosts()
            self?.server.reconcileProjectExecutions(host: host)
        }
        server.onProjectDefaultModel = { [weak self] in
            guard let values = await MainActor.run(body: { self.map { ($0.settings.agentDefaults.model, $0.server.pi.home) } }) else { return nil }
            if let model = values.0 { return model }
            return await Task.detached { PiConfig.defaultModel(in: values.1) }.value
        }
        server.onProjectPlacement = { [weak self] host, request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.projectCoordinator.place(host: host, request: request))) }
                catch { completion(.failure(error)) }
            }
        }
        server.onProjectRuntimeRequest = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.projectCoordinator.perform(request))) }
                catch { completion(.failure(error)) }
            }
        }
        server.onProjectRuntimeLaunch = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Owner closed"))); return }
                do { completion(.success(try await self.projectCoordinator.launch(request))) }
                catch { completion(.failure(error)) }
            }
        }
    }
}
