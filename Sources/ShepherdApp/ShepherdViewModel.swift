import Foundation
import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

/// Disambiguates from SwiftUI.Tab for every file in this module.
typealias Tab = ShepherdCore.Tab

struct NewAgentConfig {
    var spaceID: SpaceID
    var workingDirectory: String
    var model: String?
    var thinking: ThinkingLevel
    var initialPrompt: String?
    /// A caller-chosen starting name (worktree agents wear their branch
    /// leaf). Provisional like a prompt-derived name: pi's namer retitles it
    /// from the agent's first prompt when auto-naming is on.
    var initialName: String?
    /// The branch of the git worktree this agent was created on, when
    /// Shepherd made one for it. Persisted on the agent so the sidebar can
    /// render it as a worktree of its space.
    var worktreeBranch: String?
    /// The base the worktree branched from; Finalize targets the PR at it.
    var worktreeBase: String?
    /// Actual checkout path for imported worktrees whose directory name does
    /// not follow Shepherd's generated repo-branch convention.
    var worktreePath: String?
    /// An automation's watch agent: spawned with SHEPHERD_AUTOMATION=1 so
    /// the panes extension withholds the automation_* tools (a watcher must
    /// never create watchers).
    var isAutomation = false
    /// Resume an existing pi session (a forked subagent transcript already in the cwd's
    /// session directory) instead of a fresh one keyed by the agent id.
    var piSessionID: String?
}

struct AgentStartFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// GUI-owned view state over the in-process session server's snapshot.
/// Navigation is the sidebar: an agent row shows that agent's thread (and any terminal panes
/// beside it); a space row is a disclosure. Tabs exist only in persisted state as per-agent
/// layout containers — there is no tab UI.
@MainActor
@Observable
final class ShepherdViewModel {
    var state: ShepherdState
    var selectedSpaceID: SpaceID?
    var selectedAgentID: AgentID?
    /// Collapsed space sections in the sidebar tree. A collapsed space shows
    /// only its header; its agents leave the ⌘1–9 order too. Persisted —
    /// collapse choices survive relaunch, unlike selection.
    var collapsedSpaces: Set<SpaceID> = [] {
        didSet {
            sidebarDefaults.set(collapsedSpaces.map(\.rawValue).sorted(), forKey: "shepherd.collapsedSpaces")
        }
    }
    /// Child runs per agent, as published: the palette's Subagents section and the needs-you
    /// mark on an agent's sidebar row.
    /// Ephemeral display state; see `ChildRuns` for the lifecycle rules.
    var childRuns = ChildRuns()
    /// Native diff-review panes keyed by their review leaf. Ephemeral: review
    /// leaves are persisted long enough for layout writes, then purged on the
    /// next app start by the session server.
    var reviewSessions: [PaneID: ReviewSession] = [:]
    /// When each agent entered its current status this run: the sidebar's running elapsed
    /// time. Ephemeral; an agent restored at launch counts from its first report.
    var statusSince: [AgentID: Date] = [:]
    /// ⌘⇧S hides the sidebar. Persisted, like the other sidebar disclosure choices.
    var sidebarHidden = false {
        didSet { sidebarDefaults.set(sidebarHidden, forKey: "shepherd.sidebarHidden") }
    }
    /// The window is too narrow to dock the sidebar (`ShellLayout.sidebar`), so ⇧⌘S overlays
    /// it instead. Written by the window as it resizes; ephemeral.
    var sidebarAutoHidden = false
    /// The overlaid sidebar is showing (narrow window only). Ephemeral.
    var sidebarOverlayShown = false
    /// The sidebar row being dragged, for drop validation while the drag hovers; the drag
    /// payload itself never leaves the process.
    @ObservationIgnored var sidebarDragPayload: String?
    /// The remote agent the workspace is showing (a REMOTE row is selected):
    /// host connection id + agent id on that host. Wins over every local
    /// selection; cleared by ordinary selection. Ephemeral, like all
    /// selection state.
    var selectedRemoteAgent: RemoteAgentRef?
    var remoteFocusedPaneID: PaneID?
    var remoteWorktreeSheet: RemoteAgentRef?
    var remoteWorktreeFinalize = false
    var remoteWorktreeOperationEndpoints: [RemoteAgentRef: UUID] = [:]
    var remoteWorktreeOperationIDs: [RemoteAgentRef: UUID] = [:]
    var hostPRDescriptionGenerator = WorktreePRDescriptionGenerator()
    var hostWorktreeOperations: [UUID: RemoteWorktreeOperation] = [:]
    var hostWorktreeOperationAgents: [UUID: AgentID] = [:]
    var hostBusyWorktrees: Set<String> = []
    var startingCheckoutUsers: [UUID: String] = [:]
    var remoteChildren: [RemoteAgentRef: [ChildRun]] {
        Dictionary(uniqueKeysWithValues: remoteHosts.connections.flatMap { connection in
            connection.children.map { (RemoteAgentRef(hostID: connection.id, agentID: $0.key), $0.value) }
        })
    }
    var reviewDiffLoader: @Sendable (String, String?) async throws -> (files: [DiffFile], reference: String?) = { cwd, reference in
        try await Task.detached(priority: .userInitiated) {
            let resolved = reference == "pr" ? GitDiff.pullRequestReference(cwd: cwd) : reference
            return (try GitDiff.load(cwd: cwd, reference: resolved), resolved)
        }.value
    }
    var remoteReviews: [RemoteAgentRef: ReviewSession] = [:]
    /// Host-side utility terminals (a remote `gh auth login`) opened for a remote agent,
    /// shown in place of the agent's own layout while `remoteInspectingAgent` is set.
    var hostRemoteInspectors: [String: TabID] = [:]
    var remoteInspectorTabs: [RemoteAgentRef: TabID] = [:]
    var remoteInspectingAgent: RemoteAgentRef?
    var remoteInspectionRequest = UUID()
    var remoteRenameTarget: RemoteAgentRef?
    var remoteActionError: String?

