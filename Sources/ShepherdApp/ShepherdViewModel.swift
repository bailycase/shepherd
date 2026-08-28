import Foundation
import SwiftUI
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
    /// An automation's watch agent: spawned with SHEPHERD_AUTOMATION=1 so
    /// the panes extension withholds the automation_* tools (a watcher must
    /// never create watchers).
    var isAutomation = false
}

struct AgentStartFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// GUI-owned view state over the in-process session server's snapshot.
/// Navigation is the sidebar: an agent row shows that agent's pane layout, a
/// space row shows the space's shell workspace. Tabs exist only in persisted state as
/// per-agent (and per-space-main) layout containers — there is no tab UI.
@MainActor
final class ShepherdViewModel: ObservableObject {
    @Published var state: ShepherdState
    @Published var selectedSpaceID: SpaceID?
    @Published var selectedAgentID: AgentID?
    /// Collapsed space sections in the sidebar tree. A collapsed space shows
    /// only its header; its agents leave the ⌘1–9 order too. Persisted —
    /// collapse choices survive relaunch, unlike selection.
    @Published var collapsedSpaces: Set<SpaceID> = [] {
        didSet {
            sidebarDefaults.set(collapsedSpaces.map(\.rawValue).sorted(), forKey: "shepherd.collapsedSpaces")
        }
    }
    /// When each agent last changed status, for the header's `blocked 4m`
    /// age. Ephemeral — ages reset with the app, exactly like sessions.
    @Published private(set) var statusChangedAt: [AgentID: Date] = [:]
    /// Live pi-subagents child runs per agent (sidebar subagent rows).
    /// Ephemeral display state; see `ChildRuns` for the lifecycle rules.
    @Published var childRuns = ChildRuns()
    /// The agent whose subagent-inspector layout the workspace is showing
    /// (a subagent row is selected). Ordinary sidebar selection clears it.
    @Published var inspectingAgentID: AgentID?
    /// Which child each agent's inspector pane is currently viewing, so a
    /// re-click navigates instead of relaunching the viewer and the sidebar
    /// can highlight the inspected row. Ephemeral.
    @Published var inspectedChild: [AgentID: String] = [:]
    /// Foreground process name per shell tab ("pi", "htop"), for row labels.
    @Published var shellProcesses: [TabID: String] = [:]
    var shellProcessTimer: Timer?
    /// The global shell the workspace is showing (a SHELLS row is selected);
    /// wins over space/agent selection, cleared by ordinary selection.
    @Published var selectedShellID: TabID?
    /// The remote agent the workspace is showing (a REMOTE row is selected):
    /// host connection id + agent id on that host. Wins over every local
    /// selection; cleared by ordinary selection. Ephemeral, like all
    /// selection state.
    @Published var selectedRemoteAgent: RemoteAgentRef?
    @Published var remoteFocusedPaneID: PaneID?
    /// Configured remote Shepherd hosts and their live connections.
    let remoteHosts: RemoteHostStore
    /// Where the open space-directory browser creates its space: this Mac
    /// or a host. Sheet in RootView; every "new space" entry point (⌘⇧N,
    /// ⌘K, sidebar +) routes here — the system open panel is gone.
    enum SpacePickerTarget: Identifiable, Equatable {
        case local
        case host(UUID)
        var id: String {
            switch self {
            case .local: return "local"
            case .host(let id): return id.uuidString
            }
        }
    }

