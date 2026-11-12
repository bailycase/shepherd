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

/// GUI-owned view state over the host's workspace snapshot (`localHost`).
/// Navigation is the sidebar: an agent row shows that agent's thread (and any terminal panes
/// beside it); a space row is a disclosure. Tabs exist only in persisted state as per-agent
/// layout containers — there is no tab UI.
@MainActor
@Observable
final class ShepherdViewModel {
    var state: ShepherdState
    /// Issues & PRs, read through this Mac's host (`SessionServer.forge`).
    @ObservationIgnored lazy var forgeStore = ForgeStore(transport: { [weak self] in
        await self?.forge($0) ?? .failure(ForgeError(.unreachable, "Shepherd is closing."))
    })
    /// The branch card's pull request read (`gh` on this Mac, as its git reads are); it pins nothing.
    @ObservationIgnored lazy var branchForge = ForgeService(
        pinsURL: pi.home.deletingLastPathComponent().appendingPathComponent("forge-pins.json"))
    /// Each local thread's branch's pull request (the side pane's Pull request tab), its own page
    /// over the same transport; none while the branch has no pull request.
    var branchPullRequests: [AgentID: ForgeStore] = [:]
    /// Each local thread's link to its branch's pull request, as the host last looked it up and
    /// pushed it (`RemoteReply.pullRequestLinks`): the sidebar's badge reads it.
    var pullRequestLinks: [AgentID: ThreadPullRequest] = [:]
    /// Why a merged pull request's thread was kept open (`PullRequestLinks.closeNotes`), as pushed.
    var pullRequestCloseNotes: [AgentID: String] = [:]
    /// The sidebar's "New mission" was pressed; the Missions page opens its start page and clears it.
    var missionStartRequested = false
    /// The host whose missions the Missions page shows; nil is This Mac.
    var missionsHost: UUID?
    @ObservationIgnored var remoteMissionDrivers: [UUID: RemoteMissionDriver] = [:]
    var selectedSpaceID: SpaceID?
    /// This Mac's spaces whose folder is gone (`checkMissingSpaces`): the sidebar marks them and
    /// no thread starts in them. Live state, never persisted.
    var missingSpaces: Set<SpaceID> = []
    var selectedAgentID: AgentID?
    /// The page the main column shows in place of a thread (New thread, Automations, Hosts);
    /// nil while a thread shows. Picking a row clears it. Ephemeral, like all selection state.
    var destination: MainDestination?
    /// The sidebar's More is open, showing Hosts and Extensions. Ephemeral.
    /// Activity groups, cached on their source, pins and seen completion generations.
    @ObservationIgnored var sidebarListsCache: (source: SidebarSource, pins: SidebarPins, seen: [SidebarRowID: Int], lists: SidebarLists)?
    @ObservationIgnored var sidebarProjectsCache: (key: SidebarProjectsKey, rows: [SidebarLogicalProject])?
    var sidebarCompletions = SidebarCompletions()
    /// Prompted creations belong in Working before pi reports its first turn.
    var sidebarOpeningTurns: Set<AgentID> = [] {
        didSet {
            if oldValue != sidebarOpeningTurns {
                watchThreadRevisions(of: threadStores.live.union(sidebarOpeningTurns))
            }
        }
    }
    @ObservationIgnored var sidebarPreparingOpeningTurns: Set<AgentID> = []
    /// The run on screen that Run Now is replacing: its going is no reason to show another thread.
    @ObservationIgnored var replacingRun: AgentID?
    /// Last ten measured tool-completion rates per agent, not a decorative waveform. Each agent's
    /// box is observed by its own row alone, so one agent's tool call redraws no other row.
    @ObservationIgnored var sidebarActivityBoxes: [AgentID: SidebarActivityBox] = [:]
    var sidebarActivitySamples: [AgentID: [Double]] {
        sidebarActivityBoxes.compactMapValues { $0.samples.isEmpty ? nil : $0.samples }
    }
    /// The agent's box, made on first ask so the row observing it sees the samples arrive.
    func sidebarActivityBox(_ id: AgentID) -> SidebarActivityBox {
        if let box = sidebarActivityBoxes[id] { return box }
        let box = SidebarActivityBox()
        sidebarActivityBoxes[id] = box
        return box
    }
    @ObservationIgnored var sidebarActivityLast: [AgentID: Date] = [:]
    var sidebarSeenCompletions: [SidebarRowID: Int] = [:]
    /// Last opened thread, even while a destination covers it.
    @ObservationIgnored var sidebarReadingThread: SidebarRowID?
    @ObservationIgnored var sidebarReadingCompletion: Int?
    /// The project tree, derived once per change of what it reads (`SidebarSource`, and
    /// `SidebarTreeOptions` from Settings ▸ Appearance ▸ Sidebar).
    @ObservationIgnored var sidebarTreeCache: (source: SidebarSource, options: SidebarTreeOptions, tree: SidebarTree)?
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
    /// Share with Git (GitDesignPublish) and Open from Git (GitDesignOpen), while one is up.
    var designGitShare: DesignGitShareModel?
    var designGitOpen: DesignGitOpenModel?
    /// The design whose pull needs a merge, while its dialog (GitDesignConflict) is up.
    var designGitMergeDialog: DesignID?
    /// Each design's Git state, made the first time its chip shows (DesignGitModel).
    @ObservationIgnored var designGitStates: [DesignID: DesignGitDesignState] = [:]
    /// Jump to a board (JumpInContext) over the design on screen, while it is up.
    var designJump: DesignJumpModel?
    /// The boards each design opened lately, for the jump card's Recent section. Kept in the
    /// sidebar's defaults across launches.
    var designJumpRecents = DesignJumpRecents() {
        didSet { if let data = try? JSONEncoder().encode(designJumpRecents) { sidebarDefaults.set(data, forKey: Self.designJumpRecentsKey) } }
    }
    /// Delete design and Delete design system while they ask (DeleteDesignDialog,
    /// DeleteSystemDialog).
    var designDeleteRequest: DesignDeleteRequest?
    var designSystemDeleteRequest: DesignSystemDeleteRequest?
    /// The toast over the main column after a deletion (UndoToast, DeleteFailedToast).
    var designToast: DesignToast?
    /// Implement in a thread's sheet over a design (RefImplementSheet), while it is up.
    var implementSheet: ImplementSheetModel?
    /// The toast on a design's canvas after a reference went (RefSentStay, RefCopied).
    var referenceToast: DesignReferenceToast?
    /// Each local thread's design references: its chips, "Looked at…" lines and @ picker.
    @ObservationIgnored var referenceChips: [AgentID: DesignReferenceChips] = [:]
    /// Hosts' threads' references (`design.references.v1`), the @ picker's rows of each host
    /// design opened in it, and the kept copies being read.
    @ObservationIgnored var remoteReferenceChips: [RemoteAgentRef: DesignReferenceChips] = [:]
    @ObservationIgnored var remoteKeptReads: [String: Task<(payload: DesignReferencePayload, folder: URL, freshness: DesignReferenceFreshness)?, Never>] = [:]
    /// The designs as references last saw them (their activity and boards): a change reads every
    /// chip's standing again.
    @ObservationIgnored var referenceDesignSignature: [DesignID: [Double]] = [:]
    /// Where Copy reference puts a reference's string: the general pasteboard (tests their own).
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Rename… of a design or a design system, while its sheet is up.
    var designRename: DesignRenameRequest?
    /// An import running (its card first on Designs), and what it asks (ImportFailed,
    /// ImportAgain).
    var designImporting: DesignImporting?
    var designImportPrompt: DesignImportPrompt?
    /// The staged project a prompt waits on, put away if its dialog goes without an answer.
    @ObservationIgnored var stagedDesignImport: UUID?
    /// Where boards attached to a thread are written: the drop folder (tests use their own).
    @ObservationIgnored var designAttachDirectory: URL = AppImageDrop.directory
    /// The Designs page's filter and selected card. Ephemeral.
    var designsPageFilter = ""
    var designsPageSelection: DesignID?
    /// Each design's open comments (`loadDesignCommentCounts`).
    var designCommentCounts: [DesignID: Int] = [:]
    @ObservationIgnored var designsPageCache: (inputs: DesignsPageInputs, model: DesignsPageModel)?
    /// Each design's canvas, kept for the app's run so returning to one finds it as it was.
    @ObservationIgnored var designScreens: [DesignID: DesignScreenModel] = [:]
    /// Designs on screen: only their revisions are pushed (`SessionServer.onDesignRevision`).
    @ObservationIgnored var visibleDesigns: Set<DesignID> = []
    /// Designs whose agent is being started, so a second open waits for it.
    var startingDesignAgents: Set<DesignID> = []
    /// Each remote design's canvas, kept for the app's run like a local one's.
    @ObservationIgnored var remoteDesignScreens: [RemoteDesignRef: DesignScreenModel] = [:]
    /// Each remote host's renderers, made when one of its designs is first drawn.
    @ObservationIgnored var remoteDesignRenderings: [UUID: DesignRendering] = [:]
    /// Remote designs on screen: their hosts push changes for these alone.
    @ObservationIgnored var visibleRemoteDesigns: Set<RemoteDesignRef> = []
    /// This Mac's design systems as last read (DZSystem, the Designs page's systems).
    let designSystems = DesignSystemCatalog()
    /// The system the Design systems page shows (a system without an agent of its own; a
    /// build's page is its agent's layout).
    var shownDesignSystem: String?
    /// A connected host's system the Design systems page shows instead (`design.systems.v1`), and
    /// its read once it lands.
    var shownRemoteSystem: RemoteSystemRef?
    var shownRemoteSystemRead: DesignSystemRead?
    /// The system page last opened: More ▸ Design systems goes back to it.
    @ObservationIgnored var lastDesignSystem: DesignSystemTarget?
    @ObservationIgnored var designSystemPageCache: [DesignSystemTarget: (inputs: DesignSystemPageInputs, model: DesignSystemPageModel)] = [:]
    /// Projects whose system build is being started, so a second click waits for it.
    var startingSystemBuilds: Set<SpaceID> = []
    /// Draws every design's boards (`DesignHost.swift`), once a design or the Designs page is
    /// first shown.
    var designRendering: DesignRendering {
        if let made = madeDesignRendering { return made }
        let store = designStore
        let made = DesignRendering(folder: { store.folder(for: $0) }, network: designNetwork, liveCap: designLiveCap)
        madeDesignRendering = made
        return made
    }
    @ObservationIgnored private(set) var madeDesignRendering: DesignRendering?
    /// The background host's designs on this Mac, read-only, while the app is its client
    /// (`connectLocalHost`): the host writes them; the app draws them from where they are.
    @ObservationIgnored var localHostDesigns: DesignStore?