    /// Configured remote Shepherd hosts and their live connections.
    let remoteHosts: RemoteHostStore
    /// Where the open space-directory browser creates its space: this Mac
    /// or a host. Sheet in RootView; every "new space" entry point (⌘⇧N,
    /// ⌘K, sidebar +) routes here — the system open panel is gone.
    struct WorktreeImportTarget: Equatable {
        let id = UUID()
        let spaceID: SpaceID
        let startPath: String
    }

    enum SpacePickerTarget: Identifiable, Equatable {
        case local
        case importWorktree(WorktreeImportTarget)
        case host(UUID)
        var id: String {
            switch self {
            case .local: return "local"
            case .importWorktree(let target): return target.id.uuidString
            case .host(let id): return id.uuidString
            }
        }
    }

    var spacePickerTarget: SpacePickerTarget?
    /// Compatibility spelling used by remote call sites.
    var remoteSpacePickerHostID: UUID? {
        get {
            if case .host(let id) = spacePickerTarget { return id }
            return nil
        }
        set { spacePickerTarget = newValue.map { .host($0) } }
    }
    /// Pre-selection for the New Agent sheet (a remote space header's `+`);
    /// consumed by the sheet's onAppear.
    var newAgentPreselect: (hostID: UUID, spaceID: SpaceID)?
    /// Collapsed machine roots in the unified tree (hosts by id; local has
    /// its own flag). Persisted, like collapsedSpaces.
    var collapsedHosts: Set<UUID> = [] {
        didSet {
            sidebarDefaults.set(collapsedHosts.map(\.uuidString).sorted(), forKey: "shepherd.collapsedHosts")
        }
    }
    var localMachineCollapsed = false {
        didSet { sidebarDefaults.set(localMachineCollapsed, forKey: "shepherd.localMachineCollapsed") }
    }
    /// The sidebar footer's Automations list is open. Persisted.
    var automationsExpanded = false {
        didSet { sidebarDefaults.set(automationsExpanded, forKey: "shepherd.automationsExpanded") }
    }
    /// Remote space disclosure state, keyed by host + space so equal space IDs
    /// on different machines cannot collide. Persisted across relaunches.
    private(set) var collapsedRemoteSpaces: Set<String> = [] {
        didSet {
            sidebarDefaults.set(collapsedRemoteSpaces.sorted(), forKey: "shepherd.collapsedRemoteSpaces")
        }
    }
    /// Last agent selected on each host, so a machine jump returns to where
    /// you were, not the top. Ephemeral.
    var lastRemoteAgentByHost: [UUID: AgentID] = [:]
    /// Bumped by every selection that should scroll the sidebar to the
    /// selected row (`sidebarRevealTarget`). A counter, not the target value:
    /// re-selecting the same row (⌘3 twice after scrolling away) must scroll
    /// back, and a value-diff would see no change. Ephemeral.
    var sidebarRevealRequest = 0