    @Published var spacePickerTarget: SpacePickerTarget?
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
    @Published var collapsedHosts: Set<UUID> = [] {
        didSet {
            sidebarDefaults.set(collapsedHosts.map(\.uuidString).sorted(), forKey: "shepherd.collapsedHosts")
        }
    }
    @Published var localMachineCollapsed = false {
        didSet { sidebarDefaults.set(localMachineCollapsed, forKey: "shepherd.localMachineCollapsed") }
    }
    /// Remote space disclosure state, keyed by host + space so equal space IDs
    /// on different machines cannot collide. Persisted across relaunches.
    @Published private(set) var collapsedRemoteSpaces: Set<String> = [] {
        didSet {
            sidebarDefaults.set(collapsedRemoteSpaces.sorted(), forKey: "shepherd.collapsedRemoteSpaces")
        }
    }
    /// Last agent selected on each host, so a machine jump returns to where
    /// you were, not the top. Ephemeral.
    var lastRemoteAgentByHost: [UUID: AgentID] = [:]

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
    /// Rename target for a global shell (sheet in RootView).
    @Published var shellRenameTarget: TabID?
    /// Space pending removal confirmation (alert in RootView) — removal
    /// kills the space's agents, so it always confirms.
    @Published var spaceDeleteTarget: SpaceID?
    /// Rename target for a space (alert in RootView). Display-only rename;
    /// the checkout path never changes.
    @Published var spaceRenameTarget: SpaceID?
    /// Agents whose subagent rows are hidden (clicking the selected agent
    /// row toggles this); the row shows an `n sub` chip instead. Ephemeral,
    /// like all child-run display state.
    @Published var collapsedChildren: Set<AgentID> = []
    private var childSweepTimer: Timer?
    /// Focus is recorded per layout on every change (clicks, ⌥⌘←/→, splits),
    /// so returning to an agent restores the pane you were last working in.
    @Published var focusedPaneID: PaneID? {
        didSet {
            guard let paneID = focusedPaneID, paneID != oldValue else { return }
            // Attribute focus to the layout that actually owns the pane, not
            // the active one: selection and focus can move in either order.
            if let tab = state.tabs.first(where: { $0.layout.contains(paneID) }) {
                focusMemory.record(pane: paneID, inTab: tab.id)
            }
        }
    }
    @Published var showNewAgentSheet = false
    /// Whether the in-window settings surface is visible.
    @Published var showSettings = false
    /// ⌘K command palette visibility.
    @Published var showCommandPalette = false {
        didSet { if !showCommandPalette { paletteModifierHeld = false } }
    }
    /// ⌘ held while the palette is open — rows show ⌘1–9 pick hints.
    @Published var paletteModifierHeld = false
    /// The palette's currently visible (filtered) rows, kept fresh by the
    /// view so ⌘digit quick-pick targets what the user actually sees.
    var paletteVisibleRows: [PaletteItem] = []
    @Published var agentRenameTarget: AgentID?
    /// True while ⌘ has been held ~250ms — sidebar rows show their ⌘1–9 keycaps.
    @Published var showAgentShortcutBadges = false
    /// True while the shell-digit chord's modifiers are held — shell rows
    /// show their jump keycaps. Follows the user's configured binding
    /// (⌥⌘ by default, ⌃ if rebound), so the hint can never advertise a
    /// chord that isn't wired.
    @Published var showShellShortcutBadges = false

