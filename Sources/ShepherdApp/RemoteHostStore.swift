import Foundation
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

/// The Macs of this Mac's fleet, each with one live connection (their configs persisted in UserDefaults as JSON), and
/// this Mac's own background host. A Mac connects to another only by joining its fleet: `ShepherdViewModel.syncFleetConnections`
/// adds and removes these as the fleet changes. The other Mac runs the full Shepherd app;
/// this store is the MacBook-side viewer: it adopts pushed state for the
/// sidebar, serves remote agents' native threads, and bridges auxiliary
/// shell panes' terminals over the wire.
///
/// Reconnects with backoff while a host is unreachable — a laptop that slept
/// picks its hosts back up without any UI action. A host that refuses the token
/// or speaks another protocol waits for Edit or Reconnect instead.
@MainActor
@Observable
final class RemoteHostStore {
    struct HostConfig: Codable, Hashable, Identifiable {
        var id: UUID
        /// Persisted identity of this destination. Project assignments must not follow an edit
        /// that points an existing sidebar host at a different server or credential.
        var bindingID: UUID
        var name: String
        var host: String
        var port: UInt16
        var token: String
        /// The background host on this Mac (`host.sock`), in place of `host` and `port`. Never
        /// persisted: each launch finds it again.
        var localSocket: String?
        /// This Mac's host holds this one as a fleet peer (`FleetService`): its address and
        /// token are the fleet's. The app keeps this direct connection for drawing the Mac's threads;
        /// `bindingID` stays, so Project executor references survive. A saved config without it is a Mac this app
        /// was a client of before Fleet was how Macs connect (`notInFleet`).
        var fleetManaged: Bool
        /// `token` is this app's own (a fleet device token its host gave it), not the Mac's shared one,
        /// which a Mac can stop accepting.
        var ownToken: Bool

        init(id: UUID = UUID(), name: String, host: String, port: UInt16, token: String,
             bindingID: UUID = UUID(), localSocket: String? = nil, fleetManaged: Bool = false, ownToken: Bool = false) {
            self.localSocket = localSocket
            self.fleetManaged = fleetManaged
            self.ownToken = ownToken
            self.id = id
            self.bindingID = bindingID
            self.name = name
            self.host = host
            self.port = port
            self.token = token
        }

