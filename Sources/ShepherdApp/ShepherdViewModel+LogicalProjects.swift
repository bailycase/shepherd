import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Projects in the sidebar, selection and sheets. The runtime (conversation, tasks, pause dispatch)
// is the parent's lane; this file reads and edits the persisted record only.

/// One Project as the sidebar draws it, in either mode.
struct SidebarLogicalProject: Identifiable, Equatable {
    let ref: LogicalProjectRef
    let name: String
    /// The host that owns it, when it is not this Mac ("build-01").
    let hostName: String?
    /// Real thread count and state only: nothing here is synthetic. Empty until the lifecycle
    /// reports tasks for the project.
    var summary: String?
    var needsYou = false
    /// Its open threads (not resolved), the Spaces mode's count.
    var count = 0
    var selected = false
    var id: LogicalProjectRef { ref }
}

extension ShepherdViewModel {
    // MARK: Model

    /// The hosts the Project's OWNER knows: its own runtime answers for this Mac, and a remote owner answers for itself.
    func projectHostOptions(of home: LogicalProjectHome) async throws -> [ProjectHostOption] {
        var result: ProjectRuntimeResult = .hosts([])
        switch home {
        case .local:
            result = try await projectCoordinator.perform(ProjectRuntimeTransport.hosts)
        case .host(let id):
            result = try await remoteHosts.projectRuntime(hostID: id, request: ProjectRuntimeTransport.hosts)
        }
        guard case .hosts(let options) = result else { return [] }
        return options
    }

    var logicalProjects: LogicalProjectsModel {
        if let madeLogicalProjects { return madeLogicalProjects }
        let model = makeLogicalProjectsModel()
        madeLogicalProjects = model
        return model
    }

    /// One owner request: this Mac's server, or the connected host that owns the Project.
    private func sendLogicalProjects(_ home: LogicalProjectHome, _ request: LogicalProjectsRequest) async throws -> LogicalProjectsResult {
        switch home {
        case .local: return try await server.logicalProjects(request)
        case .host(let id): return try await remoteHosts.logicalProjects(hostID: id, request: request)
        }
    }

    /// What each owner last pushed in its state snapshot.
    private func pushedLogicalProjects(_ home: LogicalProjectHome) -> [Project] {
        switch home {
        case .local: return state.projects
        case .host(let id): return remoteHosts.connections.first { $0.id == id }?.state.projects ?? []
        }
    }

    /// A Project action at the revision shown, run by the Project's owner: this Mac's runtime, or the owning host's through
    /// `ProjectRuntimeTransport.action`. A host that does not serve it (an older one) says `update_required`, and nothing runs here.
    private func performProjectRuntime(_ ref: LogicalProjectRef, _ revision: UInt64, _ request: ProjectRuntimeRequest) async throws -> Project {
        switch ref.home {
        case .local:
            return try await projectCoordinator.perform(projectID: ref.id, expectedRevision: revision, request: request)
        case .host(let id):
            let transport = ProjectRuntimeTransport.action(projectID: ref.id, expectedRevision: revision, request: request)
            guard case .project(let project) = try await remoteHosts.projectRuntime(hostID: id, request: transport) else {
                throw LogicalProjectsError("protocol", "The host answered with something other than the Project.")
            }
            return project
        }
    }

    /// A worker's question answered through the Project's owner, fenced by the Project revision and the worker's own dialog.
    private func answerProjectQuestion(_ ref: LogicalProjectRef, _ revision: UInt64, _ task: ProjectTaskID,
                                       _ request: NativeThreadRequest) async throws -> NativeThreadResult {
        switch ref.home {
        case .local:
            return try await server.answerProjectQuestion(ref.id, expectedRevision: revision, taskID: task, request: request)
        case .host(let id):
            let transport = ProjectRuntimeTransport.answer(projectID: ref.id, expectedRevision: revision, taskID: task, request: request)
            guard case .native(let result) = try await remoteHosts.projectRuntime(hostID: id, request: transport) else {
                throw LogicalProjectsError("protocol", "The host answered with something other than the question's result.")
            }
            return result
        }
    }

    private func makeLogicalProjectsModel() -> LogicalProjectsModel {
        let closing = LogicalProjectsError("unavailable", "Shepherd is closing.")
        let send: LogicalProjectsModel.Send = { [weak self] home, request in
            guard let self else { throw closing }
            return try await self.sendLogicalProjects(home, request)
        }
        let pushed: LogicalProjectsModel.Pushed = { [weak self] home in self?.pushedLogicalProjects(home) ?? [] }
        let runtime: LogicalProjectsModel.Runtime = { [weak self] ref, revision, request in
            guard let self else { throw closing }
            return try await self.performProjectRuntime(ref, revision, request)
        }
        let model = LogicalProjectsModel(send: send, pushed: pushed, runtime: runtime)
        model.answerQuestion = { [weak self] ref, revision, task, request in
            guard let self else { throw closing }
            return try await self.answerProjectQuestion(ref, revision, task, request)
        }
        model.ownerHosts = { [weak self] home in
            guard let self else { throw closing }
            return try await self.projectHostOptions(of: home)
        }
        return model
    }