    let sessions: TerminalSessionStore
    /// System notifications when an unwatched agent finishes or blocks.
    let notifications = AgentNotifications()
    let settings: AppSettings
    private let sidebarDefaults: UserDefaults
    let keybindings: KeybindingsStore
    let themeManager: ThemeManager
    let installPiTheme: (ShepherdTheme) throws -> Void
    private var commandHoldTask: Task<Void, Never>?
    private var flagsMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    /// Last pane focused in each layout (see `PaneFocusMemory`).
    var focusMemory = PaneFocusMemory()
    /// One-shot launch guard for autoStartAutomations.
    var didAutoStartAutomations = false
    /// Recently selected agents, most recent last, no duplicates. When the
    /// selected agent goes away (⌘⇧W, process exit) selection returns to the
    /// agent you were on before it — not the space's blank shell.
    var selectionHistory: [AgentID] = []
    /// Workspace mutations are optimistic so the UI stays responsive, but the
    /// server remains authoritative. This tail makes their persistence order
    /// explicit and gives failures one reconciliation path.
    var persistenceTail: Task<Void, Never>?

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
        }
    ) {
        self.state = ShepherdState()
        self.server = server
        self.settings = settings ?? .shared
        self.sidebarDefaults = sidebarDefaults
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
        collapsedRemoteSpaces = Set(defaults.stringArray(forKey: "shepherd.collapsedRemoteSpaces") ?? [])

        sessions.onStateChanged = { [weak self] serverState in
            self?.adopt(serverState)
        }
        sessions.onTabLayoutChanged = { [weak self] tabID, layout in
            guard let self, let index = self.state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.state.tabs[index].layout = layout
        }
        sessions.onAgentStatus = { [weak self] agentID, status in
            self?.applyAgentStatus(agentID, status)
        }
        notifications.onSelectAgent = { [weak self] agentID in
            guard let self, self.state.agents.contains(where: { $0.id == agentID }) else { return }
            self.selectAgent(agentID)
        }
        // Banners from a previous app run point at dead sessions; drop them.
        notifications.removeAll()
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
        // Remote clients create agents through this host's normal spawn flow.
        server.onRemoteCreateAgent = { [weak self] request, completion in
            guard let self else {
                completion(.failure(RemoteCreateAgentError("host is shutting down")))
                return
            }
            let space = self.state.spaces.first { $0.id == request.spaceID }
            let config = NewAgentConfig(
                spaceID: request.spaceID,
                workingDirectory: request.cwd ?? space?.path ?? "~",
                model: request.model,
                thinking: request.thinking ?? self.settings.defaultThinking,
                initialPrompt: request.initialPrompt
            )
            Task { @MainActor in
                do {
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
        shellProcessTimer?.invalidate()
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    /// Delayed reveal so ordinary chords don't flash the badges. Agent rows
    /// reveal on plain ⌘ (their fixed ⌘1–9 row); shell rows reveal when
    /// exactly the configured shell-digit modifiers are held.
    private func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        // The ⌘K palette owns ⌘-digit hints while open; sidebar badges
        // staying dark keeps one set of digit hints on screen at a time.
        if showCommandPalette {
            commandHoldTask?.cancel()
            commandHoldTask = nil
            showAgentShortcutBadges = false
            showShellShortcutBadges = false
            paletteModifierHeld = flags.contains(.command)
            return
        }
        paletteModifierHeld = false
        let held = flags.intersection([.command, .shift, .option, .control])
        let shellChord = KeybindingsStore.shared.chord(for: .shellDigits)
        var shellModifiers: NSEvent.ModifierFlags = []
        if shellChord.command { shellModifiers.insert(.command) }
        if shellChord.shift { shellModifiers.insert(.shift) }
        if shellChord.option { shellModifiers.insert(.option) }
        if shellChord.control { shellModifiers.insert(.control) }

        let wantAgents = held == [.command]
        let wantShells = !shellModifiers.isEmpty && held == shellModifiers

        commandHoldTask?.cancel()
        commandHoldTask = nil
        if !wantAgents { showAgentShortcutBadges = false }
        if !wantShells { showShellShortcutBadges = false }
        guard wantAgents || wantShells else { return }
        guard (wantAgents && !showAgentShortcutBadges) || (wantShells && !showShellShortcutBadges) else { return }
        commandHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if wantAgents { self?.showAgentShortcutBadges = true }
            if wantShells { self?.showShellShortcutBadges = true }
        }
    }

    /// Adopt a server snapshot wholesale, keeping selection when IDs persist.
    func adopt(_ serverState: ShepherdState) {
        state = serverState
        syncShellProcessTimer()
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
        focusMemory.prune(liveTabs: Set(state.tabs.map(\.id)))

        if let focused = focusedPaneID, activeTab?.layout.contains(focused) == true {
            // Focused pane survived the new snapshot; keep it.
        } else {
            syncFocus()
        }
    }

    private func applyAgentStatus(_ id: AgentID, _ status: AgentStatus) {
        if let index = state.agents.firstIndex(where: { $0.id == id }) {
            let old = state.agents[index].status
            if old != status {
                statusChangedAt[id] = Date()
            }
            state.agents[index].status = status
            // Visible means the workspace is actually showing this agent's
            // layout — not a shell, remote agent, or subagent inspector.
            let visible = selectedAgentID == id
                && selectedShellID == nil
                && selectedRemoteAgent == nil
                && inspectingAgentID == nil
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
                // Copy-out so an idle sweep doesn't publish a no-op change.
                var swept = self.childRuns
                if swept.sweep() { self.childRuns = swept }
                self.syncChildSweepTimer()
            }
        }
    }

    func applyAgentChildren(_ agentID: AgentID, _ children: [ChildRun]) {
        let wasEmpty = childRuns.children(of: agentID).isEmpty
        childRuns.apply(agentID: agentID, children: children)
        let isEmpty = childRuns.children(of: agentID).isEmpty
        if isEmpty {
            collapsedChildren.remove(agentID)
        } else if wasEmpty {
            // New batches start folded; the thread remains the primary row.
            collapsedChildren.insert(agentID)
        }
        syncChildSweepTimer()
    }

    /// Sidebar child rows for one agent.
    func children(of agentID: AgentID) -> [ChildRun] {
        childRuns.children(of: agentID)
    }

    /// Secondary line of the sidebar's waiting summary.
    var waitingSummaryDetail: String {
        let finished = state.agents.count { $0.status == .done }
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        parts.append("\(blockedCount) blocked")
        return parts.joined(separator: ", ")
    }

    // MARK: Remote listener (host role)

    /// The bound port while serving, nil otherwise. Distinct from the
    /// setting: binding can fail (port in use), and the UI must say so.
    @Published private(set) var remoteListenerBoundPort: UInt16?
    @Published private(set) var remoteListenerError: String?

    var remoteListenerEnabled: Bool { settings.remoteListenerEnabled }

    var remoteListenerStatus: String {
        if let port = remoteListenerBoundPort {
            return "Serving on port \(port). Remote Shepherds connect over your VPN."
        }
        if let error = remoteListenerError {
            return "Failed to start: \(error)"
        }
        return "Off. Enable on the Mac whose sessions you want to reach."
    }

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

    /// `blocked 4m`-style age for the header; nil before any transition.
    func statusAge(for id: AgentID) -> String? {
        guard let since = statusChangedAt[id] else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        switch seconds {
        case ..<60: return "\(max(seconds, 0))s"
        case ..<3600: return "\(seconds / 60)m"
        default: return "\(seconds / 3600)h"
        }
    }

}