    private func remoteSpaceCollapseKey(hostID: UUID, spaceID: SpaceID) -> String {
        "\(hostID.uuidString)/\(spaceID.rawValue)"
    }

    func isRemoteSpaceCollapsed(hostID: UUID, spaceID: SpaceID) -> Bool {
        collapsedRemoteSpaces.contains(remoteSpaceCollapseKey(hostID: hostID, spaceID: spaceID))
    }

    func toggleRemoteSpaceCollapsed(hostID: UUID, spaceID: SpaceID) {
        let key = remoteSpaceCollapseKey(hostID: hostID, spaceID: spaceID)
        if collapsedRemoteSpaces.contains(key) {
            collapsedRemoteSpaces.remove(key)
        } else {
            collapsedRemoteSpaces.insert(key)
        }
    }

    /// A remote space header's `+`: the New Agent sheet opens pointed at
    /// that host and space.
    func showNewAgentSheetForRemote(hostID: UUID, spaceID: SpaceID) {
        newAgentPreselect = (hostID, spaceID)
        showNewAgentSheet = true
    }
    /// Space pending removal confirmation (alert in RootView) — removal
    /// kills the space's agents, so it always confirms.
    var spaceDeleteTarget: SpaceID?
    /// Rename target for a space (alert in RootView). Display-only rename;
    /// the checkout path never changes.
    var spaceRenameTarget: SpaceID?
    /// Space whose New Worktree sheet is open (sheet in RootView).
    var worktreeSheetTarget: SpaceID?
    /// Worktree agent pending delete confirmation (alert in RootView) —
    /// deleting may also remove the checkout, so it always confirms.
    var worktreeDeleteTarget: AgentID?
    /// An agent's `agent_delete` awaiting the user (`PeerDeleteDialog`). Only the dialog's
    /// destructive button approves it; `respond` answers the requesting agent exactly once.
    struct PeerDeleteConfirmation: Identifiable {
        /// The server's token for the pending request.
        let requestID: String
        let agent: Agent
        let senderName: String
        let respond: (AgentPeerOutcome) -> Void
        var id: String { requestID }
    }
    var peerDeleteConfirmation: PeerDeleteConfirmation?
    /// A snapshot of the agent + space whose Finalize Worktree sheet is
    /// open. Copies, not IDs: the pipeline's last act retires the agent, and
    /// a live lookup would blank the sheet mid-success.
    struct FinalizeRequest: Identifiable {
        let id = UUID()
        let agent: Agent
        let space: Space
    }
    var finalizeRequest: FinalizeRequest?

    /// "Finalize Worktree…" on a worktree agent's context menu.
    func beginFinalizeWorktree(_ agentID: AgentID) {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              agent.worktreeBranch != nil,
              let space = state.spaces.first(where: { $0.id == agent.spaceID }) else { return }
        finalizeRequest = FinalizeRequest(agent: agent, space: space)
    }

    /// The setup wizard's gh-authentication step: a terminal pane beside the agent's thread
    /// running `gh auth login`, because the login flow is interactive by design.
    func openGhLogin(besideAgent agentID: AgentID) {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        selectAgent(agentID)
        openTerminalPane(besideAgent: agent, running: "gh auth login")
    }
    @ObservationIgnored private var childSweepTimer: Timer?
    /// Focus is recorded per layout on every change (clicks, ⌥⌘←/→, splits),
    /// so returning to an agent restores the pane you were last working in.
    var focusedPaneID: PaneID? {
        didSet {
            guard let paneID = focusedPaneID, paneID != oldValue else { return }
            // Attribute focus to the layout that actually owns the pane, not
            // the active one: selection and focus can move in either order.
            if let tab = state.tabs.first(where: { $0.layout.contains(paneID) }) {
                focusMemory.record(pane: paneID, inTab: tab.id)
            }
        }
    }
    var showNewAgentSheet = false
    /// Whether the in-window settings surface is visible.
    var showSettings = false
    /// Last Settings category visited. View-model state survives closing the
    /// overlay but naturally resets when Shepherd restarts.
    var settingsSection: SettingsSection = .appearance
    /// Debug builds: the component gallery over the workspace.
    var showComponentGallery = false
    /// ⌘K command palette visibility.
    var showCommandPalette = false
    var agentRenameTarget: AgentID?
    /// True while ⌘ has been held ~250ms — sidebar rows show their ⌘1–9 keycaps.
    var showAgentShortcutBadges = false