        private enum CodingKeys: String, CodingKey { case id, bindingID, name, host, port, token, fleetManaged, ownToken }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            // Older configurations have a stable first binding without a write on load.
            bindingID = try values.decodeIfPresent(UUID.self, forKey: .bindingID) ?? id
            name = try values.decode(String.self, forKey: .name)
            host = try values.decode(String.self, forKey: .host)
            port = try values.decode(UInt16.self, forKey: .port)
            token = try values.decode(String.self, forKey: .token)
            fleetManaged = try values.decodeIfPresent(Bool.self, forKey: .fleetManaged) ?? false
            ownToken = try values.decodeIfPresent(Bool.self, forKey: .ownToken) ?? false
        }
    }

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(RemoteHostFailure)
    }

    /// One host's connection. Views observe its config, phase, pushed state and child runs;
    /// the transport bookkeeping below them is unobserved, and pane views register their
    /// sessions while rendering, so `panes` must never invalidate a view.
    @MainActor
    @Observable
    final class Connection: Identifiable {
        /// Editable in Settings; the store reconnects after a change.
        fileprivate(set) var config: HostConfig
        /// The background host on this Mac (client mode), whose workspace is the app's own.
        var isLocalHost: Bool { config.localSocket != nil }
        var phase: Phase = .disconnected {
            didSet {
                if oldValue == .connected, phase != .connected { lastSeen = Date() }
                if phase == .connected, lastSeen != nil { lastSeen = nil }
                onProjectionChanged?()
            }
        }
        /// When the connection last dropped, this launch (the Hosts page's Last seen); nil while
        /// connected, or when it never connected. Never persisted.
        fileprivate(set) var lastSeen: Date?
        var state = ShepherdState() {
            didSet {
                guard projects else { return }
                let agentIDs = Set(state.agents.map(\.id))
                let kept = children.filter { agentIDs.contains($0.key) }
                if kept.count != children.count { children = kept }
                onProjectionChanged?()
            }
        }
        /// Off while `skip` writes `state`: the push behind it projects (`onProjectionChanged`, the child rows' prune)
        /// for both. Every projection reads the connections whole, so none is owed to a push it skipped.
        @ObservationIgnored private var projects = true
        fileprivate(set) var children: [AgentID: [ChildRun]] = [:] { didSet { onProjectionChanged?() } }
        @ObservationIgnored fileprivate var onProjectionChanged: (() -> Void)?
        @ObservationIgnored fileprivate var childRefreshTask: Task<Void, Never>?
        @ObservationIgnored fileprivate(set) var endpointID = UUID()
        @ObservationIgnored fileprivate(set) var transportID = UUID()
        @ObservationIgnored fileprivate var stateGeneration = 0
        @ObservationIgnored fileprivate var client: RemoteHostClient? {
            didSet { hubSlot.hub = client?.tunnels }
        }
        /// The host's fleet identity (`helloOk.hostID`), kept after the link drops so a thread it sent still nests under its sender
        /// while that Mac is away. Nil until it has answered once, and for a host without Fleet.
        var fleetID: UUID? {
            if let id = client?.hostID { lastFleetID = id }
            return lastFleetID
        }
        @ObservationIgnored private var lastFleetID: UUID?
        /// The workspace pushes the host sent that the app has not taken yet (tests, diagnostics).
        var queuedStateEvents: Int { client?.queuedStateEvents ?? 0 }
        /// Where a forwarded port of this host finds its connection's tunnels (Browser): filled
        /// while there is a client, empty while there is none.
        let hubSlot = BrowserTunnelHubSlot()
        @ObservationIgnored fileprivate var reconnectTask: Task<Void, Never>?
        @ObservationIgnored fileprivate var reconnectDelay: Duration = .seconds(1)
        /// A reconnect waits out its backoff.
        @ObservationIgnored fileprivate(set) var retryPending = false
        /// Panes attached through this connection, keyed by the host-side
        /// session id. Weak-held by the pane views' lifetime: detach removes.
        @ObservationIgnored fileprivate var panes: [SessionID: RemotePaneSession] = [:]

        let id: UUID
        /// The host's designs (`designs.v1`, while its Design tool is on): its listing and each
        /// design's files, fetched by hash into the store's cache.
        let designs: RemoteDesignLibrary

        init(config: HostConfig, designCache: RemoteDesignCache = RemoteDesignCache()) {
            self.config = config
            self.id = config.id
            designs = RemoteDesignLibrary(hostID: config.id, cache: designCache)
        }

        /// Takes a push that a newer one is queued behind and the app leaves unadopted. `state` holds it at once, so
        /// no reader sees an older one than the app does, and observers are told as for any push; only the
        /// projection waits for the push behind it.
        fileprivate func skip(_ push: ShepherdState) {
            projects = false
            state = push
            projects = true
        }

        /// The host serves designs now (observed: it can change while connected).
        var supportsDesigns: Bool { designs.available }

        var supportsInspection: Bool { client?.capabilities.contains(RemoteProtocol.agentInspectionCapability) == true }
        var supportsThreadMove: Bool { client?.capabilities.contains(RemoteProtocol.moveThreadCapability) == true }
        var supportsPushMute: Bool { client?.capabilities.contains(RemoteProtocol.pushMuteCapability) == true }
        /// The host moves its threads to another Mac of its fleet when asked (`fleet.move.view.v1`).
        var supportsFleetMove: Bool { client?.capabilities.contains(RemoteProtocol.fleetMoveViewCapability) == true }
        /// The host deletes a design for this Mac, with Undo (`design.delete.v1`, while it serves
        /// designs).
        var supportsDesignDelete: Bool {
            supportsDesigns && client?.capabilities.contains(RemoteProtocol.designDeleteCapability) == true
        }
        /// The host offers `capability` beside its designs (`design.agent.v1`, `design.lifecycle.v1`,
        /// `design.systems.v1`).
        func supportsDesignCapability(_ capability: String) -> Bool {
            supportsDesigns && client?.capabilities.contains(capability) == true
        }
        var supportsReviewCommit: Bool { client?.capabilities.contains(RemoteProtocol.reviewCommitCapability) == true }
        /// The host carries Browser tunnels, lists its threads' dev servers and starts them
        /// (`browser.tunnel.v1`): its threads get a Browser tab here.
        var supportsBrowser: Bool { client?.capabilities.contains(RemoteProtocol.browserTunnelCapability) == true }
        /// The host lists and reads its threads' folders for this Mac (`files.v1`): their Files tab here.
        var supportsFiles: Bool { client?.capabilities.contains(RemoteProtocol.filesCapability) == true }
        var filesClient: RemoteHostClient? { phase == .connected && supportsFiles ? client : nil }
        /// This connection's client, for what a page asks of its host (Browser).
        var browserClient: RemoteHostClient? { phase == .connected ? client : nil }
        /// The host answers `changes*` queries: its reviews use the Changes engine.
        var supportsChanges: Bool { client?.capabilities.contains(RemoteProtocol.changesCapability) == true }
        /// The host serves automations over the protocol; older hosts show them read-only.
        var supportsAutomations: Bool { client?.capabilities.contains(RemoteProtocol.automationsCapability) == true }
        /// The host serves automation triggers: their status, inbox and settings.
        var supportsAutomationTriggers: Bool {
            supportsAutomations && client?.capabilities.contains(RemoteProtocol.automationTriggersCapability) == true
        }
        /// The host serves its root instructions (Settings ▸ Instructions).
        var supportsInstructions: Bool { client?.capabilities.contains(RemoteProtocol.instructionsCapability) == true }
        /// The host serves Settings ▸ Skills (`skills.v1`).
        var supportsSkills: Bool { client?.capabilities.contains(RemoteProtocol.skillsCapability) == true }
        var supportsHostUpdate: Bool { client?.capabilities.contains(RemoteProtocol.hostUpdateCapability) == true }
        /// The client for update requests, while connected and capable.
        var updateClient: RemoteHostClient? { supportsHostUpdate ? client : nil }
        var supportsProjects: Bool {
            client?.capabilities.contains(RemoteProtocol.projectsV2Capability) == true
                || client?.capabilities.contains(RemoteProtocol.projectsCapability) == true
        }
        /// The host owns and serves Projects (`logicalProjects.v1`); an older host has none to show.
        var supportsLogicalProjects: Bool { client?.capabilities.contains(RemoteProtocol.logicalProjectsCapability) == true }
        /// The host serves Project automation settings (`logicalProjectAutomations.v1`), apart from running them.
        /// The host carries images with a Project message (`logicalProjectRuntime.images.v1`).
        var supportsProjectMessageImages: Bool { client?.capabilities.contains(RemoteProtocol.projectMessageImagesCapability) == true }
        /// The host keeps a Project's conversation reasoning level (`logicalProjects.conversationThinking.v1`).
        var supportsProjectConversationThinking: Bool { client?.capabilities.contains(RemoteProtocol.projectConversationThinkingCapability) == true }
        var supportsLogicalProjectAutomations: Bool { client?.capabilities.contains(RemoteProtocol.logicalProjectAutomationsCapability) == true }
        var supportsProjectDetails: Bool { client?.capabilities.contains(RemoteProtocol.projectDetailsCapability) == true }
        var supportsProjectMCP: Bool { client?.capabilities.contains(RemoteProtocol.projectMCPCapability) == true }
        var supportsProjectResources: Bool { client?.capabilities.contains(RemoteProtocol.projectResourcesCapability) == true }
        var supportsProjectInheritance: Bool { client?.capabilities.contains(RemoteProtocol.projectInheritanceCapability) == true }
        var supportsProjectInheritedResources: Bool { client?.capabilities.contains(RemoteProtocol.projectInheritedResourcesCapability) == true }
        var supportsProjectParent: Bool { client?.capabilities.contains(RemoteProtocol.projectParentCapability) == true }
        /// What Settings ▸ Skills reads and changes the host's skills through, while it's connected.
        var skillsClient: (any SkillsClient)? { phase == .connected ? client : nil }
        /// What Settings' host picker reads and changes the host's settings through, while it's connected.
        var settingsClient: (any SettingsClient)? { phase == .connected ? client : nil }
        /// What the host told this Mac it can do, while connected.
        var capabilities: Set<String> { phase == .connected ? Set(client?.capabilities ?? []) : [] }
        /// The host takes every level pi has in `createAgent` (older hosts: Off to High).
        var supportsAllThinkingLevels: Bool { client?.capabilities.contains(RemoteProtocol.thinkingLevelsCapability) == true }
        var supportsCreateAgentServiceTier: Bool { client?.capabilities.contains(RemoteProtocol.createAgentServiceTierCapability) == true }
        /// The host takes the terminal panel's Rename tab and Kill process.
        var supportsTerminalControl: Bool { client?.capabilities.contains(RemoteProtocol.terminalControlCapability) == true }
        var supportsTerminalStart: Bool { client?.capabilities.contains(RemoteProtocol.terminalStartCapability) == true }
        var supportsCheckoutRead: Bool { client?.capabilities.contains(RemoteProtocol.checkoutReadCapability) == true }
        /// This Mac's host takes what the app writes for the person (`changesWriteBegan`).
        var supportsChangesWrites: Bool { client?.capabilities.contains(RemoteProtocol.changesWritesCapability) == true }
        /// The host takes a new thread's images with its opening prompt.
        var supportsCreateAgentImages: Bool { client?.capabilities.contains(RemoteProtocol.createAgentImagesCapability) == true }
        var supportsWorktreeCreation: Bool {
            client?.capabilities.isSuperset(of: [RemoteProtocol.creationOptionsCapability, RemoteProtocol.worktreeActionsCapability]) == true
        }

        func stopChildRefresh() {
            childRefreshTask?.cancel()
            childRefreshTask = nil
            // Keep the last snapshot offline, like state. Clearing it would briefly finish a
            // done parent on reconnect before the first child query restores its live work.
        }

        func startChildRefresh(client: RemoteHostClient, every interval: Duration) {
            stopChildRefresh()
            guard client.capabilities.contains(RemoteProtocol.agentInspectionCapability) else {
                if !children.isEmpty { children = [:] }
                return
            }
            childRefreshTask = Task { [weak self, weak client] in
                while !Task.isCancelled {
                    guard let client, let agents = self?.state.agents,
                          self?.client === client, self?.phase == .connected else { return }
                    for agent in agents {
                        guard !Task.isCancelled, self?.client === client else { return }
                        do {
                            if case .children(let rows) = try await client.agentQuery(agentID: agent.id, query: .children),
                               !Task.isCancelled, self?.client === client,
                               self?.state.agents.contains(where: { $0.id == agent.id }) == true,
                               // The poll repeats; an unchanged answer must not republish.
                               self?.children[agent.id] != rows {
                                self?.children[agent.id] = rows
                            }
                        } catch {
                            guard !Task.isCancelled, self?.client === client else { return }
                            if self?.children[agent.id] != nil { self?.children.removeValue(forKey: agent.id) }
                        }
                    }
                    try? await Task.sleep(for: interval)
                }
            }
        }

        func pane(for sessionID: SessionID) -> RemotePaneSession? {
            panes[sessionID]
        }
    }

    static let defaultsKey = "shepherd.remote.hosts"
    static let notInFleetKey = "shepherd.remote.hosts.notInFleet"

    /// Macs this app was a client of before Fleet was how Macs connect: not connected any more, listed under Settings ▸ Fleet ▸ Macs
    /// until each is added to the fleet (its saved address is a route to it) or dismissed.
    private(set) var notInFleet: [HostConfig] = []
    static let fleetMembersKey = "shepherd.remote.hosts.fleetMembers"
    /// The connections that stand for a Mac of the fleet (`FleetConnections` matched or made them): only these are dropped when their Mac
    /// leaves it. Saved, so a Mac removed while the app was closed is dropped at the next launch.
    var fleetMembers: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.fleetMembersKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.fleetMembersKey) }
    }

    @ObservationIgnored var onProjectionChanged: (() -> Void)?
    /// Whether the app leaves the next workspace the background host on this Mac pushes unadopted when a newer
    /// one is already queued behind it (`StateAdoption`). Asked before the connection holds the push: a push it
    /// leaves is held without its projection, which the push behind it runs.
    @ObservationIgnored var leavesQueuedLocalHostState: (() -> Bool)?
    /// Each workspace the background host on this Mac pushes, after its connection holds it, and whether a
    /// newer push is already queued behind it.
    @ObservationIgnored var onLocalHostState: ((ShepherdState, _ newerQueued: Bool) -> Void)?
    /// An agent's notify tool on the background host on this Mac, for the app to post.
    @ObservationIgnored var onLocalAgentNotify: ((AgentID, String, String) -> Void)?
    /// What a Settings page shows changed on the background host on this Mac.
    @ObservationIgnored var onLocalSettingsChanged: ((RemoteSettingsPage) -> Void)?
    /// The background host on this Mac's design systems changed.
    @ObservationIgnored var onLocalDesignSystemsChanged: (() -> Void)?
    /// A tool call, or a line said, in a thread of the background host on this Mac.
    @ObservationIgnored var onLocalToolFinished: ((AgentID, String) -> Void)?
    @ObservationIgnored var onLocalThreadNotice: ((AgentID, String) -> Void)?
    /// Every app's run on the background host on this Mac (`appsChanged`): Settings › Apps follows.
    @ObservationIgnored var onLocalAppsChanged: (([RemoteAppProcess]) -> Void)?
    /// Why one of the background host on this Mac's agents waits with its pi stopped; nil once it starts again.
    @ObservationIgnored var onLocalAgentStartProblem: ((AgentID, NativeStartProblem?) -> Void)?
    /// The background host on this Mac's automations changed, or one of them posts a banner.
    @ObservationIgnored var onLocalAutomationsChanged: (() -> Void)?
    @ObservationIgnored var onLocalAutomationNotify: ((String, String) -> Void)?
    /// The background host on this Mac's threads' pull request links and kept-open notes.
    @ObservationIgnored var onLocalPullRequestLinks: (([AgentID: ThreadPullRequest], [AgentID: String]) -> Void)?
    /// A design's thread notes changed on the background host on this Mac.
    @ObservationIgnored var onLocalDesignNotesChanged: ((DesignID) -> Void)?
    /// A design's Git state changed on the background host on this Mac.
    @ObservationIgnored var onLocalDesignGitChanged: ((DesignID) -> Void)?
    /// How this Mac's own Import is going on the background host on this Mac.
    @ObservationIgnored var onLocalDesignImportProgress: ((DesignImportProgress) -> Void)?
    @ObservationIgnored var onDropError: ((String) -> Void)?
    /// A host connected (again): what waits on it can go now (Settings ▸ Instructions' sync).
    @ObservationIgnored var onHostConnected: ((UUID) -> Void)?
    /// This app's build, compared with the background host's (`BackgroundHostClient.asksToDrain`).
    @ObservationIgnored var appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    @ObservationIgnored var onProjectExecutorConnected: ((ProjectHostReference) -> Void)?
    @ObservationIgnored var onProjectExecutionChanged: ((ProjectHostReference, ProjectExecutionKey) -> Void)?
    /// A design a host serves changed (one on screen here): its files' revision, its comments',
    /// or both.
    @ObservationIgnored var onDesignChanged: ((UUID, DesignID, UInt64?, UInt64?) -> Void)?
    /// A host said something about an agent's browser (`BrowserDrivePush`): the host, the client
    /// that heard it (an answer goes back on it) and the push.
    @ObservationIgnored var onBrowserDrive: ((UUID, RemoteHostClient, BrowserDrivePush) -> Void)?
    /// A board the background host on this Mac asks this app to draw (`DesignRelayJob`).
    @ObservationIgnored var onDesignRelay: ((RemoteHostClient, Int, DesignRelayJob) -> Void)?
    /// What the background host on this Mac asks of this app's window (`AppRelayJob`).
    @ObservationIgnored var onAppRelay: ((RemoteHostClient, Int, AppRelayJob) -> Void)?
    /// A host hinted that a subscribed thread has a newer revision (`native.revisions.v1`): one callback
    /// for every window; at most one per agent per 250 ms from the host. A hint to pull, never content.
    @ObservationIgnored var onNativeThreadChanged: ((RemoteAgentRef) -> Void)?
    /// What each host was asked to hint about, and the threads on screen to ask for (`updateThreadHints`).
    @ObservationIgnored private var threadHints = RemoteThreadHints()
    @ObservationIgnored private var liveThreads: Set<RemoteAgentRef> = []
    /// The background host's threads polling on screen, as the app's own.
    @ObservationIgnored private var localLiveThreads: Set<AgentID> = []
    /// Every host's design files, by hash (in memory).
    let designCache = RemoteDesignCache()
    /// Every connection, the background host on this Mac's included. Lookups by host id use it.
    private(set) var allConnections: [Connection] = [] { didSet { onProjectionChanged?() } }
    /// The hosts the UI lists: the paired ones. The background host on this Mac is transport only:
    /// its workspace is the app's own (`ShepherdViewModel.localHost`), so no host list, picker or
    /// page shows it. Lookups by host id (`allConnections`) still find it: requests the app routes
    /// to it go that way.
    var connections: [Connection] { pairedConnections }
    /// The background host on this Mac: This Mac's Settings pages read and change its stores. Nil
    /// before it is added; throws while the host is away.
    func thisMacHost() throws -> RemoteHostClient? {
        guard let host = localHost else { return nil }
        guard host.phase == .connected, let client = host.client else { throw RemoteHostClientError.disconnected }
        return client
    }

    /// The background host on this Mac, when the app is its client.
    var localHost: Connection? { allConnections.first(where: \.isLocalHost) }

    private let defaults: UserDefaults
    private let childRefreshInterval: Duration
    /// False keeps every host disconnected: a unit test's hosts, which never open a socket.
    private let connects: Bool

    var hosts: [HostConfig] {
        allConnections.map(\.config)
    }

    /// The remote threads polling on screen in any window: each connected host that offers revision hints is asked
    /// for its own ordinary ones (`RemoteThreadHints`), only when that set changes. Polling stays as the fallback.
    func updateThreadHints(live: Set<RemoteAgentRef>) {
        liveThreads = live
        sendThreadHints()
    }

    /// `updateThreadHints` for the background host's threads, which the app keys as its own.
    func updateLocalThreadHints(live: Set<AgentID>) {
        localLiveThreads = live
        sendThreadHints()
    }

    private func sendThreadHints() {
        let hinting = allConnections.filter { connection in
            connection.phase == .connected && connection.client?.capabilities.contains(RemoteProtocol.nativeThreadRevisionsCapability) == true
        }
        let byID = Dictionary(uniqueKeysWithValues: hinting.map { ($0.id, $0) })
        let local = localHost.map { host in localLiveThreads.map { RemoteAgentRef(hostID: host.id, agentID: $0) } } ?? []
        let plan = threadHints.plan(live: liveThreads.union(local), hosts: Set(byID.keys)) { ref in
            guard let state = byID[ref.hostID]?.state, let agent = state.agents.first(where: { $0.id == ref.agentID }) else { return false }
            return state.isOrdinaryThread(agent)
        }
        for (host, ids) in plan {
            guard let client = byID[host]?.client else { continue }
            Task { [weak self, weak client] in
                do { try await client?.subscribeNativeThreads(ids) }
                catch {
                    // Refused or dropped: the poll carries on, and the next change (or reconnect) asks again.
                    guard let self, self.allConnections.first(where: { $0.id == host })?.client === client else { return }
                    self.threadHints.forget(host)
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard, childRefreshInterval: Duration = .seconds(3), connects: Bool = true) {
        self.defaults = defaults
        self.childRefreshInterval = childRefreshInterval
        self.connects = connects
        let saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([HostConfig].self, from: $0) } ?? []
        allConnections = saved.filter(\.fleetManaged).map { Connection(config: $0, designCache: designCache) }
        // A client-only Mac is kept as a row to add or dismiss, once: its saved address is the one thing the person would retype.
        let moved = saved.filter { !$0.fleetManaged }
        notInFleet = (defaults.data(forKey: Self.notInFleetKey).flatMap { try? JSONDecoder().decode([HostConfig].self, from: $0) } ?? []) + moved
        if !moved.isEmpty { persist() }
        for connection in allConnections {
            connect(connection)
        }
    }

    /// The hosts the user added: every connection but the background host on this Mac.
    var pairedConnections: [Connection] { allConnections.filter { !$0.isLocalHost } }

    /// The background host on this Mac, through its local socket at `socket`; not persisted.
    @discardableResult
    func addLocalHost(name: String, socket: String) -> Connection {
        let connection = Connection(config: HostConfig(name: name, host: "", port: 0, token: "", localSocket: socket),
                                    designCache: designCache)
        allConnections.insert(connection, at: 0)
        connect(connection)
        return connection
    }

    /// Connects a host. `FleetConnections` adds a Mac of the fleet this way (`fleetManaged`, `id` its fleet id), and follows it as the fleet
    /// changes; nothing else adds a host (a Mac is added to the fleet, never as a client), so a connection that isn't `fleetManaged` is
    /// one a test makes, and the fleet leaves it alone.
    @discardableResult
    func addHost(id: UUID = UUID(), name: String, host: String, port: UInt16, token: String, ownToken: Bool = false,
                 fleetManaged: Bool = false) -> UUID {
        let config = HostConfig(id: id, name: name, host: host, port: port, token: token, fleetManaged: fleetManaged, ownToken: ownToken)
        let connection = Connection(config: config, designCache: designCache)
        allConnections.append(connection)
        persist()
        connect(connection)
        return config.id
    }

    /// Update a host's config and reconnect with the new values.
    func updateHost(id: UUID, name: String, host: String, port: UInt16, token: String) {
        guard let connection = allConnections.first(where: { $0.id == id }) else { return }
        connection.endpointID = UUID()
        var config = connection.config
        if config.host != host || config.port != port || config.token != token {
            config.bindingID = UUID()
        }
        config.name = name
        config.host = host
        config.port = port
        config.token = token
        connection.config = config
        persist()
        reconnect(id: id)
    }

    /// This app was given a token of its own for this fleet Mac: it replaces the shared one, and the
    /// binding stays (the Mac is the same).
    func useOwnToken(id: UUID, token: String) {
        guard let connection = allConnections.first(where: { $0.id == id }) else { return }
        connection.config.token = token
        connection.config.ownToken = true
        persist()
        reconnect(id: id)
    }

    /// The fleet says this Mac is now at `host`:`port`, or has another name: its connection follows, and keeps its binding (the Mac is
    /// the same).
    func follow(id: UUID, name: String, host: String, port: UInt16) {
        guard let connection = allConnections.first(where: { $0.id == id }) else { return }
        connection.endpointID = UUID()
        connection.config.name = name
        connection.config.host = host
        connection.config.port = port
        persist()
        reconnect(id: id)
    }

    func removeHost(id: UUID) {
        guard let index = allConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = allConnections.remove(at: index)
        connection.reconnectTask?.cancel()
        connection.stopChildRefresh()
        connection.client?.disconnect()
        connection.client = nil
        connection.designs.connect(nil, available: false)
        for pane in connection.panes.values {
            pane.phase = .failed("host removed")
        }
        connection.panes.removeAll()
        persist()
    }

    func reconnect(id: UUID) {
        guard let connection = allConnections.first(where: { $0.id == id }) else { return }
        connection.reconnectTask?.cancel()
        connection.phase = .connecting
        connection.stopChildRefresh()
        for pane in connection.panes.values {
            pane.detach()
            pane.phase = .failed("reconnecting")
        }
        connection.panes.removeAll()
        let oldClient = connection.client
        connection.client = nil
        connection.designs.connect(nil, available: false)
        oldClient?.disconnect()
        connection.reconnectDelay = .seconds(1)
        connect(connection)
    }

    /// A row of Settings ▸ Fleet ▸ Macs for a Mac that was a client: added to the fleet (it is no longer a row) or dismissed.
    func dismissNotInFleet(id: UUID) {
        notInFleet.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(allConnections.map(\.config).filter { $0.localSocket == nil }) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        if let data = try? JSONEncoder().encode(notInFleet) { defaults.set(data, forKey: Self.notInFleetKey) }
    }

    // MARK: - Connection lifecycle

    private func connect(_ connection: Connection) {
        guard connects, allConnections.contains(where: { $0 === connection }) else { return }
        connection.retryPending = false
        connection.onProjectionChanged = { [weak self] in self?.onProjectionChanged?() }
        let hostID = connection.id
        connection.designs.onDesignChanged = { [weak self] design, revision, comments in
            self?.onDesignChanged?(hostID, design, revision, comments)
        }
        connection.transportID = UUID()
        connection.phase = .connecting
        connection.reconnectTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            let client = connection.config.localSocket.map(RemoteHostClient.init(localSocket:)) ?? RemoteHostClient()
            self.wire(client: client, to: connection)
            connection.client = client
            let stateGeneration = connection.stateGeneration
            do {
                let state = try await client.connect(
                    host: connection.config.host,
                    port: connection.config.port,
                    token: connection.config.token,
                    clientName: Host.current().localizedName ?? "shepherd",
                    capabilities: RemoteProtocol.clientCapabilities
                        + (connection.isLocalHost ? [RemoteProtocol.localThreadsCapability] : [])
                )
                guard !Task.isCancelled,
                      connection.client === client,
                      self.allConnections.contains(where: { $0 === connection }) else {
                    client.disconnect()
                    return
                }
                if connection.stateGeneration == stateGeneration {
                    connection.state = state
                    if connection.isLocalHost { self.onLocalHostState?(state, false) }
                }
                connection.phase = .connected
                self.rebindPanes(connection, to: client)
                // A new connection holds no subscriptions: ask again for the threads on screen.
                self.threadHints.forget(connection.id)
                self.sendThreadHints()
                connection.designs.connect(client, available: client.capabilities.contains(RemoteProtocol.designsCapability))
                connection.startChildRefresh(client: client, every: childRefreshInterval)
                connection.reconnectDelay = .seconds(1)
                if connection.isLocalHost, BackgroundHostClient.asksToDrain(appBuild: self.appBuild, hostBuild: client.hostBuild,
                                                                          capabilities: client.capabilities) {
                    Task { do { try await client.drain() } catch { NSLog("Shepherd: background host didn't drain: \(error)") } }
                }
                self.onHostConnected?(connection.id)
                self.onProjectExecutorConnected?(.remote(hostID: connection.config.id, bindingID: connection.config.bindingID))
            } catch {
                if connection.client === client {
                    connection.client = nil
                }
                client.disconnect()
                guard !Task.isCancelled else { return }
                let failure = RemoteHostFailure(error)
                connection.phase = .failed(failure)
                if failure.retries { self.scheduleReconnect(connection) }
            }
        }
    }

    private func wire(client: RemoteHostClient, to connection: Connection) {
        let clientID = ObjectIdentifier(client)
        client.onProjectExecutionChanged = { [weak self, weak connection] key, _ in
            guard let connection, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onProjectExecutionChanged?(.remote(hostID: connection.config.id, bindingID: connection.config.bindingID), key)
        }
        client.onSettingsChanged = { [weak self, weak connection] page in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalSettingsChanged?(page)
        }
        client.onToolFinished = { [weak self, weak connection] agentID, tool in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalToolFinished?(agentID, tool)
        }
        client.onDesignNotesChanged = { [weak self, weak connection] designID in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalDesignNotesChanged?(designID)
        }
        client.onDesignGitChanged = { [weak self, weak connection] designID in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalDesignGitChanged?(designID)
        }
        client.onDesignImportProgress = { [weak self, weak connection] step in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalDesignImportProgress?(step)
        }
        client.onThreadNotice = { [weak self, weak connection] agentID, message in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalThreadNotice?(agentID, message)
        }
        client.onAppsChanged = { [weak self, weak connection] processes in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalAppsChanged?(processes)
        }
        client.onAgentStartProblem = { [weak self, weak connection] agentID, problem in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalAgentStartProblem?(agentID, problem)
        }
        client.onAutomationsChanged = { [weak self, weak connection] in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalAutomationsChanged?()
        }
        client.onAutomationNotify = { [weak self, weak connection] title, body in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalAutomationNotify?(title, body)
        }
        client.onPullRequestLinks = { [weak self, weak connection] links, notes in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalPullRequestLinks?(links, notes)
        }
        client.onAgentNotify = { [weak self, weak connection] agentID, title, body in
            guard let connection, connection.isLocalHost, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onLocalAgentNotify?(agentID, title, body)
        }
        client.onStateChanged = { [weak self, weak connection, weak client] state in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID else { return }
            // This Mac's host is the app's workspace, which leaves a push unadopted when a newer one is queued behind it.
            // The connection holds that push without the projection, which the newer one runs, and the app is told so.
            let skipped = connection.isLocalHost && client?.newerStateQueued == true && self?.leavesQueuedLocalHostState?() == true
            defer { if connection.isLocalHost { self?.onLocalHostState?(state, skipped || client?.newerStateQueued == true) } }
            let liveSessionIDs = Set(state.tabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) })
            for sessionID in Array(connection.panes.keys) where !liveSessionIDs.contains(sessionID) {
                connection.panes.removeValue(forKey: sessionID)?.detach()
            }
            connection.stateGeneration &+= 1
            if skipped { connection.skip(state) } else { connection.state = state }
        }
        client.onOutputConsumed = { [weak connection] sessionID, data, completion in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID,
                  let pane = connection.panes[sessionID] else { completion(); return }
            pane.receive(data, completion: completion)
        }
        client.onSessionExited = { [weak connection] sessionID, code in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID,
                  let pane = connection.panes.removeValue(forKey: sessionID) else { return }
            pane.phase = .exited(code)
        }
        client.onDesignChanged = { [weak connection] design, revision, comments in
            guard let connection, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            connection.designs.changed(design, revision: revision, commentsRevision: comments)
        }
        client.onDesignSystemsChanged = { [weak self, weak connection] in
            guard let connection, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            connection.designs.systemsChanged()
            if connection.isLocalHost { self?.onLocalDesignSystemsChanged?() }
        }
        client.onNativeThreadChanged = { [weak self, weak connection] agent in
            guard let connection, connection.client.map(ObjectIdentifier.init) == clientID else { return }
            self?.onNativeThreadChanged?(RemoteAgentRef(hostID: connection.id, agentID: agent))
        }
        client.onBrowserDrive = { [weak self, weak connection, weak client] push in
            guard let self, let connection, let client, connection.client === client else { return }
            self.onBrowserDrive?(connection.id, client, push)
        }
        // Only the background host on this Mac asks; its paths are this Mac's.
        client.onDesignRelay = { [weak self, weak connection, weak client] token, job in
            guard let self, let connection, let client, connection.client === client, connection.isLocalHost else { return }
            self.onDesignRelay?(client, token, job)
        }
        client.onAppRelay = { [weak self, weak connection, weak client] token, job in
            guard let self, let connection, let client, connection.client === client, connection.isLocalHost else { return }
            self.onAppRelay?(client, token, job)
        }
        client.onCapabilitiesChanged = { [weak self, weak connection, weak client] capabilities in
            guard let connection, let client, connection.client === client, connection.phase == .connected else { return }
            connection.designs.connect(client, available: capabilities.contains(RemoteProtocol.designsCapability))
            self?.onProjectionChanged?()
        }
        client.onDisconnected = { [weak self, weak connection] reason in
            guard let self, let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID else { return }
            connection.phase = .failed(RemoteHostFailure(disconnect: reason))
            connection.client = nil
            connection.designs.connect(nil, available: false)
            connection.stopChildRefresh()
            if connection.isLocalHost {
                // This Mac's host keeps its terminals across a dropped link: each pane keeps its
                // surface and attaches again once the store reconnects (`rebindPanes`).
                for pane in connection.panes.values { pane.suspend() }
            } else {
                for pane in connection.panes.values {
                    pane.phase = .failed("disconnected: \(reason)")
                }
                connection.panes.removeAll()
            }
            if self.allConnections.contains(where: { $0 === connection }) {
                self.scheduleReconnect(connection)
            }
        }
    }

    /// The panes a dropped link kept (This Mac's) attach on the new client, in place; the host's
    /// replay starts with a reset, so each redraws its screen. A pane whose session the host no
    /// longer has (it restarted) fails as before.
    private func rebindPanes(_ connection: Connection, to client: RemoteHostClient) {
        let live = Set(connection.state.tabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) })
        for (sessionID, pane) in connection.panes {
            if live.contains(sessionID) {
                pane.rebind(client)
            } else {
                pane.phase = .failed("the host restarted")
                connection.panes.removeValue(forKey: sessionID)
            }
        }
    }

    private func scheduleReconnect(_ connection: Connection) {
        // Exponential backoff, capped at 30s. Reset on successful connect. The host on this Mac
        // restarts in about a second (an update's drain, a crash) and a try costs a local connect:
        // 0.25 s, then doubling, never more than 2 s.
        let delay = connection.isLocalHost ? min(connection.reconnectDelay / 4, .seconds(2)) : connection.reconnectDelay
        connection.reconnectDelay = min(.seconds(30), connection.reconnectDelay * 2)
        connection.retryPending = true
        connection.reconnectTask = Task { [weak self, weak connection] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let connection else { return }
            self.connect(connection)
        }
    }

    // MARK: - Remote mutations

    func agentQuery(_ target: RemoteAgentRef, query: RemoteAgentQuery, endpointID: UUID? = nil, transportID: UUID? = nil) async throws -> RemoteAgentResult {
        guard let connection = allConnections.first(where: { $0.id == target.hostID }),
              connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "Host is disconnected. Reconnect before trying again.")
        }
        guard endpointID == nil || endpointID == connection.endpointID,
              transportID == nil || transportID == connection.transportID else {
            throw RemoteHostClientError.rejected(code: "host_changed", message: "Host connection changed. Reopen this action and inspect it again.")
        }
        let result = try await client.agentQuery(agentID: target.agentID, query: query)
        guard connection.client === client,
              endpointID == nil || endpointID == connection.endpointID else {
            throw RemoteHostClientError.outcomeUnknown(message: "Host changed after the request was sent. Check the original host operation status before retrying.")
        }
        return result
    }

    /// A remote agent's native thread, served by its host.
    func nativeThread(_ target: RemoteAgentRef, request: NativeThreadRequest) async throws -> NativeThreadResult {
        guard let connection = allConnections.first(where: { $0.id == target.hostID }),
              connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.nativeThread(agentID: target.agentID, request: request)
    }

    /// Queue `text` as the remote agent's next user turn (a follow-up while it runs).
    func sendUserMessage(_ target: RemoteAgentRef, text: String) async throws {
        guard case .snapshot(let snapshot) = try await nativeThread(target, request: .snapshot()),
              !snapshot.piSessionID.isEmpty else {
            throw RemoteHostClientError.rejected(code: "not_ready", message: "The agent is not ready yet. Try again in a moment.")
        }
        let result = try await nativeThread(target, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
            operationID: UUID(), text: text, delivery: .followUp))
        if case .failure(let code, let message) = result { throw RemoteHostClientError.rejected(code: code, message: message) }
    }

    /// A host's fleet as a client reads it (`fleet.view.v1`): the moves of its threads, with how they stand.
    func fleetRead(hostID: UUID) async throws -> FleetSnapshot {
        guard let connection = allConnections.first(where: { $0.id == hostID }),
              connection.phase == .connected, let client = connection.client,
              client.capabilities.contains(RemoteProtocol.fleetViewCapability) else { throw RemoteHostClientError.disconnected }
        return try await client.fleetRead().snapshot
    }

    func agentAction(_ target: RemoteAgentRef, action: RemoteAgentAction) async throws {
        guard let connection = allConnections.first(where: { $0.id == target.hostID }),
              connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.disconnected
        }
        try await client.agentAction(agentID: target.agentID, action: action)
    }

    /// Manage one of a host's automations, or read its runs.
    @discardableResult
    func automation(_ key: AutomationKey, request: RemoteAutomationRequest) async throws -> RemoteAutomationResult {
        guard let connection = allConnections.first(where: { $0.id == key.host }),
              connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.automation(key.automation, request: request)
    }

    /// Reads or saves a host's root instructions (Settings ▸ Instructions).
    @discardableResult
    func instructions(hostID: UUID, request: RemoteInstructionsRequest = .fetch) async throws -> InstructionsSnapshot {
        guard let connection = allConnections.first(where: { $0.id == hostID }),
              connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.instructions(request)
    }

    func projects(hostID: UUID, endpointID: UUID?, request: RemoteProjectsRequest) async throws -> RemoteProjectsResult {
        guard let connection = allConnections.first(where: { $0.id == hostID }),
              connection.phase == .connected, let client = connection.client else { throw RemoteHostClientError.disconnected }
        guard endpointID == connection.endpointID else {
            throw RemoteHostClientError.rejected(code: "host_changed", message: "Host changed. Reopen this space before editing it.")
        }
        let result = try await client.projects(request)
        guard connection.client === client, endpointID == connection.endpointID else {
            throw RemoteHostClientError.outcomeUnknown(message: "Host changed after the request was sent. Check the original space before retrying.")
        }
        return result
    }

    /// One Projects request to the host that owns the project. The request names the owner's own IDs.
    func logicalProjects(hostID: UUID, request: LogicalProjectsRequest) async throws -> LogicalProjectsResult {
        guard let connection = allConnections.first(where: { $0.id == hostID }),
              connection.phase == .connected, let client = connection.client else { throw RemoteHostClientError.disconnected }
        let endpoint = connection.endpointID
        let result = try await client.logicalProjects(request)
        // A host retargeted mid-request answered for another machine: do not trust it.
        guard connection.client === client, connection.endpointID == endpoint else {
            throw RemoteHostClientError.outcomeUnknown(message: "Host changed after the request was sent. Check the original project before retrying.")
        }
        return result
    }

    /// One Project runtime request to the host that owns the project (its hosts list, a native read, an action). A host that
    /// changed identity mid-request answered for another machine and is not trusted.
    func projectRuntime(hostID: UUID, request: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult {
        guard let connection = allConnections.first(where: { $0.id == hostID }),
              connection.phase == .connected, let client = connection.client else { throw RemoteHostClientError.disconnected }
        let endpoint = connection.endpointID
        let result = try await client.projectRuntime(request)
        guard connection.client === client, connection.endpointID == endpoint else {
            throw RemoteHostClientError.outcomeUnknown(message: "Host changed after the request was sent. Check the original project before retrying.")
        }
        return result
    }

    func creationOptions(hostID: UUID, spaceID: SpaceID, cwd: String?, fetchFirst: Bool?) async throws -> RemoteCreationOptions {
        guard let connection = allConnections.first(where: { $0.id == hostID }), connection.phase == .connected, let client = connection.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.creationOptions(spaceID: spaceID, cwd: cwd, fetchFirst: fetchFirst)
    }

    /// List a directory on a host (remote pickers). Empty path = host home.
    func listDir(hostID: UUID, path: String) async throws -> RemoteHostClient.DirListing {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.listDir(path: path)
    }

    /// The host's pi model ids and default (remote model picker).
    func listModels(hostID: UUID) async throws -> ModelListing {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.listModels()
    }

    /// Issues & PRs through the background host on this Mac, which knows its threads' folders.
    func localForge(_ request: RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError> {
        guard let client = localHost?.client else { return .failure(ForgeError(.unreachable, "Shepherd's background service isn't running.")) }
        return await client.forge(request)
    }

    /// The thread the app shows and the pane with its keyboard, told to the background host on
    /// this Mac (`focusThread`).
    func focusLocalThread(_ agentID: AgentID?, pane: PaneID? = nil) {
        guard let client = localHost?.client, localHost?.phase == .connected else { return }
        Task { try? await client.focusThread(agentID, pane: pane) }
    }

    /// Starts a thread on the background host on this Mac (`startThread`).
    func startThread(hostID: UUID, _ thread: RemoteThreadStart) async throws -> AgentID {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else { throw RemoteHostClientError.disconnected }
        return try await client.startThread(thread)
    }

    /// Changes a space of the background host on this Mac (`spaceAction`).
    func spaceAction(hostID: UUID, spaceID: SpaceID, _ action: RemoteSpaceAction) async throws {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else { throw RemoteHostClientError.disconnected }
        try await client.spaceAction(action, spaceID: spaceID)
    }

    /// Create a space on a host from a host-side directory path.
    func addSpace(hostID: UUID, path: String) async throws -> SpaceID {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.addSpace(path: path)
    }

    /// This Mac's background host's space registry (`projectRequest`): the space it registered or edited.
    func projectRequest(hostID: UUID, _ request: RemoteProjectRequest) async throws -> SpaceID {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else { throw RemoteHostClientError.disconnected }
        return try await client.projectRequest(request)
    }

    /// A space's branches on a host (`creationBranches`).
    func creationBranches(hostID: UUID, spaceID: SpaceID) async throws -> ChangesBranches {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else { throw RemoteHostClientError.disconnected }
        return try await client.creationBranches(spaceID: spaceID)
    }

    /// Create an agent on a host; it appears in the sidebar via state push.
    @discardableResult
    func createAgent(
        hostID: UUID,
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?,
        worktreeBranch: String? = nil,
        worktreeBase: String? = nil,
        worktreeFetchFirst: Bool? = nil,
        initialImages: [NativeImage] = [],
        serviceTier: ServiceTier? = nil
    ) async throws -> AgentID {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.createAgent(
            spaceID: spaceID,
            cwd: cwd,
            model: model,
            thinking: thinking,
            initialPrompt: initialPrompt,
            worktreeBranch: worktreeBranch,
            worktreeBase: worktreeBase,
            worktreeFetchFirst: worktreeFetchFirst,
            initialImages: initialImages,
            serviceTier: serviceTier
        )
    }

    // MARK: - Remote panes

    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        for pane in allConnections.flatMap({ $0.panes.values }) {
            pane.terminal.updateAppearance(terminal)
        }
    }

    func updateSurfaceConfiguration() {
        for pane in allConnections.flatMap({ $0.panes.values }) {
            pane.terminal.updateConfiguration(
                fontSize: AppSettings.shared.terminalFontSize,
                fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
                extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds
            )
        }
    }

    func openPane(hostID: UUID, agentID: AgentID, relativeTo paneID: PaneID, axis: SplitAxis) async throws -> PaneID {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.openPane(agentID: agentID, relativeTo: paneID, axis: axis)
    }

    func closePane(hostID: UUID, agentID: AgentID, paneID: PaneID) async throws {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        try await client.closePane(agentID: agentID, paneID: paneID)
    }

    func resizePaneSplit(hostID: UUID, agentID: AgentID, split: PaneNode, ratio: Double) async throws {
        guard let client = allConnections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        try await client.resizePaneSplit(agentID: agentID, split: split, ratio: ratio)
    }

    /// The pane session for a remote agent's terminal, creating and attaching
    /// on first use. Returns nil while the host is not connected.
    func paneSession(
        connection: Connection,
        sessionID: SessionID
    ) -> RemotePaneSession? {
        guard let client = connection.client else { return nil }
        if let existing = connection.panes[sessionID] {
            return existing
        }
        let pane = RemotePaneSession(sessionID: sessionID, client: client)
        pane.onDropError = { [weak self] in self?.onDropError?($0) }
        connection.panes[sessionID] = pane
        pane.start()
        return pane
    }

    /// Detach a pane's stream (view went away; the host session keeps running).
    func closePane(connection: Connection, sessionID: SessionID) {
        guard let pane = connection.panes.removeValue(forKey: sessionID) else { return }
        pane.detach()
    }

    func closePanes(connection: Connection, sessionIDs: [SessionID]) {
        for sessionID in sessionIDs {
            closePane(connection: connection, sessionID: sessionID)
        }
    }
}

