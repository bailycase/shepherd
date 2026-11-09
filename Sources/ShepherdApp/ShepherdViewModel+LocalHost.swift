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
    /// Whether this launch takes the host's workspace as its own: `SHEPHERD_THIS_MAC_LOCAL=1`
    /// while the local paths learn to reach the host.
    /// ponytail: a migration gate; it goes when every local path routes to the host.
    static var routesThisMacLocally: Bool {
        ProcessInfo.processInfo.environment["SHEPHERD_THIS_MAC_LOCAL"] == "1"
    }

    /// The background host on this Mac, while its workspace is the app's own; nil in process.
    var localHost: RemoteHostStore.Connection? {
        remoteHosts.hidesLocalHost ? remoteHosts.localHost : nil
    }

    /// The host's handle on one of the app's agents, when the background host owns it.
    func localRef(_ id: AgentID) -> RemoteAgentRef? {
        localHost.map { RemoteAgentRef(hostID: $0.id, agentID: id) }
    }

    /// The workspace's owner's copy: the host's, as a client, else the in-process server's.
    var ownerState: ShepherdState { localHost?.state ?? server.state }

    /// Takes the background host's workspace as the app's own (`ShepherdApp`, before the host is
    /// added). Its threads' revision hints go to the host as the in-process server's would.
    func adoptLocalHost() {
        remoteHosts.hidesLocalHost = true
        sessions.startsSessions = false
        remoteHosts.onLocalHostState = { [weak self] state in self?.adopt(state) }
        // As the in-process session's notify (`sessions.onNotify`): a click opens the thread here.
        remoteHosts.onLocalAgentNotify = { [weak self] agentID, title, body in
            guard let self, let agent = self.state.agents.first(where: { $0.id == agentID }) else { return }
            self.notifications.post(AgentBanners.agentNotify(agent, title: title, body: body))
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
