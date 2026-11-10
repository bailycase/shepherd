import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The background service's client, with the host's workspace as the app's own: the host on this
/// Mac pushes its state into `adopt`, as the in-process server does, so the sidebar, the thread,
/// its menus and dialogs are the app's local ones. What they change goes to the host through the
/// connection, under the same view-model methods (`localRef`). The connection is transport only:
/// no host list, picker or page shows it (`RemoteHostStore.hidesLocalHost`).
extension ShepherdViewModel {
    /// Whether this launch takes the host's workspace as its own: yes, unless
    /// `SHEPHERD_THIS_MAC_LOCAL=0` (the switch back to This Mac as a host, while it lasts).
    /// ponytail: a migration gate; it goes when every local path routes to the host.
    static var routesThisMacLocally: Bool {
        ProcessInfo.processInfo.environment["SHEPHERD_THIS_MAC_LOCAL"] != "0"
    }

    /// The host's workspace less what designs, Projects and missions own: their pages
    /// still reach those through the host's connection (`allConnections`), so the app's local views,
    /// whose actions would go to the idle in-process server, never see them.
    /// ponytail: a fallback until those features route through `localHost` too.
    nonisolated static func mirrored(_ state: ShepherdState) -> ShepherdState {
        let owned = state.projectWorkerIDs.union(state.missionAgentIDs)
        var copy = state.withoutDesigns.withoutProjectCoordinators
        let gone = Set(copy.agents.filter { owned.contains($0.id) }.map(\.id))
        let tabs = Set(copy.agents.filter { gone.contains($0.id) }.map(\.tabID))
        copy.agents.removeAll { gone.contains($0.id) }
        copy.tabs.removeAll { tabs.contains($0.id) || $0.inspectorFor.map(gone.contains) == true }
        copy.spaces.removeAll(where: \.holdsDesigns)
        copy.projects = []
        copy.projectExecutions = []
        copy.missions = []
        return copy
    }

    /// The background host on this Mac, while its workspace is the app's own; nil in process.
    var localHost: RemoteHostStore.Connection? {
        remoteHosts.hidesLocalHost ? remoteHosts.localHost : nil
    }

    /// The host's handle on one of the app's agents, when the background host owns it.
    func localRef(_ id: AgentID) -> RemoteAgentRef? {
        localHost.map { RemoteAgentRef(hostID: $0.id, agentID: id) }
    }

    /// The workspace's owner's copy: the host's as the app mirrors it, as a client, else the
    /// in-process server's.
    var ownerState: ShepherdState { localHost.map { Self.mirrored($0.state) } ?? server.state }

    /// Connects the background host on this Mac (`ShepherdApp`), its workspace taken as the app's
    /// own unless `SHEPHERD_THIS_MAC_LOCAL=0`.
    @discardableResult
    func connectLocalHost(socket: String, token: String) -> RemoteHostStore.Connection {
        if Self.routesThisMacLocally { adoptLocalHost() }
        return remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
    }

    /// Takes the background host's workspace as the app's own (`connectLocalHost`, before the host
    /// is added). Its threads' revision hints go to the host as the in-process server's would.
    func adoptLocalHost() {
        remoteHosts.hidesLocalHost = true
        sessions.startsSessions = false
        // The host keeps its own settings from the shared preferences: each side follows the other's writes.
        settings.followOtherProcesses()
        remoteHosts.onLocalHostState = { [weak self] state in
            guard let self else { return }
            let automations = self.state.automations.map(\.id)
            self.adopt(Self.mirrored(state))
            // The host's `automationsChanged` arrives before the state that moved it: an automation
            // that came or went reads the runs again against the state that has it.
            if self.state.automations.map(\.id) != automations { self.refreshAutomationTriggers() }
        }
        // As the in-process session's notify (`sessions.onNotify`): a click opens the thread here.
        remoteHosts.onLocalAgentNotify = { [weak self] agentID, title, body in
            guard let self, let agent = self.state.agents.first(where: { $0.id == agentID }) else { return }
            self.notifications.post(AgentBanners.agentNotify(agent, title: title, body: body))
        }
        // As the in-process server's `onAgentToolFinished` and the thread's rotation notice.
        remoteHosts.onLocalToolFinished = { [weak self] agentID, _ in self?.recordSidebarActivity(agentID) }
        remoteHosts.onLocalThreadNotice = { [weak self] agentID, message in
            self?.threadStores.store(for: agentID).reportActionNotice(message)
        }
        // As the in-process server's `AutomationHosting.triggersChanged` and `notify`.
        remoteHosts.onLocalAutomationsChanged = { [weak self] in self?.refreshAutomationTriggers() }
        remoteHosts.onLocalAutomationNotify = { [weak self] title, body in self?.postAutomationBanner(title: title, body: body) }
        // Settings pages that read the host's stores follow its changes, and catch up on each connect.
        remoteHosts.onLocalSettingsChanged = { [weak self] page in Task { await self?.localHostSettingsChanged(page) } }
        let connected = remoteHosts.onHostConnected
        remoteHosts.onHostConnected = { [weak self] hostID in
            connected?(hostID)
            guard let self, hostID == self.localHost?.id else { return }
            Task { for page in RemoteSettingsPage.allCases { await self.localHostSettingsChanged(page) } }
            self.refreshAutomationTriggers()
        }
        // The thread says when the host's pi stopped and why: its can't-start and sign-in cards.
        let configure = threadStores.configure
        threadStores.configure = { [weak self] id, store in
            configure?(id, store)
            self?.watchStartProblem(id, store)
        }
        let remoteChanged = remoteHosts.onNativeThreadChanged
        remoteHosts.onNativeThreadChanged = { [weak self] ref in
            guard let self, ref.hostID == self.localHost?.id else { remoteChanged?(ref); return }
            self.threadStores.existing(for: ref.agentID)?.revisionAvailable()
            self.reconcileSidebarOpeningTurn(ref.agentID)
        }
    }