/// One remote pane's terminal bridge: an AppTerminalModel fed from `output`
/// frames, with input and debounced resize forwarded to the host, which owns
/// the session lifecycle.
@MainActor
@Observable
final class RemotePaneSession {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
        case exited(Int32?)
    }

    /// How long a surface waits for its first real grid before replaying anyway.
    static let gridWaitNanoseconds: UInt64 = 400_000_000

    let sessionID: SessionID
    let terminal: AppTerminalModel
    var phase: Phase = .connecting

    @ObservationIgnored var onDropError: ((String) -> Void)?
    @ObservationIgnored private var uploading = false
    @ObservationIgnored private weak var client: RemoteHostClient?
    @ObservationIgnored private(set) var lastCols = 80
    @ObservationIgnored private(set) var lastRows = 24
    @ObservationIgnored private var hasReportedGrid = false
    @ObservationIgnored private var attachStarted = false
    /// Debounce the initial attach and later resizes to a settled grid.
    /// Per-frame reports SIGWINCH-spam the child and fill scrollback with
    /// duplicated prompts.
    @ObservationIgnored private var viewportDebounce: Task<Void, Never>?
    private static let resizeSettleMs = 120

    init(sessionID: SessionID, client: RemoteHostClient) {
        self.sessionID = sessionID
        self.client = client
        self.terminal = AppTerminalModel(
            fontSize: AppSettings.shared.terminalFontSize,
            fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
            terminal: ThemeManager.shared.current.terminal,
            extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds,
            acceptsFileDrops: true
        )
        terminal.maximumDropBytes = RemoteProtocol.uploadMaxBytes
        terminal.onFileDropError = { [weak self] in self?.onDropError?($0) }
        terminal.onFileDrop = { [weak self] urls in
            guard let self, let client = self.client else { return }
            guard !self.uploading else { self.onDropError?("A file drop is already uploading"); return }
            self.uploading = true
            Task {
                defer { self.uploading = false }
                do {
                    var paths: [String] = []
                    for url in urls { paths.append(try await client.upload(file: url, sessionID: self.sessionID)) }
                    let text = paths.map(shellQuoted).joined(separator: " ") + " "
                    try await client.paste(sessionID: self.sessionID, text: text, submit: false)
                } catch { self.onDropError?(String(describing: error)) }
            }
        }
        terminal.onInput = { [weak self] data in
            guard let self, let client = self.client else { return }
            client.write(sessionID: self.sessionID, data: data)
        }
        terminal.onResize = { [weak self] cols, rows in
            self?.noteGrid(cols: cols, rows: rows)
        }
        // Selecting a local thread unmounts this pane's view (remote panes
        // are conditional, unlike the permanently mounted local layouts);
        // returning creates a fresh, blank ghostty surface. Mirror the local
        // resync: release the replacement, then re-attach so the host
        // re-sends its screen snapshot into the new surface.
        terminal.onSurfaceAttachmentChanged = { [weak self] generation in
            guard let self, let generation else { return }
            _ = self.terminal.replaceWithReplay(Data(), generation: generation)
            guard self.attachStarted, let client = self.client else { return }
            client.detach(sessionID: self.sessionID)
            Task { [weak self] in
                guard let self, let client = self.client else { return }
                // First attachment and replacements both replay: bytes retired while there
                // was no surface are represented by this authoritative screen, not buffered.
                _ = try? await client.attach(
                    sessionID: self.sessionID,
                    cols: self.lastCols,
                    rows: self.lastRows
                )
            }
        }
    }

    /// Record a surface grid. Internal so the attach debounce can be tested
    /// without relying on AppKit callback timing.
    func noteGrid(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        hasReportedGrid = true
        // Ghostty can report once before the configured font metrics settle.
        // Wait for the final grid before attaching and requesting its replay.
        scheduleViewportSync()
    }

    private func scheduleViewportSync() {
        viewportDebounce?.cancel()
        viewportDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.resizeSettleMs))
            guard !Task.isCancelled, let self, let client = self.client else { return }
            if self.attachStarted {
                client.resize(sessionID: self.sessionID, cols: self.lastCols, rows: self.lastRows)
            } else {
                self.attachIfNeeded()
            }
        }
    }

    /// Attach once a grid is known; also called with a grace fallback so a
    /// surface that never lays out still attaches at 80×24.
    func start() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: RemotePaneSession.gridWaitNanoseconds)
            guard let self, !self.attachStarted, !self.hasReportedGrid else { return }
            self.attachIfNeeded()
        }
    }

    private func attachIfNeeded() {
        guard !attachStarted, client != nil else { return }
        attachStarted = true
        let attachCols = lastCols
        let attachRows = lastRows
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                _ = try await client.attach(sessionID: self.sessionID, cols: attachCols, rows: attachRows)
                if case .connecting = self.phase {
                    self.phase = .live
                }
            } catch {
                self.phase = .failed(String(describing: error))
            }
        }
    }

    func receive(_ data: Data, completion: @escaping @Sendable () -> Void) {
        terminal.feed(data, completion: completion)
    }

    func detach() {
        viewportDebounce?.cancel()
        client?.detach(sessionID: sessionID)
    }

    /// The link dropped and the store will reconnect: the surface stays as it is, waiting.
    func suspend() {
        viewportDebounce?.cancel()
        attachStarted = false
        phase = .connecting
    }

    /// The store reconnected: attach the same surface on the new client at its last grid.
    func rebind(_ client: RemoteHostClient) {
        self.client = client
        attachStarted = false
        phase = .connecting
        attachIfNeeded()
    }
}

extension RemoteHostStore.Phase {
    enum Kind: Hashable { case disconnected, connecting, connected, failed(RemoteHostFailure.Kind) }

    /// The phase with its failure's kind, not its detail: what the workspace's placeholders
    /// cross-fade between (a retry that fails the same way again changes nothing on screen).
    var kind: Kind {
        switch self {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .failed(let failure): .failed(failure.kind)
        }
    }
}