    // MARK: Reading what the sidebar draws

    /// Every owner's projects, This Mac first, then each connected host that serves them, in
    /// configured order. An older host serves none.
    var allLogicalProjects: [(home: LogicalProjectHome, hostName: String?, project: Project)] {
        guard projectsEnabled else { return [] }
        var rows = state.projects.map { (home: LogicalProjectHome.local, hostName: String?.none, project: $0) }
        for connection in remoteHosts.connections where connection.phase == .connected && connection.supportsLogicalProjects {
            rows += connection.state.projects.map { (home: LogicalProjectHome.host(connection.id), hostName: connection.config.name, project: $0) }
        }
        return rows
    }

    /// The Projects the sidebar lists, with the one on screen marked.
    var sidebarLogicalProjects: [SidebarLogicalProject] {
        allLogicalProjects.map { owner in
            let ref = LogicalProjectRef(home: owner.home, id: owner.project.id)
            let page = ProjectPagePresentation(owner.project)
            // The summary is counted from the tasks the owner reports: "1 needs you" first, else "2 working", else nothing.
            let summary = page.waiting > 0 ? "\(page.waiting) needs you" : page.working > 0 ? "\(page.working) working" : nil
            return SidebarLogicalProject(ref: ref, name: owner.project.name, hostName: owner.hostName, summary: summary,
                                         needsYou: page.waiting > 0, count: page.total - page.resolved,
                                         selected: ref == selectedLogicalProject && (shownDestination == .project || shownDestination == .projectSettings))
        }
    }

    /// "Baily": the Mac's user's first name, for "Welcome back, Baily." (never a typed sample).
    var projectViewerName: String {
        (sidebarFooterIdentity?.name ?? SidebarDerivation.footer.name).split(separator: " ").first.map(String.init) ?? ""
    }

    /// Whether this Project's OWNER carries images with a message. It comes from the Project transport, never from the coordinator's
    /// native snapshot, so the paperclip, paste and drop agree and exist before the first coordinator does. This Mac's own runtime
    /// always does; a remote owner says so with its capability.
    func projectCarriesImages(_ home: LogicalProjectHome) -> Bool {
        switch home {
        case .local: true
        case .host(let id): remoteHosts.connections.first { $0.id == id }?.supportsProjectMessageImages == true
        }
    }

    /// A worker's own native thread store: this Mac's for a local Project, the owner's (read as a remote agent) for a remote one.
    func projectWorkerStore(_ home: LogicalProjectHome, _ agent: AgentID) -> NativeThreadStore {
        switch home {
        case .local: threadStores.store(for: agent)
        case .host(let host): remoteThreadStores.store(for: RemoteAgentRef(hostID: host, agentID: agent))
        }
    }

    /// How a worker's thread is read and written: always through the Project's OWNER, keyed by Project and task (never by an agent ID
    /// or a host this viewer chose). The owner finds the recorded worker and its exact executor binding, so a viewer needs no
    /// executor credentials. A task the executor has not opened yet answers `native_starting`, and nothing is started for it.
    func projectWorkerRequest(_ ref: LogicalProjectRef, task: ProjectTaskID) -> NativeThreadStore.Request {
        { [weak self] native in
            guard let self else { throw LogicalProjectsError("unavailable", "Shepherd is closing.") }
            let transport = ProjectRuntimeTransport.worker(projectID: ref.id, taskID: task, request: native)
            let result: ProjectRuntimeResult
            switch ref.home {
            case .local: result = try await self.projectCoordinator.perform(transport)
            case .host(let host): result = try await self.remoteHosts.projectRuntime(hostID: host, request: transport)
            }
            guard case .native(let value) = result else {
                throw LogicalProjectsError("protocol", "The host answered with something other than the thread.")
            }
            return value
        }
    }