    /// A Settings page's data changed on the host: the page reads it again, as in process the
    /// server's `on…Changed` hands it over.
    func localHostSettingsChanged(_ page: RemoteSettingsPage) async {
        switch page {
        case .instructions: await instructions.localFilesChanged()
        case .suggestions: await suggestions.refresh()
        case .skills:
            guard case .skills(let snapshot)? = try? await localHost?.skillsClient?.skills(.fetch) else { return }
            skills.hostChanged(Self.thisMacSkills, snapshot)
        case .hooks: hooks.reload()
        case .slashCommands:
            guard let host = try? remoteHosts.thisMacHost(), let settings = try? await host.hostSettings() else { return }
            slashCommands.catalog = settings.slashCommands
        }
    }

    /// The subagents the host's threads published, as this app's own threads' (`applyAgentChildren`).
    /// The host sweeps stale rows as it answers, so none are swept here (`syncChildSweepTimer`).
    func syncLocalHostChildren() {
        guard let host = localHost else { return }
        let published = host.children
        for (id, rows) in published where childRuns.children(of: id) != rows { applyAgentChildren(id, rows) }
        for id in childRuns.rows.keys where published[id] == nil { applyAgentChildren(id, []) }
    }

    /// The threads whose revisions are pushed: those on screen and those opening a turn.
    func watchThreadRevisions(of ids: Set<AgentID>) {
        if localHost != nil { remoteHosts.updateLocalThreadHints(live: ids) } else { sessions.watchThreadRevisions(of: ids) }
    }

    /// One Issues & PRs request, answered with the workspace's threads and folders: by the
    /// background host as its client, else the in-process server.
    func forge(_ request: RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError> {
        if localHost != nil { return await remoteHosts.localForge(request) }
        return await server.forge(request)
    }

    /// A space change, persisted where the workspace lives: the background host (as its client),
    /// else the in-process server. Ordered after earlier changes either way (`enqueuePersistence`).
    func persistSpace(_ id: SpaceID, _ description: String, failureTitle: String, host action: RemoteSpaceAction,
                      server operation: @escaping @Sendable (SessionServer) async throws -> Void) {
        guard let host = localHost else {
            enqueuePersistence(description, failureTitle: failureTitle, operation: operation)
            return
        }
        let (hosts, hostID) = (remoteHosts, host.id)
        enqueuePersistence(description, failureTitle: failureTitle) { _ in try await hosts.spaceAction(hostID: hostID, spaceID: id, action) }
    }

    /// The models the workspace's pi offers: the host's pi as its client, else this app's.
    func modelListing() async -> ModelListing {
        if let host = localHost {
            return (try? await remoteHosts.listModels(hostID: host.id)) ?? ModelListing(models: [], defaultModel: nil)
        }
        let server = server
        return await Task.detached(priority: .userInitiated) { server.modelListing() }.value
    }

    /// Runs `agentStopped` for each start problem the host's thread reports, for as long as the
    /// store is the agent's (the in-process app hears it from the session instead).
    private func watchStartProblem(_ id: AgentID, _ store: NativeThreadStore) {
        let problem = store.startProblem
        if problem != nil || cannotStart.contains(id) || notSignedIn[id] != nil {
            agentStopped(id, problem: problem, stopped: problem != nil)
        }
        withObservationTracking { _ = store.startProblem } onChange: { [weak self, weak store] in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.threadStores.existing(for: id) === store else { return }
                self.watchStartProblem(id, store)
            }
        }
    }

    /// A thread's requests: to the host that runs it, else the in-process server.
    func nativeThread(_ id: AgentID, request: NativeThreadRequest) async throws -> NativeThreadResult {
        if let ref = localRef(id) { return try await remoteHosts.nativeThread(ref, request: request) }
        return try await server.nativeThread(agentID: id, request: request)
    }
}