    /// Where the designs' files are on this Mac: the background host's folder, else the support folder's.
    var designStore: DesignStore { localHostDesigns ?? supportDesigns }
    @ObservationIgnored private lazy var supportDesigns = DesignStore(
        directory: pi.home.deletingLastPathComponent().appendingPathComponent("designs", isDirectory: true))
    /// Tests turn Google Fonts off so boards never reach the network, and previews take no live
    /// views; both are set before the first design draws.
    @ObservationIgnored var designNetwork: DesignRenderingNetwork = .googleFonts
    @ObservationIgnored var designLiveCap = DesignLivePlan.liveCap
    /// Child runs per agent, as published: the palette's Subagents section and the parent's
    /// Working sidebar presentation. A child's question is for its parent, never Needs you.
    /// Ephemeral display state; see `ChildRuns` for the lifecycle rules.
    var childRuns = ChildRuns() {
        didSet { reconcileSidebarCompletions() }
    }
    /// Native diff-review panes keyed by their review leaf. Ephemeral: review
    /// leaves are persisted long enough for layout writes, then purged on the
    /// next app start by the session server.
    var reviewSessions: [PaneID: ReviewSession] = [:] {
        didSet {
            for (id, session) in oldValue where reviewSessions[id] !== session { session.cancelLoads() }
        }
    }
    /// Per-agent file tree models for the Files tab, keyed by agent ID. Created on first
    /// Files tab open; removed when the thread is gone.
    var fileTrees: [AgentID: FileTreeModel] = [:]
    /// A remote thread's tree, read from its host over `files.v1`; replaced when its folder there changes.
    var remoteFileTrees: [RemoteAgentRef: FileTreeModel] = [:]
    /// When each agent entered its current status this run: the sidebar's running elapsed
    /// time. Ephemeral; an agent restored at launch counts from its first report.
    var statusSince: [AgentID: Date] = [:]
    /// Agents whose last turn ended in an error: done, but their sidebar row reads failed. An
    /// agent restored idle with `Agent.lastFailure` reads failed too, until a turn starts.
    var failedTurns: Set<AgentID> = []
    /// Agents whose pi stopped (before it served or on its own after), waiting for Retry: their sidebar row reads "can't
    /// start". Ephemeral: a relaunch starts every pi again.
    var cannotStart: Set<AgentID> = []
    /// This Mac's agents whose pi can't start because nothing signs in for their model: the
    /// provider it needs (nil when pi names none), and when it stopped.
    var notSignedIn: [AgentID: NotSignedIn] = [:]
    /// Each automation's run whose agent still exists, as the server's run log keeps it: an
    /// idle run agent is starting until its run has settled (`AutomationRun.isLive`). Read with
    /// every adopted state.
    var openAutomationRuns: [AutomationID: AutomationRun] = [:]
    /// ⌘⇧S hides the sidebar. Persisted, like the other sidebar disclosure choices.
    var sidebarHidden = false {
        didSet { sidebarDefaults.set(sidebarHidden, forKey: "shepherd.sidebarHidden") }
    }
    /// The project tree's closed projects (`SidebarProjectID.key`). Persisted, like hiding the
    /// sidebar.
    var collapsedProjects: Set<String> = [] {
        didSet { sidebarDefaults.set(collapsedProjects.sorted(), forKey: Self.collapsedProjectsKey) }
    }
    static let collapsedProjectsKey = "shepherd.sidebar.collapsedProjects"
    static let designJumpRecentsKey = "shepherd.designs.jumpRecents"
    var collapsedActivitySections: Set<SidebarActivitySection> = [] {
        didSet { sidebarDefaults.set(collapsedActivitySections.map(\.rawValue).sorted(), forKey: Self.collapsedActivitySectionsKey) }
    }
    static let collapsedActivitySectionsKey = "shepherd.sidebar.collapsedActivitySections"
    /// The threads pinned at the top of the Activity sidebar (Sidebar › Pinned), oldest pin first.
    /// Persisted beside the other sidebar choices; changed only by `pinThread`, `unpinThread`
    /// and `pruneSidebarPins` (ShepherdViewModel+SidebarPins).
    var sidebarPins = SidebarPins() {
        didSet { sidebarPins.save(to: sidebarDefaults) }
    }
    /// This Mac's spaces pinned to the top of the Spaces tree (`togglePinSpace`).
    var spacePins = SpacePins() {
        didSet { spacePins.save(to: sidebarDefaults) }
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
    var selectedRemoteAgent: RemoteAgentRef? {
        didSet { if let ref = selectedRemoteAgent, !remoteDeckRefs.contains(ref) { remoteDeckRefs.append(ref) } }
    }
    /// The remote agents shown this session, first shown first: the candidates for pages of the
    /// remote deck (`RemoteDeckPages`). It bounds which pages' values are resolved and decides no
    /// mounting: a page mounts when it is shown. Unobserved, as it changes only beside the
    /// selection or a host's state, which the deck's layer reads.
    @ObservationIgnored var remoteDeckRefs: [RemoteAgentRef] = []
    var remoteFocusedPaneID: PaneID?
    var remoteWorktreeSheet: RemoteAgentRef?
    /// What the background host reported for the worktree in Delete worktree agent's dialog
    /// (`localHost`): the checkout, its loss warning, and the fingerprint its removal is bound to.
    var hostWorktreeInfo: RemoteWorktreeInfo?
    /// What this app last told its background host of the paired Macs it reaches, on which connection.
    @ObservationIgnored var sentProjectHosts: (ObjectIdentifier, [ProjectHostOption])?
    var remoteWorktreeOperationEndpoints: [RemoteAgentRef: UUID] = [:]
    var remoteWorktreeOperationIDs: [RemoteAgentRef: UUID] = [:]
    /// A review pane's Commit… sheet by review session, kept while its commit runs.
    @ObservationIgnored var reviewCommitStores: [UUID: ReviewCommitStore] = [:]
    var remoteChildren: [RemoteAgentRef: [ChildRun]] {
        Dictionary(uniqueKeysWithValues: remoteHosts.allConnections.flatMap { connection in
            connection.children.map { (RemoteAgentRef(hostID: connection.id, agentID: $0.key), $0.value) }
        })
    }
    var reviewDiffLoader: @Sendable (String, String?) async throws -> (files: [DiffFile], reference: String?) = { cwd, reference in
        try await Task.detached(priority: .userInitiated) {
            let resolved = reference == "pr" ? GitDiff.pullRequestReference(cwd: cwd) : reference
            return (try GitDiff.load(cwd: cwd, reference: resolved), resolved)
        }.value
    }
    var remoteReviews: [RemoteAgentRef: ReviewSession] = [:] {
        didSet {
            for (id, session) in oldValue where remoteReviews[id] !== session { session.cancelLoads() }
        }
    }
    /// Where a local review reads its changes from; tests put a fixed engine here. Nil: this Mac's
    /// host (`changes*` queries).
    @ObservationIgnored var changesEngineOverride: ((AgentID, String) -> ChangesEngine)?
    /// When each thread's review was last sent (ms): a review opened after the agent replied
    /// opens on Last turn.
    @ObservationIgnored var reviewSentAt: [SidePaneOwner: Double] = [:]
    /// Host-side utility terminals (a remote `gh auth login`) opened for a remote agent,
    /// shown in place of the agent's own layout while `remoteInspectingAgent` is set.
    var remoteInspectorTabs: [RemoteAgentRef: TabID] = [:]
    var remoteInspectingAgent: RemoteAgentRef?
    var remoteInspectionRequest = UUID()
    var remoteRenameTarget: RemoteAgentRef?
    /// A host's agent waiting on its Delete agent dialog (AppDialogs). Ephemeral.
    var remoteDeleteTarget: RemoteAgentRef?
    /// A terminal tab being renamed (the panel's Rename tab).
    var terminalRenameTarget: TerminalRenameTarget?
    /// The failure the error sheet shows: what was attempted, and why it failed.
    var actionError: ActionError?
    /// The message alone, under a generic title; `fail(_:_:)` names the action.
    var remoteActionError: String? {
        get { actionError?.message }
        set { actionError = newValue.map { ActionError(title: ActionError.genericTitle, message: $0) } }
    }

    /// Reports a failed action under its own title ("Couldn’t fork"), with the error worded for a person.
    func fail(_ title: String, _ error: Error) {
        actionError = ActionError(title: title, message: ActionError.describe(error))
    }

    /// Configured remote Shepherd hosts and their live connections.
    let remoteHosts: RemoteHostStore
    /// Settings ▸ Instructions: pi's root instructions here and on every host, and their sync.
    let instructions: InstructionsModel
    /// Settings ▸ Experiments ▸ Suggested instructions: what this Mac's agents suggested.
    let suggestions: SuggestionsModel
    /// Settings ▸ Pi ▸ Slash commands: the commands pi lists on this Mac, and which the `/` menu hides.
    let slashCommands: SlashCommandsModel
    /// Settings › Hooks and the composer's hook glyph.
    let hooks: HooksModel
    /// Settings › Apps, and the apps running now.
    let apps: AppsModel
    /// Settings ▸ Fleet: this Mac's fleet as its host reports it.
    let fleet = FleetSettingsModel()
    /// The thread whose Browser waits for each app's address.
    @ObservationIgnored var appPageWaits: [AppKey: AgentID] = [:]
    /// Each remote host's hooks, made when first shown (`hooks(for:)`).
    @ObservationIgnored var remoteHookModels: [UUID: HooksModel] = [:]
    /// Settings ▸ Skills: every host's agent skills, This Mac's through its host.
    let skills: ClientSkills
    /// Settings ▸ MCP servers: this Mac's servers, their sign-ins, and the credentials agents ask for.
    let mcp: MCPStore
    /// Settings ▸ Pi's sign-ins and From your pi, and the first launch's copy and welcome step.
    let yourPi: YourPiModel
    /// Shepherd's pi's sign-ins: the sign-in sheet, sign-outs, what expired, what agents wait on.
    let piAuth: PiAuthStore
    /// Restored agents wait for the first launch's copy from the user's pi, and for its welcome
    /// step when no provider can start them.
    @ObservationIgnored private(set) var holdsForWelcome = false
    /// This Mac's restored agents the first launch's copy holds (the sidebar's "waiting", the
    /// thread's Waiting to continue), and when they were restored.
    var waitingForImport: Set<AgentID> = []
    @ObservationIgnored private(set) var restoredAt = Date()
    /// The workspace has been adopted at least once.
    @ObservationIgnored private(set) var didAdopt = false
    /// What the membership prunes last ran for (`adopt`).
    @ObservationIgnored private var membershipFingerprint: Int?
    /// Adoptions of a changed snapshot, and the membership prunes they ran (tests).
    @ObservationIgnored private(set) var changedAdoptions = 0
    @ObservationIgnored private(set) var membershipPrunes = 0
    /// The server Settings ▸ MCP servers opens with its row open (a search hit named it).
    @ObservationIgnored var mcpOpenServer: String?
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
        /// Locate Folder… for a space whose folder is gone.
        case relocate(SpaceID)
        var id: String {
            switch self {
            case .local: return "local"
            case .importWorktree(let target): return target.id.uuidString
            case .host(let id): return id.uuidString
            case .relocate(let id): return "relocate.\(id.rawValue)"
            }
        }
    }

