import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The background service's client, with the host's workspace as the app's own: the host on this
/// Mac pushes its state into `adopt`, so the sidebar, the thread,
/// its menus and dialogs are the app's local ones. What they change goes to the host through the
/// connection, under the same view-model methods (`localRef`). The connection is transport only:
/// no host list, picker or page shows it (`RemoteHostStore.connections`).
extension ShepherdViewModel {
    /// The background host on this Mac, whose workspace is the app's own; nil until it connects.
    var localHost: RemoteHostStore.Connection? { remoteHosts.localHost }

    /// The host's handle on one of the app's agents, when the background host owns it.
    func localRef(_ id: AgentID) -> RemoteAgentRef? {
        localHost.map { RemoteAgentRef(hostID: $0.id, agentID: id) }
    }

    /// Connects the background host on this Mac (`ShepherdApp`), its workspace taken as the app's own.
    @discardableResult
    func connectLocalHost(socket: String, token: String) -> RemoteHostStore.Connection {
        // The host keeps its designs beside its socket, in its support folder on this Mac.
        localHostDesigns = DesignStore(directory: URL(fileURLWithPath: socket).deletingLastPathComponent()
            .appendingPathComponent("designs", isDirectory: true))
        adoptLocalHost()
        return remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
    }

    /// Takes the background host's workspace as the app's own (`connectLocalHost`, before the host
    /// is added). Its threads' revision hints go to the host.
    func adoptLocalHost() {
        // The host keeps its own settings from the shared preferences: each side follows the other's writes.
        settings.followOtherProcesses()
        // Its design systems are the Designs page's own.
        remoteHosts.onLocalDesignSystemsChanged = { [weak self] in self?.designSystemsChanged() }
        remoteHosts.onLocalDesignNotesChanged = { [weak self] in self?.designThreadNotesChanged($0) }
        remoteHosts.onLocalDesignImportProgress = { [weak self] in self?.designImporting?.apply($0) }
        remoteHosts.onLocalDesignGitChanged = { [weak self] id in
            if self?.designGitStates[id] != nil { self?.refreshDesignGit(id) }
        }
        remoteHosts.onLocalHostState = { [weak self] state in
            guard let self else { return }
            let automations = self.state.automations.map(\.id)
            self.adopt(state)
            // The host's `automationsChanged` arrives before the state that moved it: an automation
            // that came or went reads the runs again against the state that has it.
            if self.state.automations.map(\.id) != automations { self.refreshAutomationTriggers() }
        }
        // An agent's notify: a click opens the thread here.
        remoteHosts.onLocalAgentNotify = { [weak self] agentID, title, body in
            guard let self, let agent = self.state.agents.first(where: { $0.id == agentID }) else { return }
            self.notifications.post(AgentBanners.agentNotify(agent, title: title, body: body))
        }
        // A finished tool and the thread's rotation notice.
        remoteHosts.onLocalToolFinished = { [weak self] agentID, _ in self?.recordSidebarActivity(agentID) }
        remoteHosts.onLocalThreadNotice = { [weak self] agentID, message in
            self?.threadStores.store(for: agentID).reportActionNotice(message)
        }
        // The host's automation triggers and banners.
        remoteHosts.onLocalAutomationsChanged = { [weak self] in self?.refreshAutomationTriggers() }
        remoteHosts.onLocalAutomationNotify = { [weak self] title, body in self?.postAutomationBanner(title: title, body: body) }
        // The sidebar's pull request badges: the host looks them up.
        remoteHosts.onLocalPullRequestLinks = { [weak self] links, notes in self?.applyPullRequestLinks(links, notes: notes) }
        // Settings pages that read the host's stores follow its changes, and catch up on each connect.
        remoteHosts.onLocalSettingsChanged = { [weak self] page in Task { await self?.localHostSettingsChanged(page) } }
        let connected = remoteHosts.onHostConnected
        remoteHosts.onHostConnected = { [weak self] hostID in
            connected?(hostID)
            guard let self else { return }
            // A paired Mac that answers again may have turned Fleet on since: ask it again.
            if hostID != self.localHost?.id { Task { await self.adoptLegacyFleetHosts(only: hostID) } }
            guard hostID == self.localHost?.id else { return }
            Task { for page in RemoteSettingsPage.allCases { await self.localHostSettingsChanged(page) } }
            self.refreshAutomationTriggers()
            // A host that started again knows no focus: tell it.
            self.syncFocusedThread()
        }
        // The host says when an agent's pi stopped and why, opened or not: the thread's
        // can't-start and sign-in cards.
        remoteHosts.onLocalAgentStartProblem = { [weak self] id, problem in
            self?.agentStopped(id, problem: problem, stopped: problem != nil)
        }
        let remoteChanged = remoteHosts.onNativeThreadChanged
        remoteHosts.onNativeThreadChanged = { [weak self] ref in
            guard let self, ref.hostID == self.localHost?.id else { remoteChanged?(ref); return }
            self.threadStores.existing(for: ref.agentID)?.revisionAvailable()
            self.reconcileSidebarOpeningTurn(ref.agentID)
        }
    }