    let sessions: TerminalSessionStore
    /// Native thread state per local agent and per remote agent.
    let threadStores = NativeThreadStores<AgentID>()
    let remoteThreadStores = NativeThreadStores<RemoteAgentRef>()
    /// Keyboard commands for the thread on screen.
    let threadCommands = ThreadCommandCenter()
    /// The menu bar's narrow view of this model (`MenuStateSync` keeps it current).
    let menuState = MenuState()
    /// The sidebar's one drop target (`SidebarView`), kept here so no update allocates another.
    let sidebarDropZone = SidebarDropZone()
    /// Which native subagent an agent's workspace is inspecting (the side panel).
    let subagentInspector = RightPaneState()
    /// System notifications when an unwatched agent finishes or blocks.
    let notifications = AgentNotifications()
    let settings: AppSettings
    private let sidebarDefaults: UserDefaults
    let keybindings: KeybindingsStore
    let themeManager: ThemeManager
    let installPiTheme: (ShepherdTheme) throws -> Void
    @ObservationIgnored private var commandHoldTask: Task<Void, Never>?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?
    /// Last pane focused in each layout (see `PaneFocusMemory`).
    var focusMemory = PaneFocusMemory()
    /// Memoized sidebar projections (`SidebarDerivations`). `spaceForest`
    /// is quadratic in spaces, and the sidebar reads these on every render —
    /// including once per row for the ⌘1–9 badges — so uncached they
    /// dominate every click once the space count grows. @ObservationIgnored:
    /// the cache fills inside getters during view updates and must never
    /// invalidate the views reading it; the inputs (`state`,
    /// `collapsedSpaces`) are themselves observed.
    @ObservationIgnored var sidebarDerivations = SidebarDerivations()
    /// When each layout last stopped being the visible one; drives cold
    /// parking (see `WorkspaceSelection`). @ObservationIgnored: it only changes alongside
    /// the active tab.
    @ObservationIgnored var tabHiddenSince: [TabID: Date] = [:]
    /// Layouts currently unmounted by cold parking. Observed: parking and
    /// unparking must re-evaluate `mountedTabs`.
    var parkedTabIDs: Set<TabID> = []
    /// Layouts not mounted yet at launch (`WorkspaceSelection.pendingMountTabIDs`): the
    /// workspace's first frame builds the visible layout alone, then `drainPendingMounts`
    /// mounts the rest. Observed, like `parkedTabIDs`.
    var pendingMountTabIDs: Set<TabID> = []
    /// The first adopt with agents plans the launch's mounting, once.
    @ObservationIgnored var mountingPlanned = false
    @ObservationIgnored var parkSweepTimer: Timer?
    /// One-shot launch guard for autoStartAutomations.
    var didAutoStartAutomations = false
    /// The first adoption starts every restored agent's pi (`TerminalSessionStore.startRestoredAgents`).
    /// Off in harnesses that seed agents only to draw them: their pi then starts when a layout
    /// mounts or a test asks, as before.
    @ObservationIgnored let restoresAgentsAtLaunch: Bool
    /// One-shot launch guard for starting the restored agents' pi.
    @ObservationIgnored var didStartRestoredAgents = false
    /// Recently selected agents, most recent last, no duplicates. When the
    /// selected agent goes away (⌘⇧W, process exit) selection returns to the
    /// agent you were on before it — not the space's blank shell.
    var selectionHistory: [AgentID] = []
    /// Workspace mutations are optimistic so the UI stays responsive, but the
    /// server remains authoritative. This tail makes their persistence order
    /// explicit and gives failures one reconciliation path.
    @ObservationIgnored var persistenceTail: Task<Void, Never>?

    let server: SessionServer