    var spacePickerTarget: SpacePickerTarget?
    var addingChildProject: ChildProjectModel?
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
    /// Each triggered automation's trigger state (paused, pending events, next run), and the
    /// host-wide Pause all triggers switch.
    var automationTriggerStatuses: [AutomationID: AutomationTriggerStatus] = [:]
    var automationTriggersAllPaused = false
    /// Each remote host's triggered automations' status (hosts with `automationTriggersCapability`),
    /// read while the Automations page is on screen.
    var remoteAutomationTriggerStatuses: [AutomationKey: AutomationTriggerStatus] = [:]
    /// Run threads whose pull request was looked up recently.
    @ObservationIgnored var checkedRunPullRequests: Set<AgentID> = []
    /// Reads remote hosts' trigger status for the sidebar (`startRemoteAutomationWatch`).
    @ObservationIgnored var remoteTriggerWatch: Task<Void, Never>?
    /// The Automations page's selected row and its filter. Ephemeral.
    var automationsPageSelection: AutomationKey?
    var automationsPageFilter = ""
    /// A sidebar row's Edit…: the Automations page opens its editor on this automation, then clears it.
    var automationEditRequest: AutomationKey?
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
    /// kills the space's agents. The user's own removal skips it once "Don't ask again" was
    /// checked (`requestSpaceDelete`); another process's request always confirms.
    var spaceDeleteTarget: SpaceID?
    /// The pending removal came from another process (`ProjectRequest.delete`): its dialog
    /// offers no "Don't ask again", and a stored skip never answers it.
    var spaceDeleteRequested = false
    /// Rename target for a space (alert in RootView). Display-only rename;
    /// the checkout path never changes.
    var spaceRenameTarget: SpaceID?
    /// Space whose New Worktree sheet is open (sheet in RootView).
    var worktreeSheetTarget: SpaceID?
    /// Worktree agent pending delete confirmation (alert in RootView) —
    /// deleting may also remove the checkout (`requestWorktreeDelete`).
    var worktreeDeleteTarget: AgentID?
    /// Automation pending delete confirmation (sheet in RootView): its prompt, schedule and
    /// settings go with it and nothing brings them back.
    var automationDeleteTarget: AutomationID?
    /// Agent pending delete confirmation (sheet in RootView): deleting stops a run and drops the
    /// thread from the sidebar with nothing to bring it back, so it always confirms.
    var agentDeleteTarget: AgentID?
    /// The last `WorkspaceSelection` and its mounted layouts (`resolvedMountedTabs`).
    @ObservationIgnored var mountedTabsCache: (selection: WorkspaceSelection, tabs: [Tab])?
    /// A confirmed deletion runs after its sheet has dismissed (`sheet(item:onDismiss:)`):
    /// tearing a mounted layout down mid-dismissal wedges the modal session.
    @ObservationIgnored var afterDialogDismiss: (@MainActor () -> Void)?

