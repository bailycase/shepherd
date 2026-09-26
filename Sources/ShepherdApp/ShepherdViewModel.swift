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
    /// Go to pi with the opening prompt (the New thread page's attachments).
    var initialImages: [NativeImage] = []
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
    /// The design this agent draws: it launches with the design tools, keeps its name (the
    /// design's), and has no row of its own in Recents.
    var designID: DesignID?
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
    /// The page the main column shows in place of a thread (New thread, Automations, Hosts);
    /// nil while a thread shows. Picking a row clears it. Ephemeral, like all selection state.
    var destination: MainDestination?
    /// The sidebar's More is open, showing Hosts and Extensions. Ephemeral.
    var moreOpen = false
    /// Needs you and Recents, derived once per change of what they read (`SidebarSource`).
    @ObservationIgnored var sidebarListsCache: (source: SidebarSource, lists: SidebarLists)?
    /// Who the sidebar's footer names: the Mac's user and computer, read once. Previews pass their
    /// own, so a render never shows the machine it ran on.
    @ObservationIgnored var sidebarFooterIdentity: (name: String, detail: String)?
    /// The Automations and Hosts pages, derived again only when what they read changed.
    @ObservationIgnored var automationsPageCache: (inputs: AutomationsPageInputs, model: AutomationsPageModel)?
    @ObservationIgnored var hostsPageCache: (inputs: HostsPageInputs, model: HostsPageModel)?
    /// The New thread page's draft: what to do, where, and how. Kept while the page is away.
    let newThread = NewThreadState()
    /// The New design page's brief, images and project. Kept while the page is away.
    let newDesign = NewDesignState()
    /// The Export sheet over a design (DZExport), while it is up.
    var designExport: DesignExportModel?
    /// Where boards attached to a thread are written: the drop folder (tests use their own).
    @ObservationIgnored var designAttachDirectory: URL = AppImageDrop.directory
    /// The Designs page's filter and selected card. Ephemeral.
    var designsPageFilter = ""
    var designsPageSelection: DesignID?
    @ObservationIgnored var designsPageCache: (inputs: DesignsPageInputs, model: DesignsPageModel)?
    /// Each design's canvas, kept for the app's run so returning to one finds it as it was.
    @ObservationIgnored var designScreens: [DesignID: DesignScreenModel] = [:]
    /// Designs on screen: only their revisions are pushed (`SessionServer.onDesignRevision`).
    @ObservationIgnored var visibleDesigns: Set<DesignID> = []
    /// Designs whose agent is being started, so a second open waits for it.
    @ObservationIgnored var startingDesignAgents: Set<DesignID> = []
    /// This Mac's design systems as last read (DZSystem, the Designs page's systems).
    let designSystems = DesignSystemCatalog()
    /// The system the Design systems page shows (a system without an agent of its own; a
    /// build's page is its agent's layout).
    var shownDesignSystem: String?
    /// The system page last opened: More ▸ Design systems goes back to it.
    @ObservationIgnored var lastDesignSystem: DesignSystemTarget?
    @ObservationIgnored var designSystemPageCache: [DesignSystemTarget: (inputs: DesignSystemPageInputs, model: DesignSystemPageModel)] = [:]
    /// Projects whose system build is being started, so a second click waits for it.
    @ObservationIgnored var startingSystemBuilds: Set<SpaceID> = []
    /// Draws every design's boards (`DesignHost.swift`), once a design or the Designs page is
    /// first shown.
    var designRendering: DesignRendering {
        if let made = madeDesignRendering { return made }
        let made = DesignRendering(folder: { [server] in server.designs.folder(for: $0) }, network: designNetwork, liveCap: designLiveCap)
        madeDesignRendering = made
        return made
    }
    @ObservationIgnored private(set) var madeDesignRendering: DesignRendering?
    /// Tests turn Google Fonts off so boards never reach the network, and previews take no live
    /// views; both are set before the first design draws.
    @ObservationIgnored var designNetwork: DesignRenderingNetwork = .googleFonts
    @ObservationIgnored var designLiveCap = DesignLivePlan.liveCap
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
    /// Agents whose last turn ended in an error: done, but their sidebar row reads failed.
    /// Ephemeral, like the status it qualifies.
    var failedTurns: Set<AgentID> = []
    /// Each automation's run whose agent still exists, as the server's run log keeps it: an
    /// idle run agent is starting until its run has settled (`AutomationRun.isLive`). Read with
    /// every adopted state.
    var openAutomationRuns: [AutomationID: AutomationRun] = [:]
    /// Automations whose next run is being started: a second start refuses rather than racing it.
    @ObservationIgnored var startingAutomations: Set<AutomationID> = []
    /// ⌘⇧S hides the sidebar. Persisted, like the other sidebar disclosure choices.
    var sidebarHidden = false {
        didSet { sidebarDefaults.set(sidebarHidden, forKey: "shepherd.sidebarHidden") }
    }
    /// The window is too narrow to dock the sidebar (`ShellLayout.sidebar`), so ⇧⌘S overlays
    /// it instead. Written by the window as it resizes; ephemeral.
    var sidebarAutoHidden = false
    /// The overlaid sidebar is showing (narrow window only). Ephemeral.
    var sidebarOverlayShown = false
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
    /// A review pane's Commit… sheet by review session, kept while its commit runs.
    @ObservationIgnored var reviewCommitStores: [UUID: ReviewCommitStore] = [:]
    /// Runs commit from review's git and gh (tests stub gh here); reads time out, mutations don't.
    @ObservationIgnored var reviewCommitRunner: ReviewCommitGit.Runner = { await LoginShell.run($0, cwd: $1) }
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
    /// Where a local review reads its changes from; tests put a fixed engine here. Nil: this Mac's
    /// `server.changes`.
    @ObservationIgnored var changesEngineOverride: ((AgentID, String) -> ChangesEngine)?
    /// When each thread's review was last sent (ms): a review opened after the agent replied
    /// opens on Last turn.
    @ObservationIgnored var reviewSentAt: [SidePaneOwner: Double] = [:]
    /// Host-side utility terminals (a remote `gh auth login`) opened for a remote agent,
    /// shown in place of the agent's own layout while `remoteInspectingAgent` is set.
    var hostRemoteInspectors: [String: TabID] = [:]
    var remoteInspectorTabs: [RemoteAgentRef: TabID] = [:]
    var remoteInspectingAgent: RemoteAgentRef?
    var remoteInspectionRequest = UUID()
    var remoteRenameTarget: RemoteAgentRef?
    /// A terminal tab being renamed (the panel's Rename tab).
    var terminalRenameTarget: TerminalRenameTarget?
    var remoteActionError: String?

    /// Configured remote Shepherd hosts and their live connections.
    let remoteHosts: RemoteHostStore
    /// Settings ▸ Instructions: pi's root instructions here and on every host, and their sync.
    let instructions: InstructionsModel
    /// Settings ▸ Experiments ▸ Suggested instructions: what this Mac's agents suggested.
    let suggestions: SuggestionsModel
    /// Settings ▸ MCP servers: what this Mac's agents report about each server.
    let mcpReports = MCPAgentReports()
    /// Answers an agent's MCP credentials request (the Keychain and OAuth). Nil until Settings ▸
    /// MCP servers' store is installed; requests then fail with `mcp_unavailable`.
    @ObservationIgnored var mcpCredentialSource: (@MainActor (MCPRequest) async -> MCPOutcome)?
    /// Settings ▸ Skills: every host's agent skills, This Mac's through `localSkills`.
    let skills: ClientSkills
    @ObservationIgnored let localSkills: LocalSkillsClient
    /// This Mac's daily look for newer skills (`startSkillChecks`).
    @ObservationIgnored var skillChecks: Task<Void, Never>?
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
    /// Each remote automation's runs as its host last sent them, oldest first (read for the sheet).
    var remoteAutomationRuns: [AutomationKey: [AutomationRun]] = [:]
    /// Remote automation changes on their way, so their controls wait.
    var remoteAutomationsPending: Set<AutomationKey> = []
    /// This Mac's automations' runs as the run log kept them, oldest first (read for the
    /// Automations page).
    var localAutomationRuns: [AutomationID: [AutomationRun]] = [:]
    /// The Automations page's selected row and its filter. Ephemeral.
    var automationsPageSelection: AutomationKey?
    var automationsPageFilter = ""
    /// Bumped by every selection that should scroll the sidebar to the
    /// selected row. A counter, not the target value: re-selecting the same
    /// row (⌘3 twice after scrolling away) must scroll back, and a value-diff
    /// would see no change. Ephemeral.
    var sidebarRevealRequest = 0

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
    /// The workspace column's size and window, kept current without redrawing anything.
    @ObservationIgnored let workspaceColumn = LiveResizeColumn()
    /// The column's size when the side pane last covered the window: hidden layouts keep it
    /// while it does (`isSidePaneWide`).
    @ObservationIgnored var wideFrozenSize: CGSize?
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
    /// Which native subagent an agent's workspace is inspecting (the side panel).
    let subagentInspector = RightPaneState()
    /// Each layout's terminal panel under its thread (`TerminalPanels`).
    let terminalPanels = TerminalPanels()
    /// System notifications when an unwatched agent finishes, fails, or asks, or a subagent asks.
    let notifications = AgentNotifications()
    let settings: AppSettings
    private let sidebarDefaults: UserDefaults
    let keybindings: KeybindingsStore
    let themeManager: ThemeManager
    let installThemeMarker: (ShepherdTheme) throws -> Void
    @ObservationIgnored private var commandHoldTask: Task<Void, Never>?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var resignActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var becomeActiveObserver: NSObjectProtocol?
    /// Reads each local agent's branch and changed files for the header (`CheckoutMonitor`);
    /// nil when the harness turned it off.
    @ObservationIgnored private(set) var checkouts: CheckoutMonitor?
    /// Last pane focused in each layout (see `PaneFocusMemory`).
    var focusMemory = PaneFocusMemory()
    /// Whether each space's folder is a git checkout (the New thread page offers a worktree
    /// there), probed once per change of the space list, never per render.
    @ObservationIgnored var repoBySpace: (spaces: [Space], repos: [SpaceID: Bool])?
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
            try ShepherdThemeMarker.install(for: theme)
        },
        restoresAgentsAtLaunch: Bool = true,
        checkoutReader: CheckoutMonitor.Reader? = CheckoutMonitor.git
    ) {
        self.state = ShepherdState()
        self.server = server
        self.restoresAgentsAtLaunch = restoresAgentsAtLaunch
        self.settings = settings ?? .shared
        self.sidebarDefaults = sidebarDefaults
        LegacyTerminalAgents.forgetPresentationPreferences(in: sidebarDefaults)
        self.keybindings = keybindings ?? .shared
        self.themeManager = themeManager ?? .shared
        let hosts = remoteHosts ?? RemoteHostStore()
        self.remoteHosts = hosts
        threadStores.hostName = { _ in localHostName }
        remoteThreadStores.hostName = { [weak hosts] ref in hosts?.connections.first { $0.id == ref.hostID }?.config.name }
        let instructions = InstructionsModel(store: server.instructions, remoteHosts: hosts, defaults: sidebarDefaults)
        self.instructions = instructions
        self.suggestions = SuggestionsModel(store: server.suggestions, instructionsStore: server.instructions, instructions: instructions)
        self.skills = ClientSkills(defaults: sidebarDefaults)
        self.localSkills = LocalSkillsClient(store: server.skills)
        self.installThemeMarker = themeInstaller
        self.sessions = TerminalSessionStore(server: server)
        self.selectedSpaceID = nil
        self.selectedAgentID = nil
        self.focusedPaneID = nil

        // The tree's disclosure keys (collapsed spaces, hosts, This Mac, the Automations
        // footer) stay in older preferences and are no longer read.
        sidebarHidden = sidebarDefaults.bool(forKey: "shepherd.sidebarHidden")

        sessions.onStateChanged = { [weak self] serverState in
            self?.adopt(serverState)
        }
        // Settings ▸ Instructions follows a remote client's save here, and sends a host that
        // comes back what it is owed.
        server.onInstructionsChanged = { [weak instructions = self.instructions] snapshot in
            MainActor.assumeIsolated { instructions?.localChanged(snapshot) }
        }
        hosts.onHostConnected = { [weak self, weak instructions = self.instructions] hostID in
            instructions?.hostConnected(hostID)
            self?.skillsHostConnected(hostID)
        }
        // Settings ▸ Skills follows a remote client's change to This Mac's skills.
        server.onSkillsChanged = { [weak skills = self.skills] snapshot in
            MainActor.assumeIsolated { skills?.hostChanged(ShepherdViewModel.thisMacSkills, snapshot) }
        }
        server.onSuggestionsChanged = { [weak suggestions = self.suggestions] snapshot in
            MainActor.assumeIsolated { suggestions?.serverChanged(snapshot) }
        }
        sessions.onTabLayoutChanged = { [weak self] tabID, layout in
            guard let self, let index = self.state.tabs.firstIndex(where: { $0.id == tabID }),
                  self.state.tabs[index].layout != layout else { return }
            self.state.tabs[index].layout = layout
        }
        sessions.onAgentStatus = { [weak self] agentID, status, failure in
            self?.applyAgentStatus(agentID, status, failure: failure)
        }
        // A thread on screen shows pi's history the moment pi serves it, not at its next poll.
        sessions.onThreadServable = { [weak self] agentID in
            self?.threadStores.existing(for: agentID)?.revisionAvailable()
        }
        // And each revision pi reaches after, within a frame: the server pushes the threads on
        // screen (those whose poll loop runs), and the store pulls at most every
        // `NativeThreadStore.pushedPullSpacing`. The polls stay as the fallback.
        threadStores.onLiveChange = { [weak self] live in
            self?.sessions.watchThreadRevisions(of: live)
        }
        sessions.onThreadRevision = { [weak self] agentID in
            self?.threadStores.existing(for: agentID)?.revisionAvailable()
        }
        // A design on screen pulls what changed as the agent draws.
        server.onDesignRevision = { [weak self] designID in
            MainActor.assumeIsolated { self?.designRevised(designID) }
        }
        // A system an agent wrote, or a re-sync, reaches its page and cards.
        server.onDesignSystemsChanged = { [weak self] in
            MainActor.assumeIsolated { self?.designSystemsChanged() }
        }
        notifications.onResponse = { [weak self] response in
            self?.respond(to: response)
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
            self.notifyRemote()
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
        if let checkoutReader {
            let monitor = CheckoutMonitor(read: checkoutReader) { [server] id, checkout in await server.setAgentCheckout(id, checkout) }
            monitor.directory = { [weak self] id in self?.checkoutDirectory(of: id) }
            checkouts = monitor
            server.onAgentToolFinished = { [weak monitor] agentID, tool in
                guard CheckoutMonitor.touchesFiles(tool: tool) else { return }
                monitor?.refresh(agentID, after: .seconds(1))
            }
        }
        // Agents drive their own panes through the server's extension socket.
        installPaneControl()
        installReviewHandler()
        // Agents' MCP extensions report servers and ask for their credentials.
        installMCPHandlers()
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
        // Queues go the way Settings ▸ Agents says, unless an agent's own ••• menu chose.
        server.setDefaultQueueMode(self.settings.queueDelivery)
        self.settings.onQueueDeliveryChange = { [weak server] mode in server?.setDefaultQueueMode(mode) }
        installRemoteInspection()
        installHostSettings()
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
                    case .renameTerminal(let paneID, let title): try self.renameTerminalPane(paneID, of: agentID, to: title)
                    case .killTerminalProcess(let paneID): try await self.killTerminalProcess(paneID, of: agentID)
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
            config.initialImages = request.initialImages
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
        // Back from another app (a commit in a terminal, an editor's save): read the checkout on
        // screen again.
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.selectedRemoteAgent == nil, let id = self.selectedAgentID else { return }
                self.checkouts?.refresh(id)
            }
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
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    /// Chord→intent classification for the navigation fast path. Pure and
    /// separated from NSEvent so the matching — the part that could swallow
    /// a keystroke it shouldn't — is directly testable.
    enum NavigationKeyAction: Equatable {
        case agentDigit(Int)
        case adjacentAgent(Int)
    }

    /// `modifiers` must be pre-masked to the four app modifiers. ⌘digits match by the exact
    /// modifier set, so ⌃⇧digits (the retired machine jumps) fall through to the focused view.
    static func navigationKeyAction(
        digit: Int?,
        chord: KeyChord?,
        modifiers: NSEvent.ModifierFlags,
        next: KeyChord,
        previous: KeyChord
    ) -> NavigationKeyAction? {
        if let digit, modifiers == .command { return .agentDigit(digit) }
        guard let chord else { return nil }
        if chord == next { return .adjacentAgent(1) }
        if chord == previous { return .adjacentAgent(-1) }
        return nil
    }

    /// Fast path for the navigation chords (⌘↑/↓, ⌘1–9): act directly instead of letting the event
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
            // Mirrors the Agent menu's digit rows: live only for an existing Recents row.
            guard sidebarLists.shortcutRows.count >= digit else { return false }
            showCommandPalette = false
            selectAgentDigit(digit)
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
        let runs = server.openAutomationRuns
        if runs != openAutomationRuns { openAutomationRuns = runs }
        threadStores.prune(live: Set(state.agents.map(\.id)))
        notifyLocalQuestions()
        checkouts?.sync(agents: state.agents.map(\.id))
        pruneReviewSessions()
        pruneDesigns()
        mcpReports.retain(agents: Set(state.agents.map(\.id)))
        // First adoption of the restored workspace: stand the enabled
        // automation watches back up (their agents died with the last run).
        if !didAutoStartAutomations {
            didAutoStartAutomations = true
            autoStartAutomations()
        }
        let standing = WorkspaceSelection.standingSpace(selectedSpaceID, agentSelected: selectedAgent != nil, in: state)
        if standing != selectedSpaceID { selectedSpaceID = standing }
        // With nothing on screen (the shown agent went away, or the app just launched), the
        // agent shown before it comes back, else the most recently active on this Mac; with no
        // agents at all, the New thread page shows. A page the user opened stays.
        if selectedAgent == nil, destination == nil, selectedRemoteAgent == nil {
            let live = Set(state.agents.map(\.id))
            if let next = selectionHistory.last(where: live.contains) ?? localRecentsOrder.first,
               let agent = state.agents.first(where: { $0.id == next }) {
                selectedAgentID = agent.id
                selectedSpaceID = agent.spaceID
            }
        }
        // First adoption of the restored workspace: every agent's pi starts now, not when its
        // layout mounts, the one on screen first and the rest a few at a time, in Recents order.
        if restoresAgentsAtLaunch, !didStartRestoredAgents {
            didStartRestoredAgents = true
            sessions.startRestoredAgents(localRecentsOrder + state.agents.map(\.id),
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

    private func applyAgentStatus(_ id: AgentID, _ status: AgentStatus, failure: TurnFailure?) {
        if let index = state.agents.firstIndex(where: { $0.id == id }) {
            let old = state.agents[index].status
            // A repeated report must not invalidate every view that reads the workspace.
            if old != status { state.agents[index].status = status }
            if old != status || statusSince[id] == nil { statusSince[id] = Date() }
            // A turn starting or ending may have changed files.
            if old != status { checkouts?.refresh(id, after: .milliseconds(300)) }
            let failed = status == .done && failure != nil
            if failed != failedTurns.contains(id) {
                if failed { failedTurns.insert(id) } else { failedTurns.remove(id) }
            }
            notifyStatus(state.agents[index], from: old, failure: failure)
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
        if let agent = state.agents.first(where: { $0.id == agentID }) {
            notifySubagents(agent, children: children)
        }
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
    private(set) var remoteListenerFailure: RemoteListenerFailure?

    var remoteListenerEnabled: Bool { settings.remoteListenerEnabled }

    var remoteListenerStatus: String {
        if let port = remoteListenerBoundPort {
            return "Serving on port \(port). Other Macs with your token connect to agents here."
        }
        return "Let other Macs with your token connect to agents here."
    }

    /// Why the listener couldn't start, in words, shown inline under the listener row.
    var remoteListenerProblem: String? { remoteListenerFailure?.sentence }
    /// The technical reason: that line's tooltip.
    var remoteListenerProblemDetail: String? { remoteListenerFailure?.detail }

    /// Applied at startup (ShepherdApp calls this after server.start()) and
    /// from the Settings toggle.
    func applyRemoteListenerSetting() {
        setRemoteListenerEnabled(settings.remoteListenerEnabled, persist: false)
    }

    func setRemoteListenerEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist { settings.remoteListenerEnabled = enabled }
        remoteListenerFailure = nil
        if enabled {
            guard remoteListenerBoundPort == nil else { return }
            let port = UInt16(clamping: settings.remoteListenerPort)
            do {
                remoteListenerBoundPort = try server.startRemoteListener(
                    port: port,
                    tokenURL: ShepherdPaths.remoteTokenURL()
                )
            } catch {
                // Surfaced in Settings AND logged — on a headless host nobody
                // is looking at Settings.
                remoteListenerFailure = RemoteListenerFailure(error, port: port)
                NSLog("Shepherd: remote listener failed to start: \(error)")
            }
        } else if remoteListenerBoundPort != nil {
            server.stopRemoteListener()
            remoteListenerBoundPort = nil
        }
    }

}