    /// What a running worker is doing, from its own native thread: the current step of the plan it reported, else its activity line
    /// (the call running now, else the last burst), never a typed-in sentence. nil while it has shown nothing.
    func workerActivity(_ agent: AgentID, home: LogicalProjectHome = .local) -> String? {
        // The worker's own plan says what it is doing now (ProjectLead-Started: "Writing the OpenAPI spec"): the typed `project_plan` step
        // that is current, when it has reported one in its latest turn. Otherwise the call running now.
        let latest = projectWorkerStore(home, agent).rows.last { $0.presentation != nil }?.presentation
        if let current = latest?.latestProjectPlan?.steps.first(where: { $0.state == .current }) { return current.text }
        let items = latest?.items ?? []
        for item in items.reversed() {
            // A plan update is the Steps card, never an activity line.
            if case .activity(_, let bursts) = item, let burst = bursts.last(where: { $0.calls.allSatisfy { $0.projectPlan == nil } }) {
                return burst.meta.isEmpty ? burst.label : burst.label + " · " + burst.meta
            }
        }
        return nil
    }

    /// When a running worker's current work began, in milliseconds: the time of the last message a person or the project sent it
    /// (its assignment, or the latest follow-up), else when its status last changed. nil when neither is known yet (no age is drawn).
    func workerStarted(_ agent: AgentID, home: LogicalProjectHome = .local) -> Double? {
        projectWorkerStore(home, agent).rows.last { $0.turn.isUser }?.turn.messages.first?.timestamp
            ?? statusSince[agent].map { $0.timeIntervalSince1970 * 1000 }
    }

    /// A Suggestion puts its words in the Project's composer for the person to read and send. It sends nothing itself.
    func useProjectSuggestion(_ text: String, in ref: LogicalProjectRef) {
        guard let project = logicalProjects.project(ref) else { return }
        let store = project.coordinatorAgentID.map { threadStores.store(for: $0) } ?? emptyProjectConversation
        store.draft = text
        (project.coordinatorAgentID.map { threadStores.input(for: $0) } ?? emptyProjectInput).focus()
    }

    /// The Project that owns an automation (This Mac's), nil for an ordinary one.
    func projectOwning(_ automation: AutomationID) -> LogicalProjectRef? {
        state.automations.first { $0.id == automation }?.projectID.map { LogicalProjectRef(home: .local, id: $0) }
    }

    // MARK: Opening

    /// A Project's page: its Overview and conversation.
    func openLogicalProject(_ ref: LogicalProjectRef) {
        guard projectsEnabled, logicalProjects.project(ref) != nil else { return }
        // A file a card asked for belongs to the Project that drew the card; another Project never inherits it.
        if logicalProjectPaneFile?.ref != ref { logicalProjectPaneFile = nil }
        selectedLogicalProject = ref
        logicalProjectSettingsTab = .general
        openDestination(.project)
    }

    /// A Project's own settings, on one of its four tabs.
    func openLogicalProjectSettings(_ ref: LogicalProjectRef, tab: LogicalProjectSettingsTab = .general) {
        guard projectsEnabled, logicalProjects.project(ref) != nil else { return }
        selectedLogicalProject = ref
        logicalProjectSettingsTab = tab
        openDestination(.projectSettings)
    }

    /// New project: the sheet opens for the owner that will hold it (This Mac).
    func showNewProject() {
        guard projectsEnabled else { return }
        newLogicalProject = NewLogicalProjectDraft()
    }

    // MARK: Spaces a project may link

    /// The Spaces on the owner a new project can link: existing, not hidden, not reserved. A
    /// viewer never offers another host's Space for a project this Mac owns.
    var linkableLogicalProjectSpaces: [Space] {
        state.spaces.filter { !$0.hidden }
    }

    /// The owner's Spaces, by ID, for a project's links (owner-relative).
    func ownerSpaces(of home: LogicalProjectHome) -> [Space] {
        switch home {
        case .local: state.spaces
        case .host(let id): remoteHosts.connections.first { $0.id == id }?.state.spaces ?? []
        }
    }

    func ownerName(of home: LogicalProjectHome) -> String {
        switch home {
        case .local: "This Mac"
        case .host(let id): remoteHosts.connections.first { $0.id == id }?.config.name ?? "this host"
        }
    }

    /// The pi model ids the owner can use now: its real catalog, never a list this app carries.
    func ownerModelIDs(of home: LogicalProjectHome) async -> [String] {
        switch home {
        case .local:
            let server = self.server
            return await Task.detached(priority: .userInitiated) { server.modelListing().models }.value
        case .host(let id):
            return (try? await remoteHosts.listModels(hostID: id))?.models ?? []
        }
    }
}

/// The New project sheet's draft. The ID is made once, so a retry after a failure never creates a second project.
struct NewLogicalProjectDraft: Identifiable, Equatable {
    let id = ProjectID()
    var name = ""
    var goal = ""
    var spaces: [SpaceID] = []
    var creating = false

    var canCreate: Bool { !creating && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