    /// The branch card's Update from the base, New branch and Rename branch sheets.
    var branchSheet: BranchSheet?
    /// Each local thread's branch card, made when its card first shows.
    @ObservationIgnored var branchCardStores: [AgentID: BranchCardStore] = [:]

    @ObservationIgnored private var childSweepTimer: Timer?
    /// Focus is recorded per layout on every change (clicks, tab switches, new terminals),
    /// so returning to an agent restores the terminal (or thread) you were last working in.
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
    @ObservationIgnored var madeProjects: ProjectsModel?
    @ObservationIgnored var madeLogicalProjects: LogicalProjectsModel?
    /// The Project whose page or settings the main column shows (ProjectLead boards). Ephemeral.
    var selectedLogicalProject: LogicalProjectRef?
    var logicalProjectSettingsTab: LogicalProjectSettingsTab = .general
    /// The New project sheet's draft while it is up.
    var newLogicalProject: NewLogicalProjectDraft?
    /// A Project with no conversation yet draws the shared thread over these (never polled: no host to ask).
    /// The task open in the Project page's right pane.
    var logicalProjectPaneTask: ProjectTaskID?
    /// A published file the person pressed in a task card, with the Project it belongs to: the Files tab of THAT Project previews it
    /// (through the owner) and clears this. Another Project's page never takes it.
    var logicalProjectPaneFile: (ref: LogicalProjectRef, file: ProjectTaskFile)?
    /// The Threads pane beside the conversation: open unless the person closed it with Overview or its close button.
    var logicalProjectPaneOpen = true
    /// The pane's own view state: its tab, a text filter over the tasks, which groups to show, and the wide layout.
    var logicalProjectPaneTab: LogicalProjectPaneTab = .threads
    var logicalProjectPaneQuery = ""
    var logicalProjectPaneSearching = false
    var logicalProjectPaneFilter: Set<ProjectTaskGroup> = []
    var logicalProjectPaneExpanded = false
    /// The Threads pane's width, dragged at its divider as a thread's side pane is: one width for every Project, kept across launches.
    /// The board's 480 box is the 1pt divider and a 479 pane.
    let logicalProjectPane: RightPaneState
    static let logicalProjectPaneWidthKey = "shepherd.projectPaneWidth"
    /// The New thread sheet over a Project (assign a task into one of its Spaces).
    var assigningProjectTask: AssignProjectTaskDraft?
    /// Run on another host, over a Project's task (ProjectRunElsewhere).
    var runningElsewhere: RunElsewhereDraft?
    @ObservationIgnored let emptyProjectConversation = NativeThreadStore()
    @ObservationIgnored let emptyProjectInput = ThreadInput()
    @ObservationIgnored var madeProjectCookies: ProjectCookiesModel?
    @ObservationIgnored var madeSubagentDefinitions: SubagentDefinitionsModel?
    /// Sign-ins remote clients drive on this Mac (`RemoteRequest.hostConfig`).
    @ObservationIgnored let remoteSignIns = RemoteSignIns()
    /// Settings' host picker: the remote host a host-level page shows; nil for this Mac.
    var settingsHostID: UUID?
    /// The background host's launchd job, when this launch may use it (`BackgroundService.prepare`);
    /// nil has the app supervise its own host, with no Settings line. Set at launch.
    @ObservationIgnored var backgroundService: BackgroundService?
    /// Its status as Settings last read it.
    var backgroundServiceStatus: BackgroundService.Status?
    /// A remote host's settings and configuration as Settings shows them (`settingsHostID`).
    @ObservationIgnored let remoteHostSettings = ClientHostSettings()
    @ObservationIgnored let remoteHostConfig = ClientHostConfig()
    @ObservationIgnored let remoteSuggestions = ClientSuggestions()
    var subagentDefinitions: SubagentDefinitionsModel {
        if let madeSubagentDefinitions { return madeSubagentDefinitions }
        let model = SubagentDefinitionsModel(pi: pi)
        madeSubagentDefinitions = model
        return model
    }
    /// Debug builds: the component gallery over the workspace.
    var showComponentGallery = false
    /// ⌘K command palette visibility.
    var showCommandPalette = false
    /// An image open full size (ThreadImageOpen); nil when none is.
    var imageViewer: ImageViewerState?
    /// Stable identity in the window environment, independent of shell geometry.
    let diagramPresentation = SHDiagramPresentation()
    /// A Mermaid diagram open full screen (its source); nil when none is.
    var diagramViewer: String? {
        get { diagramPresentation.source }
        set { diagramPresentation.source = newValue }
    }
    /// Reveal in Finder and Copy for the viewer; a test replaces them.
    @ObservationIgnored var imageViewerActions = ImageViewerActions()