    /// Fleet: the paired Macs this app reached with the shared token (`RemoteHostStore`) become fleet peers
    /// of its host, which pairs with each over the same token and no code. Each one that does is
    /// marked fleet managed here; one that doesn't speak Fleet is left exactly as it was. `only` is one
    /// host that just connected, asked again even if it said before that it isn't a fleet Mac.
    func adoptLegacyFleetHosts(only: UUID? = nil) async {
        guard settings.fleetEnabled else { return }
        let hosts = remoteHosts.pairedConnections
            .filter { !$0.config.fleetManaged && (only == nil || $0.id == only) }
            .map { FleetLegacyHost(id: $0.config.id, name: $0.config.name, host: $0.config.host, port: $0.config.port, token: $0.config.token) }
        for adoption in await fleet.adopt(hosts, retrying: only != nil) {
            if case .established = adoption.outcome { remoteHosts.markFleetManaged(id: adoption.id) }
        }
        await switchFleetHostsToOwnToken()
    }

    /// Fleet: the Macs this app reached with the shared token and that are fleet peers now are reached
    /// with a token of this app's own instead, so a Mac can stop accepting the shared one. The host makes
    /// the token and every Mac in the fleet takes it in; each Mac is asked once with it before it replaces
    /// the shared token, so a Mac that didn't hear of it keeps working until it does.
    func switchFleetHostsToOwnToken() async {
        guard settings.fleetEnabled else { return }
        let pending = remoteHosts.pairedConnections.filter { $0.config.fleetManaged && !$0.config.ownToken }
        guard !pending.isEmpty else { return }
        var made = remoteHosts.pairedConnections.first { $0.config.ownToken }?.config.token
        if made == nil { made = await fleet.enrollApp(name: Host.current().localizedName ?? "Mac") }
        guard let token = made else { return }
        for connection in pending {
            let config = connection.config
            let probe = RemoteHostClient()
            defer { probe.disconnect() }
            guard (try? await probe.connect(host: config.host, port: config.port, token: token, clientName: Host.current().localizedName ?? "shepherd",
                                            capabilities: [], fetchesState: false)) != nil else { continue }
            remoteHosts.useOwnToken(id: config.id, token: token)
        }
    }

    /// A Settings page's data changed on the host: the page reads it again.
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
        case .remote: await refreshRemoteListener()
        case .fleetPressure: await fleet.refresh()
        case .fleet:
            await fleet.refresh()
            // A host that started again (or this app's connection to it) forgot the page is on screen.
            if fleet.wantsWatch { await fleet.watch(true) }
            // Fleet came up, or its listener did: a host this Mac already reached becomes a peer.
            await adoptLegacyFleetHosts()
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
        remoteHosts.updateLocalThreadHints(live: ids)
    }

    /// One Issues & PRs request, answered by the background host with the workspace's threads and folders.
    func forge(_ request: RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError> {
        await remoteHosts.localForge(request)
    }

    /// A space change, persisted on the background host. Ordered after earlier changes (`enqueuePersistence`).
    func persistSpace(_ id: SpaceID, _ description: String, failureTitle: String, host action: RemoteSpaceAction) {
        let hosts = remoteHosts
        enqueuePersistence(description, failureTitle: failureTitle) { [weak self] in
            guard let hostID = self?.localHost?.id else { throw BackgroundHostClient.HostStarting() }
            try await hosts.spaceAction(hostID: hostID, spaceID: id, action)
        }
    }

    /// The models the workspace's pi offers: the host's.
    func modelListing() async -> ModelListing {
        guard let host = localHost else { return ModelListing(models: [], defaultModel: nil) }
        return (try? await remoteHosts.listModels(hostID: host.id)) ?? ModelListing(models: [], defaultModel: nil)
    }

    /// A thread's requests: to the host that runs it.
    func nativeThread(_ id: AgentID, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let ref = localRef(id) else { throw BackgroundHostClient.HostStarting() }
        return try await remoteHosts.nativeThread(ref, request: request)
    }
}