    init(
        server: SessionServer = .shared,
        settings: AppSettings? = nil,
        keybindings: KeybindingsStore? = nil,
        themeManager: ThemeManager? = nil,
        remoteHosts: RemoteHostStore? = nil,
        sidebarDefaults: UserDefaults = .standard,
        themeInstaller: @escaping (ShepherdTheme) throws -> Void = { theme in
            _ = try ShepherdPiTheme.installedPath(for: theme)
        },
        restoresAgentsAtLaunch: Bool = true
    ) {
        self.state = ShepherdState()
        self.server = server
        self.restoresAgentsAtLaunch = restoresAgentsAtLaunch
        self.settings = settings ?? .shared
        self.sidebarDefaults = sidebarDefaults
        LegacyTerminalAgents.forgetPresentationPreferences(in: sidebarDefaults)
        self.keybindings = keybindings ?? .shared
        self.themeManager = themeManager ?? .shared
        self.remoteHosts = remoteHosts ?? RemoteHostStore()
        self.installPiTheme = themeInstaller
        self.sessions = TerminalSessionStore(server: server)
        self.selectedSpaceID = nil
        self.selectedAgentID = nil
        self.focusedPaneID = nil

        // Restore persisted sidebar collapse state. Stale IDs are pruned on
        // the first server snapshot (`adopt`).
        let defaults = sidebarDefaults
        if let raw = defaults.stringArray(forKey: "shepherd.collapsedSpaces") {
            collapsedSpaces = Set(raw.map(SpaceID.init(rawValue:)))
        }
        if let raw = defaults.stringArray(forKey: "shepherd.collapsedHosts") {
            collapsedHosts = Set(raw.compactMap(UUID.init(uuidString:)))
        }
        localMachineCollapsed = defaults.bool(forKey: "shepherd.localMachineCollapsed")
        automationsExpanded = defaults.bool(forKey: "shepherd.automationsExpanded")
        sidebarHidden = defaults.bool(forKey: "shepherd.sidebarHidden")
        collapsedRemoteSpaces = Set(defaults.stringArray(forKey: "shepherd.collapsedRemoteSpaces") ?? [])

        sessions.onStateChanged = { [weak self] serverState in
            self?.adopt(serverState)
        }
        sessions.onTabLayoutChanged = { [weak self] tabID, layout in
            guard let self, let index = self.state.tabs.firstIndex(where: { $0.id == tabID }),
                  self.state.tabs[index].layout != layout else { return }
            self.state.tabs[index].layout = layout
        }
        sessions.onAgentStatus = { [weak self] agentID, status in
            self?.applyAgentStatus(agentID, status)
        }
        // A thread on screen shows pi's history the moment pi serves it, not at its next poll.
        sessions.onThreadServable = { [weak self] agentID in
            self?.threadStores.existing(for: agentID)?.revisionAvailable()
        }
        notifications.onSelectAgent = { [weak self] agentID in
            guard let self, self.state.agents.contains(where: { $0.id == agentID }) else { return }
            self.selectAgent(agentID)
        }
        // Banners from a previous app run point at dead sessions; drop them.
        notifications.removeAll()
        sessions.reserveCheckoutForLaunch = { [weak self] cwd in
            guard let self else { throw AgentStartFailure(message: "Workspace closed") }
            try self.verifyCheckoutAvailable(cwd)
            let id = UUID()
            self.startingCheckoutUsers[id] = cwd
            return { [weak self] in self?.startingCheckoutUsers.removeValue(forKey: id) }
        }
        self.remoteHosts.onDropError = { [weak self] in self?.remoteActionError = $0 }
        self.remoteHosts.onProjectionChanged = { [weak self] in
            guard let self else { return }
            self.remoteThreadStores.prune(live: Set(self.remoteHosts.connections.flatMap { connection in
                connection.state.agents.map { RemoteAgentRef(hostID: connection.id, agentID: $0.id) }
            }))
            for (target, review) in self.remoteReviews where review.hostReviewPane {
                guard let connection = self.remoteHosts.connections.first(where: { $0.id == target.hostID }),
                      connection.phase == .connected,
                      !connection.state.tabs.contains(where: { $0.layout.contains(review.paneID) }) else { continue }
                let oldPaneID = review.paneID
                review.paneID = PaneID()
                review.hostReviewPane = false
                review.loadRequestID = UUID()
                review.isLoading = false
                review.loadError = nil
                if self.remoteFocusedPaneID == oldPaneID { self.remoteFocusedPaneID = review.paneID }
            }
        }
        sessions.onAgentChildren = { [weak self] agentID, children in
            self?.applyAgentChildren(agentID, children)
        }
        sessions.onPaneSessionExited = { [weak self] paneID in
            self?.handleSessionExited(paneID: paneID)
        }
        sessions.onNotify = { [weak self] agentID, title, body in
            guard let self, let agent = self.state.agents.first(where: { $0.id == agentID }) else { return }
            self.notifications.agentNotify(agent, title: title, body: body)
        }
        // Agents drive their own panes through the server's extension socket.
        installPaneControl()
        installReviewHandler()
        // Any pi session can create automations through the same socket.
        installAutomationControl()
        // Agents can see, message, and spawn peer threads.
        installAgentPeerControl()
        // Host role: bind the remote listener at VM creation, not from a
        // window's .task — a restored-minimized or slow-to-render window
        // must not leave a host Mac unreachable. The TCP listener is
        // independent of server.start()'s Unix socket, so ordering is safe;
        // the .task call remains as a no-op-if-bound backstop.
        applyRemoteListenerSetting()
        installRemoteInspection()
        server.onRemoteAgentAction = { [weak self] agentID, action, completion in
            Task { @MainActor in
                guard let self else {
                    completion(.failure(RemoteCreateAgentError("Host is shutting down")))
                    return
                }
                do {
                    switch action {
                    case .rename(let name): try await self.server.renameAgent(agentID, to: name)
                    case .reorder(let target): try await self.server.reorderAgent(agentID, onto: target)
                    case .deleteKeepingWorktree: try await self.deleteAgentPersisted(agentID)
                    }
                    completion(.success(()))
                } catch {
                    completion(.failure(RemoteCreateAgentError(String(describing: error))))
                }
            }
        }
        server.onRemoteCreationOptions = { [weak self] spaceID, cwd, fetchFirst, completion in
            Task { @MainActor in
                guard let self, let space = self.server.state.spaces.first(where: { $0.id == spaceID }) else {
                    completion(.failure(RemoteCreateAgentError("Space no longer exists"))); return
                }
                let repo = cwd ?? space.path
                let mode = self.settings.worktreeBaseMode
                let fetch = fetchFirst ?? self.settings.worktreeFetchBeforeCreate
                let resolution = await Task.detached {
                    cwd == nil ? GitWorktree.BaseResolution(startPoint: nil, display: "", note: "")
                        : GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetch)
                }.value
                completion(.success(.init(base: resolution.display, note: resolution.note, fetchFirst: fetch,
                                          model: self.settings.agentDefaults.model ?? PiConfig.defaultModel(), thinking: self.settings.defaultThinking)))
            }
        }
        // Remote clients create agents through this host's normal spawn flow.
        server.onRemoteCreateAgent = { [weak self] request, completion in
            guard let self else {
                completion(.failure(RemoteCreateAgentError("host is shutting down")))
                return
            }
            let space = self.state.spaces.first { $0.id == request.spaceID }
            var config = NewAgentConfig(
                spaceID: request.spaceID,
                workingDirectory: request.cwd ?? space?.path ?? "~",
                model: request.model ?? self.settings.agentDefaults.model,
                thinking: request.thinking ?? self.settings.defaultThinking,
                initialPrompt: request.initialPrompt
            )
            Task { @MainActor in
                do {
                    if let branch = request.worktreeBranch {
                        let repo = config.workingDirectory
                        let mode = self.settings.worktreeBaseMode
                        let fetchFirst = request.worktreeFetchFirst ?? self.settings.worktreeFetchBeforeCreate
                        guard let space else { throw RemoteCreateAgentError("Space no longer exists") }
                        let (path, base) = try await Task.detached {
                            guard try GitWorktree.primaryCheckout(at: repo) == GitWorktree.primaryCheckout(at: space.path) else {
                                throw RemoteCreateAgentError("Choose a directory in the selected space's repository")
                            }
                            let resolution = GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetchFirst)
                            let base = request.worktreeBase?.trimmingCharacters(in: .whitespacesAndNewlines)
                            return (try GitWorktree.add(repo: repo, branch: branch, from: base?.isEmpty == false ? base : resolution.startPoint), base?.isEmpty == false ? base! : resolution.display)
                        }.value
                        config.workingDirectory = path
                        config.worktreeBranch = branch
                        config.worktreeBase = base
                        config.worktreePath = path
                    }
                    let agentID = try await self.startAgent(config, selectAfter: false)
                    completion(.success(agentID))
                } catch {
                    completion(.failure(RemoteCreateAgentError(String(describing: error))))
                }
            }
        }
        // Adopt the persisted workspace without waiting for a pane to render
        // (an empty sidebar can never render one).
        sessions.warmUp()

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.modifierFlagsChanged(event.modifierFlags)
            }
            return event
        }
        // Agent navigation chords bypass the menu bar: dispatching a SwiftUI
        // CommandMenu key equivalent revalidates the whole main menu
        // (including the dynamic agent list) and showed up as 200–500ms of
        // keypress→switch latency. The menu items stay for discoverability;
        // this monitor consumes the event first so they never double-fire.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleNavigationKeyDown(event) ?? false
            }
            return handled ? nil : event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.modifierFlagsChanged([]) }
        }
    }

    deinit {
        commandHoldTask?.cancel()
        persistenceTail?.cancel()
        childSweepTimer?.invalidate()
        parkSweepTimer?.invalidate()
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    /// Chord→intent classification for the navigation fast path. Pure and
    /// separated from NSEvent so the matching — the part that could swallow
    /// a keystroke it shouldn't — is directly testable.
    enum NavigationKeyAction: Equatable {
        case agentDigit(Int)
        case machineJump(Int)
        case adjacentAgent(Int)
    }

    /// `modifiers` must be pre-masked to the four app modifiers. Digit
    /// families match by exact modifier set; validation already guarantees
    /// the three sets are mutually exclusive.
    static func navigationKeyAction(
        digit: Int?,
        chord: KeyChord?,
        modifiers: NSEvent.ModifierFlags,
        next: KeyChord,
        previous: KeyChord
    ) -> NavigationKeyAction? {
        if let digit {
            if modifiers == .command { return .agentDigit(digit) }
            if modifiers == [.control, .shift] { return .machineJump(digit) }
        }
        guard let chord else { return nil }
        if chord == next { return .adjacentAgent(1) }
        if chord == previous { return .adjacentAgent(-1) }
        return nil
    }

    /// Fast path for the navigation chords (⌘↑/↓, ⌘1–9, ⌃⇧1–9 machine jumps): act directly instead of letting the event
    /// reach the main menu. Consumes an event only when the menu's
    /// equivalent item would be live, so a dead chord falls through
    /// unchanged. Stands down while the Settings shortcut recorder is
    /// capturing so rebinding these chords still works.
    private func handleNavigationKeyDown(_ event: NSEvent) -> Bool {
        guard !keybindings.isRecording else { return false }
        let action = Self.navigationKeyAction(
            digit: KeyChord.digit(keyCode: event.keyCode),
            chord: KeyChord(event: event),
            modifiers: event.modifierFlags.intersection([.command, .shift, .option, .control]),
            next: keybindings.chord(for: .nextAgent),
            previous: keybindings.chord(for: .previousAgent)
        )
        switch action {
        case .agentDigit(let digit):
            // Mirrors the Agent menu's digit rows: live only for an existing sidebar index.
            guard activeMachineAgents.count >= digit else { return false }
            showCommandPalette = false
            selectAgentDigit(digit)
            return true
        case .machineJump(let digit):
            // ⌃⇧1 (local) is always live; host rows only while connected,
            // matching the Machines menu's disabled states.
            if digit > 1 {
                guard remoteHosts.connections.indices.contains(digit - 2),
                      remoteHosts.connections[digit - 2].phase == .connected else { return false }
            }
            jumpToMachine(digit)
            return true
        case .adjacentAgent(let delta):
            selectAdjacentAgent(delta)
            return true
        case nil:
            return false
        }
    }

    /// Delayed reveal so ordinary chords don't flash the badges: agent rows show their ⌘1–9
    /// keycaps once plain ⌘ has been held for a moment.
    private func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        commandHoldTask?.cancel()
        commandHoldTask = nil
        // No digit badges over the ⌘K palette.
        let wantAgents = !showCommandPalette && flags.intersection([.command, .shift, .option, .control]) == [.command]
        if !wantAgents { showAgentShortcutBadges = false }
        guard wantAgents, !showAgentShortcutBadges else { return }
        commandHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.showAgentShortcutBadges = true
        }
    }

    /// Adopt a server snapshot wholesale, keeping selection when IDs persist.
    func adopt(_ serverState: ShepherdState) {
        state = serverState
        threadStores.prune(live: Set(state.agents.map(\.id)))
        pruneReviewSessions()
        // First adoption of the restored workspace: stand the enabled
        // automation watches back up (their agents died with the last run).
        if !didAutoStartAutomations {
            didAutoStartAutomations = true
            autoStartAutomations()
        }
        // Drop collapse entries for spaces that no longer exist so the
        // persisted set cannot grow without bound.
        let liveSpaces = Set(state.spaces.map(\.id))
        if !collapsedSpaces.isSubset(of: liveSpaces) {
            collapsedSpaces.formIntersection(liveSpaces)
        }
        if let selected = selectedSpaceID, !state.spaces.contains(where: { $0.id == selected }) {
            selectedSpaceID = nil
        }
        if selectedSpaceID == nil {
            // Never default into the hidden automations space.
            selectedSpaceID = visibleSpaces.first?.id
        }
        if selectedAgent == nil {
            selectedAgentID = state.agents.first { $0.spaceID == selectedSpaceID }?.id
        }
        // First adoption of the restored workspace: every agent's pi starts now, not when its
        // layout mounts, the one on screen first and the rest a few at a time.
        if restoresAgentsAtLaunch, !didStartRestoredAgents {
            didStartRestoredAgents = true
            sessions.startRestoredAgents(orderedAgents.map(\.id) + state.agents.map(\.id),
                                         first: selectedAgentID.map { [$0] } ?? [], in: state)
        }
        focusMemory.prune(liveTabs: Set(state.tabs.map(\.id)))

        if let focused = focusedPaneID, activeTab?.layout.contains(focused) == true {
            // Focused pane survived the new snapshot; keep it.
        } else {
            syncFocus()
        }
        planMounting()
    }

    private func applyAgentStatus(_ id: AgentID, _ status: AgentStatus) {
        if let index = state.agents.firstIndex(where: { $0.id == id }) {
            let old = state.agents[index].status
            // A repeated report must not invalidate every view that reads the workspace.
            if old != status { state.agents[index].status = status }
            if old != status || statusSince[id] == nil { statusSince[id] = Date() }
            // Visible means the workspace is actually showing this agent's
            // layout — not a remote agent.
            let visible = selectedAgentID == id && selectedRemoteAgent == nil
            notifications.agentStatusChanged(state.agents[index], from: old, isAgentVisible: visible)
        }
    }

    /// Runs the ChildRuns TTL/staleness sweep only while rows exist; the
    /// timer dies with the last row, so an idle fleet costs nothing.
    private func syncChildSweepTimer() {
        if childRuns.rows.isEmpty {
            childSweepTimer?.invalidate()
            childSweepTimer = nil
            return
        }
        guard childSweepTimer == nil else { return }
        childSweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Copy-out so an idle sweep doesn't publish a no-op change; its bookkeeping
                // still lands (unobserved) so a stale publisher is not re-swept forever.
                var swept = self.childRuns
                if swept.sweep() { self.childRuns = swept } else { self._childRuns = swept }
                self.syncChildSweepTimer()
            }
        }
    }

    func applyAgentChildren(_ agentID: AgentID, _ children: [ChildRun]) {
        var updated = childRuns
        updated.apply(agentID: agentID, children: children)
        // The extension republishes every 45s: an identical publish only refreshes the
        // publisher's timestamp, which no view reads, so it goes to the unobserved storage.
        if updated.rows == childRuns.rows { _childRuns = updated } else { childRuns = updated }
        syncChildSweepTimer()
    }

    /// One agent's published child runs: its sidebar row asks while one waits on you, and a
    /// host answers a remote client's children query with them.
    func children(of agentID: AgentID) -> [ChildRun] {
        childRuns.children(of: agentID)
    }

    // MARK: Remote listener (host role)

    /// The bound port while serving, nil otherwise. Distinct from the
    /// setting: binding can fail (port in use), and the UI must say so.
    private(set) var remoteListenerBoundPort: UInt16?
    private(set) var remoteListenerError: String?

    var remoteListenerEnabled: Bool { settings.remoteListenerEnabled }

    var remoteListenerStatus: String {
        if let port = remoteListenerBoundPort {
            return "Serving on port \(port). Other Macs with your token connect to agents here."
        }
        return "Let other Macs with your token connect to agents here."
    }

    /// The bind failure, shown inline under the listener row.
    var remoteListenerProblem: String? { remoteListenerError.map { "Couldn't start: \($0)" } }

    /// Applied at startup (ShepherdApp calls this after server.start()) and
    /// from the Settings toggle.
    func applyRemoteListenerSetting() {
        setRemoteListenerEnabled(settings.remoteListenerEnabled, persist: false)
    }

    func setRemoteListenerEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist { settings.remoteListenerEnabled = enabled }
        remoteListenerError = nil
        if enabled {
            guard remoteListenerBoundPort == nil else { return }
            do {
                remoteListenerBoundPort = try server.startRemoteListener(
                    port: UInt16(clamping: settings.remoteListenerPort),
                    tokenURL: ShepherdPaths.remoteTokenURL()
                )
            } catch {
                // Surfaced in Settings AND logged — on a headless host nobody
                // is looking at Settings.
                remoteListenerError = String(describing: error)
                NSLog("Shepherd: remote listener failed to start: \(error)")
            }
        } else if remoteListenerBoundPort != nil {
            server.stopRemoteListener()
            remoteListenerBoundPort = nil
        }
    }

}