    /// Closes the viewer and stops what it was still fetching.
    func closeImageViewer() {
        imageViewer?.close()
        imageViewer = nil
    }
    var agentRenameTarget: AgentID?
    /// True while ⌘ has been held ~250ms — sidebar rows show their ⌘1–9 keycaps.
    var showAgentShortcutBadges = false

    /// Native thread state per local agent and per remote agent.
    let threadStores = NativeThreadStores<AgentID>()
    let remoteThreadStores = NativeThreadStores<RemoteAgentRef>()
    /// Hidden readers scrolled into a thread's history, shared by both store sets (`NativeThreadStores`).
    let threadReaderPins = ThreadReaderPins()
    /// Keyboard commands for the thread on screen.
    let threadCommands = ThreadCommandCenter()
    /// The menu bar's narrow view of this model (`MenuStateSync` keeps it current).
    let menuState = MenuState()
    /// Which native subagent an agent's workspace is inspecting (the side panel).
    let subagentInspector = RightPaneState()
    /// Each local thread's Browser page (`BrowserHost.swift`).
    let browsers: BrowserSessions
    /// Each layout's terminal panel under its thread (`TerminalPanels`).
    let terminalPanels = TerminalPanels()
    /// System notifications when an unwatched agent finishes, fails, or asks, or a subagent asks.
    let notifications = AgentNotifications()
    /// When local threads' turns and questions post (`ThreadBanners`): through `notifications`,
    /// quiet while you watch.
    @ObservationIgnored lazy var threadBanners = ThreadBanners(
        state: { [unowned self] in self.state },
        sink: .init(post: { [unowned self] in self.notifications.post($0) },
                    remove: { [unowned self] in self.notifications.remove($0) },
                    isWatching: { [unowned self] in self.isWatching($0) },
                    notifyOnTurnFinished: { [unowned self] in self.settings.notifyOnTurnFinished }),
        request: { [unowned self] in try await self.nativeThread($0, request: $1) })
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
    @ObservationIgnored var missingSpaceWatch: Task<Void, Never>?
    /// `paths`: the spaces the last adopt-time pass read, so a broadcast that moved no space runs none.
    @ObservationIgnored var missingSpaceCheck = (running: false, again: false, paths: [String]?.none)
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
    /// Layouts shown at least once this session (`WorkspaceSelection.shownTabIDs`): a layout
    /// mounts the first time its agent is shown and stays mounted. Not observed: it changes only
    /// alongside the active tab, which is, and recording the tab on screen never changes what
    /// mounts at that moment.
    @ObservationIgnored var shownTabIDs: Set<TabID> = []
    @ObservationIgnored var parkSweepTimer: Timer?
    /// One-shot launch guard for autoStartAutomations.
    var didAutoStartAutomations = false
    /// Recently selected agents, most recent last, no duplicates. When the
    /// selected agent goes away (⌘⇧W, process exit) selection returns to the
    /// agent you were on before it — not the space's blank shell.
    var selectionHistory: [AgentID] = []
    /// Workspace mutations are optimistic so the UI stays responsive, but the
    /// server remains authoritative. This tail makes their persistence order
    /// explicit and gives failures one reconciliation path.
    @ObservationIgnored var persistenceTail: Task<Void, Never>?

    /// The local pi home: sessions root, catalog, home.
    let pi: PiSetup

    init(
        pi: PiSetup = .app,
        settings: AppSettings? = nil,
        keybindings: KeybindingsStore? = nil,
        themeManager: ThemeManager? = nil,
        remoteHosts: RemoteHostStore? = nil,
        sidebarDefaults: UserDefaults = .standard,
        themeInstaller: @escaping (ShepherdTheme) throws -> Void = { theme in
            try ShepherdThemeMarker.install(for: theme)
        },
        mcp: MCPStore? = nil,
        welcomesYourPi: Bool = false,
        yourPi: YourPiModel? = nil,
        piAuth: PiAuthStore? = nil,
        browserData: BrowserDataStores = .ephemeral,
        hooks: HooksModel? = nil,
        apps: AppsModel? = nil
    ) {
        self.browsers = BrowserSessions(dataStores: browserData)
        self.state = ShepherdState()
        self.pi = pi
        self.settings = settings ?? .shared
        self.sidebarDefaults = sidebarDefaults
        logicalProjectPane = RightPaneState(widthKey: Self.logicalProjectPaneWidthKey,
                                            defaultWidth: SHLeadMetrics.paneWidth - AppLayout.dividerWidth, defaults: sidebarDefaults)
        LegacyTerminalAgents.forgetPresentationPreferences(in: sidebarDefaults)
        self.keybindings = keybindings ?? .shared
        self.themeManager = themeManager ?? .shared
        let hosts = remoteHosts ?? RemoteHostStore()
        self.remoteHosts = hosts
        threadStores.hostName = { _ in localHostName }
        threadStores.pins = threadReaderPins
        remoteThreadStores.pins = threadReaderPins
        // Remote threads on screen (in any window) ask their host for revision hints; a hint wakes only a store already polling.
        remoteThreadStores.onLiveChange = { [weak hosts] live in hosts?.updateThreadHints(live: live) }
        hosts.onNativeThreadChanged = { [weak remoteThreadStores] ref in remoteThreadStores?.existing(for: ref)?.historyChanged() }
        remoteThreadStores.hostName = { [weak hosts] ref in hosts?.allConnections.first { $0.id == ref.hostID }?.config.name }
        let instructions = InstructionsModel(remoteHosts: hosts, defaults: sidebarDefaults)
        instructions.piHome = pi.home
        self.instructions = instructions
        self.suggestions = SuggestionsModel(instructions: instructions, remoteHosts: hosts)
        self.skills = ClientSkills(defaults: sidebarDefaults)
        // The host's catalog arrives on connect (`localHostSettingsChanged`).
        self.slashCommands = SlashCommandsModel(hidden: self.settings.hiddenSlashCommands)
        // This Mac's hook files, as the host reads them.
        let hookHome = HookCatalog.home(fallback: pi.userHome)
        self.hooks = hooks ?? HooksModel(home: hookHome, support: pi.home.deletingLastPathComponent())
        self.apps = apps ?? AppsModel(home: hookHome)
        self.mcp = mcp ?? MCPStore(dependencies: .app(pi: pi, openURL: { NSWorkspace.shared.open($0) },
                                                      copy: ShepherdViewModel.copyToPasteboard))
        self.installThemeMarker = themeInstaller
        self.yourPi = yourPi ?? YourPiModel(pi: pi)
        self.piAuth = piAuth ?? PiAuthStore(pi: pi)
        self.selectedSpaceID = nil
        self.selectedAgentID = nil
        self.focusedPaneID = nil

        // The tree's disclosure keys (collapsed spaces, hosts, This Mac, the Automations
        // footer) stay in older preferences and are no longer read.
        sidebarHidden = sidebarDefaults.bool(forKey: "shepherd.sidebarHidden")
        collapsedProjects = Set(sidebarDefaults.stringArray(forKey: Self.collapsedProjectsKey) ?? [])
        if let data = sidebarDefaults.data(forKey: Self.designJumpRecentsKey),
           let recents = try? JSONDecoder().decode(DesignJumpRecents.self, from: data) {
            designJumpRecents = recents
        }
        collapsedActivitySections = Set((sidebarDefaults.stringArray(forKey: Self.collapsedActivitySectionsKey) ?? [])
            .compactMap(SidebarActivitySection.init(rawValue:)))
        sidebarPins = SidebarPins(defaults: sidebarDefaults)
        spacePins = SpacePins(defaults: sidebarDefaults)

        // The selected thread keeps its history whatever its recency (`NativeThreadStores`).
        threadStores.protected = { [weak self] in self?.selectedAgentID.map { [$0] } ?? [] }
        remoteThreadStores.protected = { [weak self] in self?.selectedRemoteAgent.map { [$0] } ?? [] }
        // A sign-in or sign-out: Settings reads both sides again.
        self.piAuth.onChanged = { [weak yourPi = self.yourPi] in
            Task { await yourPi?.refresh() }
        }
        self.piAuth.onSignedIn = { [weak self] provider in self?.signInLanded(provider) ?? 0 }
        // The first launch checks what came over against Shepherd's own pi: its default model and its logins.
        self.yourPi.settingsDefaultModel = { [weak self] in self?.settings.agentDefaults.model }
        self.yourPi.onDefaultChosen = { [weak self] model in self?.settings.defaultModel = model }
        self.yourPi.checkLogins = { [weak piAuth = self.piAuth] providers in await piAuth?.checkLogins(providers) ?? [:] }
        // Logins re-imported from your pi: agents waiting on a sign-in try again.
        self.yourPi.onSignInsChanged = { [weak self] in _ = self?.retrySignedOutAgents(nil) }
        // A host that comes back takes the instruction and skill changes it is owed.
        hosts.onHostConnected = { [weak self, weak instructions = self.instructions] hostID in
            instructions?.hostConnected(hostID)
            self?.skillsHostConnected(hostID)
        }
        threadStores.configure = { [weak self] agent, store in store.offline = self?.coordinatorHeldOff(agent) ?? false }
        threadStores.drafts = ComposerDrafts(defaults: sidebarDefaults)
        threadStores.onLiveChange = { [weak self] live in
            guard let self else { return }
            watchThreadRevisions(of: live.union(sidebarOpeningTurns))
        }
        notifications.onResponse = { [weak self] response in
            self?.respond(to: response)
        }
        self.remoteHosts.onDropError = { [weak self] in self?.remoteActionError = $0 }
        self.remoteHosts.onDesignChanged = { [weak self] host, design, revision, comments in
            self?.remoteDesignChanged(RemoteDesignRef(hostID: host, designID: design), revision: revision, comments: comments)
        }
        self.remoteHosts.onProjectionChanged = { [weak self] in
            self?.refreshProjectHosts()
            guard let self else { return }
            self.syncLocalHostChildren()
            self.reconcileSidebarCompletions()
            self.notifyRemote()
            let liveRemote = Set(self.remoteHosts.allConnections.flatMap { connection in
                connection.state.agents.map { RemoteAgentRef(hostID: connection.id, agentID: $0.id) }
            })
            self.remoteThreadStores.prune(live: liveRemote)
            self.remoteDeckRefs.removeAll { !liveRemote.contains($0) }
            self.browsers.prune(liveRemote: liveRemote, hosts: self.remoteHosts)
            self.syncRemoteBrowserDrive()
            self.pruneRemoteDesigns()
            self.pruneSidebarPins()
            for (target, review) in self.remoteReviews where review.hostReviewPane {
                guard let connection = self.remoteHosts.allConnections.first(where: { $0.id == target.hostID }),
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
        installReviewHandler()
        installDesignRenderHandler()
        installRemoteBrowserDrive()
        self.settings.onProjectsChange = { [weak self] _ in self?.projectsExperimentChanged() }
        // Host role: bind the remote listener at VM creation, not from a
        // window's .task — a restored-minimized or slow-to-render window
        // must not leave a host Mac unreachable; the .task call remains as a
        // no-op-if-bound backstop.
        applyRemoteListenerSetting()
        // The `/` menu of every thread leaves out what Settings ▸ Pi ▸ Slash commands turned off.
        self.settings.onHiddenSlashCommandsChange = { [weak model = self.slashCommands] names in model?.setHidden(names) }
        installCompactionThreshold()

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
        trackFocusedThread()
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.modifierFlagsChanged([])
                self?.syncFocusedThread()
            }
        }
        // Back from another app: spaces whose folder went, and the focused thread.
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkMissingSpaces()
                self.syncFocusedThread()
            }
        }
        installMissingSpaceWatch()
        installProjectRuntime()
        self.hooks.spacePaths = { [weak self] in self?.state.spaces.filter { !$0.hidden }.map(\.path) ?? [] }
        self.fleet.host = { [weak self] in try self?.remoteHosts.thisMacHost() }
        self.fleet.browse = { update in
            let browser = FleetBrowser()
            browser.start(update)
            return { browser.stop() }
        }
        self.apps.spaces = { [weak self] in self?.state.spaces.filter { !$0.hidden } ?? [] }
        self.apps.currentSpace = { [weak self] in self?.selectedRemoteAgent == nil ? self?.selectedAgent?.spaceID : nil }
        installApps()
        // The first launch of a build with Shepherd's own pi: restored agents (and automations)
        // wait until the copy from the user's pi is over, and, when no provider can start them,
        // until the welcome step closes.
        if welcomesYourPi {
            holdsForWelcome = true
            Task { [weak self] in
                guard let self else { return }
                self.applyFirstLaunchHold(await self.yourPi.runFirstLaunch(models: { [weak self] in self?.firstLaunchModels ?? [] }))
            }
        }
    }

    /// The first launch's sheet is over (closed, skipped, or never shown): it goes, and restored
    /// agents start if they still wait.
    func finishImport() {
        yourPi.importSheet = nil
        piAuth.closeSheet()
        releaseStarts()
        if !waitingForImport.isEmpty { waitingForImport = [] }
        // The copy (or a default chosen on the sheet) changed what a new thread starts on: the open page's chip names it.
        if destination == .newThread { newThread.prepare(for: self) }
    }

    /// Who waits for the first launch's sheet: nobody, everyone, or the agents whose model's
    /// provider it asks for (the rest start at once).
    func applyFirstLaunchHold(_ hold: YourPiModel.Hold) {
        switch hold {
        case .none:
            releaseStarts()
            if !waitingForImport.isEmpty { waitingForImport = [] }
        case .all:
            let all = Set(state.agents.map(\.id))
            if waitingForImport != all { waitingForImport = all }
        case .agents(let providers):
            let held = agentIDs(using: providers)
            releaseStarts()
            if waitingForImport != held { waitingForImport = held }
        }
    }

    /// This Mac's agents whose model (or, with none, the default model) is one of `providers`'.
    func agentIDs(using providers: Set<String>) -> Set<AgentID> {
        let fallback = settings.agentDefaults.model ?? yourPi.survey?.shepherdDefaultModel
        return Set(state.agents.filter { agent in
            guard let model = agent.model ?? fallback, let slash = model.firstIndex(of: "/") else { return false }
            return providers.contains(String(model[..<slash]))
        }.map(\.id))
    }

    /// Retry, on a first launch's sheet that couldn't read your pi's sign-ins: once they come over
    /// and nothing more is asked, restored agents start.
    func retryImportSignIns() {
        Task { applyFirstLaunchHold(await yourPi.retrySignIns()) }
    }

    /// A sign-in landed in Shepherd's pi. The first launch's sheet shows it signed in, or, for a
    /// new user, closes. Returns how many waiting agents started again.
    func signInLanded(_ provider: String) -> Int {
        if let sheet = yourPi.importSheet {
            if sheet.stage == .newUser {
                finishImport()
            } else {
                Task { await yourPi.signInLanded(provider) }
            }
        }
        return retrySignedOutAgents(provider)
    }

    /// The models restored agents use, and Shepherd's default: their providers are what the first
    /// launch's sheet asks for when nothing covers them.
    var firstLaunchModels: [String] {
        state.agents.compactMap(\.model) + [settings.agentDefaults.model].compactMap { $0 }
    }

    /// The first launch's hold is over: restored agents start, the one on screen first, and so do
    /// enabled automations.
    private func releaseStarts() {
        guard holdsForWelcome else { return }
        holdsForWelcome = false
        if didAdopt, !didAutoStartAutomations {
            didAutoStartAutomations = true
            autoStartAutomations()
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
        missingSpaceWatch?.cancel()
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
            // Mirrors the Agent menu's digit rows: live only for an existing row.
            guard sidebarShortcutRows.count >= digit else { return false }
            showCommandPalette = false
            selectAgentDigit(digit)
            return true
        case .adjacentAgent(let delta):
            // ⌘↑ and ⌘↓ in a draft of several lines are the text view's own: the caret goes to
            // the document's start or end, as in every Mac text view, and the agent stays.
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
               Self.draftTakesVerticalChord(KeyChord(event: event), draft: text.string) {
                text.interpretKeyEvents([event])
                return true
            }
            selectAdjacentAgent(delta)
            return true
        case nil:
            return false
        }
    }

    /// Whether a plain ⌘↑ or ⌘↓ belongs to the text view under the keyboard: only when the
    /// draft spans more than one line, so a one-line composer still switches agents.
    static func draftTakesVerticalChord(_ chord: KeyChord?, draft: String) -> Bool {
        guard let chord, chord == KeyChord(key: "up", command: true) || chord == KeyChord(key: "down", command: true) else { return false }
        return draft.contains(where: \.isNewline)
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

    /// The thread stores follow the owner's state on every adoption, equal snapshot or not: a store is
    /// cheap to check and "held off" also reads session liveness, which no snapshot carries.
    private func reconcileThreadStores() {
        // A Project's coordinator ID is recorded before its agent is registered, while its page already holds the store: keep it.
        threadStores.prune(live: Set(state.agents.map(\.id)).union(state.projects.compactMap(\.coordinatorAgentID)))
        // The owner's state, not a page's lifetime, says whether a coordinator's pi is held off on purpose: every adoption restates it.
        for agent in state.projects.compactMap(\.coordinatorAgentID) + state.missions.flatMap({ $0.run?.attempts.compactMap(\.agentID) ?? [] }) {
            guard let store = threadStores.existing(for: agent) else { continue }
            let held = coordinatorHeldOff(agent)
            if store.offline != held { store.offline = held }
        }
    }

    /// Adopt a server snapshot wholesale, keeping selection when IDs persist.
    func adopt(_ serverState: ShepherdState) {
        // The host's run log is read on its `automationsChanged` (`loadLocalAutomationRuns`).
        // A status report and a checkout read each broadcast the whole workspace, equal or not.
        // Assigning `state` invalidates every view that read any part of it, so an equal snapshot
        // stops here: one `==` instead of the sidebar, workspace, menu and palette fan-out.
        guard !didAdopt || state != serverState else {
            reconcileThreadStores()
            return
        }
        // A restored agent's last outcome, before any status report this run: the row reads
        // failed as it did at quit, not idle.
        for agent in serverState.agents where statusSince[agent.id] == nil && Self.persistedTurnFailed(agent) != failedTurns.contains(agent.id) {
            if Self.persistedTurnFailed(agent) { failedTurns.insert(agent.id) } else { failedTurns.remove(agent.id) }
        }
        let shownBefore = shownDesign?.id
        // As the background host's client, a status arrives in the workspace, not as a session's
        // report: each change runs what the report would (notifications, failed rows, cards).
        if localHost != nil {
            for agent in serverState.agents {
                guard let old = state.agents.first(where: { $0.id == agent.id })?.status, old != agent.status else { continue }
                applyAgentStatus(agent.id, agent.status, failure: agent.status == .done ? agent.lastFailure.map { TurnFailure(message: $0) } : nil)
            }
        }
        if !sidebarOpeningTurns.isEmpty {
            let removed = Set(state.agents.map(\.id)).subtracting(serverState.agents.map(\.id))
            sidebarOpeningTurns.subtract(removed)
            sidebarOpeningTurns.subtract(serverState.agents.filter { $0.status != .idle }.map(\.id))
        }
        // The checkout of the thread whose layout is on screen: its count is no layout's input, so
        // its card is asked to read again when the count moves. A hidden card reads when shown.
        let shown = selectedAgent.flatMap { $0.tabID == activeTabID ? ($0.id, $0.checkout) : nil }
        state = serverState
        if let (id, checkout) = shown, state.agents.first(where: { $0.id == id })?.checkout != checkout {
            branchCardStores[id]?.requestRefresh()
        }
        // A move keeps the selected thread and its existing layout visible in its new space.
        if destination == nil, selectedRemoteAgent == nil, let agent = selectedAgent, selectedSpaceID != agent.spaceID {
            selectedSpaceID = agent.spaceID
        }
        // A status or checkout broadcast changes no folder: the stat pass runs when the spaces do.
        let paths = state.spaces.map(\.path)
        if paths != missingSpaceCheck.paths {
            missingSpaceCheck.paths = paths
            checkMissingSpaces()
            // The thread header's and New thread's apps follow the spaces.
            apps.reload()
        }
        reconcileSidebarCompletions()
        reconcileThreadStores()
        browsers.prune(state: state)
        notifyLocalQuestions()
        // A deleted agent waits on no sign-in.
        if notSignedIn.keys.contains(where: { id in !state.agents.contains { $0.id == id } }) {
            notSignedIn = notSignedIn.filter { entry in state.agents.contains { $0.id == entry.key } }
            let needed = Set(notSignedIn.values.compactMap(\.provider))
            if piAuth.needed != needed { piAuth.needed = needed }
        }
        didAdopt = true
        changedAdoptions += 1
        pruneMembership()
        // First adoption of the restored workspace: stand the enabled
        // automation watches back up (their agents died with the last run), once the first
        // launch's welcome step is over.
        if !didAutoStartAutomations, !holdsForWelcome {
            didAutoStartAutomations = true
            autoStartAutomations()
        }
        // A design on screen that went (deleted here, or by another device on this host): the
        // window goes back to Designs (DesignDeleted), not to another thread.
        if let gone = shownBefore, destination == nil, !state.designs.contains(where: { $0.id == gone }) {
            openDestination(.designs)
        }
        // The host's push removed the selected agent (deleted here first, then restated by an
        // earlier push, or deleted elsewhere): nothing points at it.
        if selectedAgentID != nil, selectedAgent == nil { selectedAgentID = nil }
        let standing = WorkspaceSelection.standingSpace(selectedSpaceID, agentSelected: selectedAgent != nil, in: state)
        if standing != selectedSpaceID { selectedSpaceID = standing }
        // With nothing on screen (the shown agent went away, or the app just launched), the
        // agent shown before it comes back, else the most recently active on this Mac; with no
        // agents at all, the New thread page shows. A page the user opened stays.
        if selectedAgent == nil, destination == nil, selectedRemoteAgent == nil, replacingRun == nil || replacingRun != selectedAgentID {
            // A Project's threads live under the Project: none is shown in its place unless the person opened it before.
            let live = Set(state.agents.filter { $0.coordinatorFor == nil }.map(\.id))
            if let next = selectionHistory.last(where: live.contains) ?? launchAgentID,
               let agent = state.agents.first(where: { $0.id == next && $0.coordinatorFor == nil }),
               !state.isProjectWorker(next) || selectionHistory.contains(next) {
                willOpenSidebarThread(design(drawnBy: agent).map { .design($0.id) } ?? .local(agent.id))
                selectedAgentID = agent.id
                selectedSpaceID = agent.spaceID
            } else if selectedAgentID != nil {
                // The one shown went and none comes back: nothing is selected.
                selectedAgentID = nil
            }
        }
        if let focused = focusedPaneID, activeTab?.layout.contains(focused) == true {
            // Focused pane survived the new snapshot; keep it.
        } else {
            syncFocus()
        }
    }

    /// What only follows which agents, tabs, spaces and designs exist (reviews, designs' screens and reference chips, file
    /// trees, pins, focus memory) runs when those change, never for a snapshot that changed only statuses or checkouts (a
    /// fleet's reports, one adoption each). Every snapshot is still adopted in order; what depends on each transition
    /// (completions, questions, selection, focus, restoration) runs per snapshot in `adopt`.
    private func pruneMembership() {
        var key = Hasher()
        for agent in state.agents { key.combine(agent.id); key.combine(agent.tabID); key.combine(agent.spaceID) }
        for tab in state.tabs { key.combine(tab) }
        for space in state.spaces { key.combine(space.id); key.combine(space.hidden); key.combine(space.path) }
        for design in state.designs { key.combine(design.id); key.combine(design.lastActiveAt); key.combine(design.boardCount) }
        let fingerprint = key.finalize()
        guard fingerprint != membershipFingerprint else { return }
        membershipFingerprint = fingerprint
        membershipPrunes += 1
        pruneReviewSessions()
        pruneDesigns()
        pruneFileTrees()
        pruneSidebarPins()
        let live = Set(state.agents.map(\.id))
        branchCardStores = branchCardStores.filter { live.contains($0.key) }
        focusMemory.prune(liveTabs: Set(state.tabs.map(\.id)))
    }

    /// An agent's pi stopped (`problem`: why it couldn't start), or started again: the thread's
    /// can't-start and sign-in cards, from the background host's thread or a Retry.
    func agentStopped(_ agentID: AgentID, problem: NativeStartProblem?, stopped: Bool) {
        if stopped { sidebarOpeningTurns.remove(agentID) }
        let waiting = stopped && problem != nil
        if waiting != cannotStart.contains(agentID) {
            if waiting { cannotStart.insert(agentID) } else { cannotStart.remove(agentID) }
        }
        noteSignIn(agentID, problem: stopped ? problem : nil)
        if stopped, let problem, problem.kind == .extensionFailed { switchOffFailedExtensions(agentID, problem: problem) }
    }

    private func applyAgentStatus(_ id: AgentID, _ status: AgentStatus, failure: TurnFailure?) {
        if let index = state.agents.firstIndex(where: { $0.id == id }) {
            let old = state.agents[index].status
            // A repeated report must not invalidate every view that reads the workspace.
            if old != status { state.agents[index].status = status }
            if status != .idle { sidebarOpeningTurns.remove(id) }
            if old != status || statusSince[id] == nil { statusSince[id] = Date() }
            if old != status, old != .blocked, status == .working {
                sidebarActivityBoxes[id]?.samples = []
                sidebarActivityLast[id] = Date()
            }
            // A turn ending reads the branch card again (commits, a push, the PR's checks).
            if old == .working, status != .working { branchCardStores[id]?.requestRefresh() }
            // A session (re)start reports idle; the server still remembers the failure until a
            // turn starts, so the row keeps reading failed.
            let failed = status == .done ? failure != nil : status == .idle && Self.persistedTurnFailed(state.agents[index])
            // pi said a subscription's refresh failed: Sign-in says it expired.
            if let message = failure?.message { piAuth.noteTurnError(message, provider: provider(of: id)) }
            if failed != failedTurns.contains(id) {
                if failed { failedTurns.insert(id) } else { failedTurns.remove(id) }
            }
            notifyStatus(state.agents[index], from: old, failure: failure)
        }
    }

    /// Whether the server kept the agent's last turn (or start problem) as failed across a
    /// relaunch: `Agent.lastFailure`, cleared when a turn starts or ends well.
    static func persistedTurnFailed(_ agent: Agent) -> Bool {
        agent.lastFailure != nil
    }

    /// Runs the ChildRuns TTL/staleness sweep only while rows exist; the
    /// timer dies with the last row, so an idle fleet costs nothing.
    private func syncChildSweepTimer() {
        if childRuns.rows.isEmpty || localHost != nil {
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

    /// One agent's published child runs: the tray, the inspector and the palette show them, and a
    /// host answers a remote client's children query with them. A child that asked its parent a
    /// question is among them, but it asks nothing of the user: no row, banner or badge says so.
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

    /// Applied at startup and from the Settings toggle. The host binds the listener
    /// (`ShepherdHost.serveSettings`), following the setting.
    func applyRemoteListenerSetting() {
        setRemoteListenerEnabled(settings.remoteListenerEnabled, persist: false)
    }

    func setRemoteListenerEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist { settings.remoteListenerEnabled = enabled }
        remoteListenerFailure = nil
    }

    /// The host binds the listener: its port, or why it couldn't, as its settings say.
    func refreshRemoteListener() async {
        guard let host = try? remoteHosts.thisMacHost(), let answer = try? await host.hostSettings() else { return }
        if remoteListenerBoundPort != answer.listenerPort { remoteListenerBoundPort = answer.listenerPort }
        let failure = answer.listenerProblem.map { RemoteListenerFailure(sentence: $0, detail: answer.listenerProblemDetail ?? $0) }
        if remoteListenerFailure != failure { remoteListenerFailure = failure }
    }

}
