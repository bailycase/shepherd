import Foundation
import AppKit
import ShepherdCore
import ShepherdRemote
import ShepherdUI

extension ShepherdViewModel {
    // MARK: Lookups

    var selectedSpace: Space? {
        state.spaces.first { $0.id == selectedSpaceID }
    }

    var selectedAgent: Agent? {
        guard let id = selectedAgentID else { return nil }
        return state.agents.first { $0.id == id }
    }

    var blockedCount: Int {
        // Child runs needing attention count toward the waiting rollup: a
        // stuck subagent is exactly as attention-worthy as a blocked agent.
        return state.agents.count { $0.status == .blocked } + childRuns.attentionCount
            + remoteHosts.connections.filter { $0.phase == .connected }.reduce(0) { total, connection in
                total + connection.state.agents.count { $0.status == .blocked }
                    + connection.children.values.reduce(0) { $0 + $1.count(where: \.needsAttention) }
            }
    }

    /// Spaces the user sees: everything except the reserved hidden automations space (whose
    /// agents are automation runs). They are the New thread page's projects.
    var visibleSpaces: [Space] {
        state.spaces.filter { !$0.hidden }
    }

    /// The spaces connected hosts list.
    var remoteSpaceCount: Int {
        remoteHosts.connections.reduce(0) { count, connection in
            connection.phase == .connected ? count + connection.state.spaces.count { !$0.hidden } : count
        }
    }

    /// Whether `space` is a git checkout, from a probe made once per change of the space list.
    func spaceIsRepo(_ space: Space) -> Bool {
        spaceRepoFlags[space.id] ?? GitWorktree.isRepo(space.path)
    }

    /// Whether each visible space is a git checkout, probed once per change of the space list.
    var spaceRepoFlags: [SpaceID: Bool] {
        let spaces = visibleSpaces
        if let cached = repoBySpace, cached.spaces == spaces { return cached.repos }
        let repos = Dictionary(spaces.map { ($0.id, GitWorktree.isRepo($0.path)) }) { first, _ in first }
        repoBySpace = (spaces, repos)
        return repos
    }

    /// Pure tree filter, separated for tests.
    static func agents(in state: ShepherdState, space: SpaceID) -> [Agent] {
        state.agents.filter { $0.spaceID == space }
    }

    func agent(id: AgentID?) -> Agent? {
        guard let id else { return nil }
        return state.agents.first { $0.id == id }
    }

    // MARK: Sidebar lists

    /// What Needs you and Recents are derived from.
    var sidebarSource: SidebarSource {
        SidebarSource(
            local: state, localChildren: childRuns.rows, failedTurns: failedTurns, statusSince: statusSince,
            openRuns: openAutomationRuns,
            hosts: remoteHosts.connections.filter { $0.phase == .connected }.map {
                SidebarSource.Host(id: $0.id, name: $0.config.name, state: $0.state, children: $0.children)
            })
    }

    /// Needs you and Recents in order, derived again only when what they read changed.
    var sidebarLists: SidebarLists {
        let source = sidebarSource
        if let cached = sidebarListsCache, cached.source == source { return cached.lists }
        let lists = SidebarDerivation.lists(source)
        sidebarListsCache = (source, lists)
        return lists
    }

    /// The lists as the sidebar draws them: the row on screen marked, and ⌘-digits while ⌘ is
    /// held.
    var presentedSidebarLists: SidebarLists {
        sidebarLists.presented(selected: selectedSidebarRow, shortcuts: showAgentShortcutBadges)
    }

    /// The row whose thread is on screen; none while a page is.
    var selectedSidebarRow: SidebarRowID? {
        guard shownDestination == nil else { return nil }
        if let remote = selectedRemoteAgent { return .remote(remote) }
        return selectedAgentID.map { .local($0) }
    }

    /// This Mac's agents in Recents order (Needs you's first): which one shows at launch and
    /// the order their pi starts in.
    var localRecentsOrder: [AgentID] {
        sidebarLists.all.compactMap { row in
            if case .local(let id) = row.id { return id }
            return nil
        }
    }

    /// Hosts neither connected nor connecting: More ▸ Hosts says how many, as the Hosts page does.
    var offlineHostCount: Int {
        remoteHosts.connections.count { HostsPageModel.isOffline($0.phase) }
    }

    // MARK: Destinations

    /// The page the main column shows: the one picked, else New thread when no thread is on
    /// screen (nothing selected, or nothing left to select).
    var shownDestination: MainDestination? {
        if let destination { return destination }
        guard selectedRemoteAgent == nil else { return nil }
        return activeTabID == nil ? .newThread : nil
    }

    /// A destination row: its page (a remote thread on screen leaves it), More's disclosure, or
    /// Extensions, which lives in Settings ▸ Pi.
    func openSidebarDestination(_ target: SidebarDerivation.Destination.Target) {
        switch target {
        case .page(let page): openDestination(page)
        case .more: moreOpen.toggle()
        case .extensions:
            settingsSection = .pi
            showSettings = true
        }
    }

    /// Shows a page in the main column. The thread it covers stays mounted and hidden, as when
    /// switching agents.
    func openDestination(_ page: MainDestination) {
        // New thread opens in the project of the thread on screen, remote ones included.
        if page == .newThread { newThread.prepare(for: self) }
        if page == .hosts, !moreOpen { moreOpen = true }
        if selectedRemoteAgent != nil {
            remoteInspectingAgent = nil
            selectedRemoteAgent = nil
        }
        if destination != page { destination = page }
    }

    /// ⌘N, the first destination: the New thread page, ready to type into.
    func openNewThread(in spaceID: SpaceID? = nil, hostID: UUID? = nil) {
        openDestination(.newThread)
        if let spaceID { newThread.choose(host: hostID, space: spaceID, vm: self) }
        newThread.focusRequest += 1
    }

    // MARK: Selection

    func focusSelectedAgent() {
        if let remote = selectedRemoteAgent {
            selectRemoteAgent(hostID: remote.hostID, agentID: remote.agentID)
        } else if let id = selectedAgentID {
            selectAgent(id)
        }
    }

    /// A Needs you or Recents row.
    func selectSidebarRow(_ row: SidebarRowID) {
        switch row {
        case .local(let id): selectAgent(id)
        case .remote(let ref): selectRemoteAgent(hostID: ref.hostID, agentID: ref.agentID)
        }
    }

    func selectAgent(_ id: AgentID) {
        remoteInspectionRequest = UUID()
        remoteInspectingAgent = nil
        guard let agent = state.agents.first(where: { $0.id == id }) else { return }
        selectedRemoteAgent = nil
        if destination != nil { destination = nil }
        selectionHistory.removeAll { $0 == id }
        selectionHistory.append(id)
        // A restored agent still waiting to start its pi starts now, ahead of the others.
        sessions.startAhead(id)
        selectedAgentID = id
        selectedSpaceID = agent.spaceID
        // A layout still waiting to mount mounts now, as the visible one, and stays mounted when
        // a page covers it next.
        if pendingMountTabIDs.contains(agent.tabID) { pendingMountTabIDs.remove(agent.tabID) }
        sidebarRevealRequest += 1
        focusedPaneID = restoredFocus(forTab: agent.tabID, fallback: agent.paneID)
    }

    /// Reselect the most recently selected agent that still exists, after
    /// `dying` goes away. Falls back to no selection (the New thread page) when history is empty,
    /// leaving a hidden space (a stopped automation run's) for a visible one.
    func selectPreviousAgent(after dying: AgentID) {
        selectionHistory.removeAll { $0 == dying }
        while let candidate = selectionHistory.last {
            if state.agents.contains(where: { $0.id == candidate }) {
                selectAgent(candidate)
                return
            }
            selectionHistory.removeLast()
        }
        selectedAgentID = nil
        let standing = WorkspaceSelection.standingSpace(selectedSpaceID, agentSelected: false, in: state)
        if standing != selectedSpaceID { selectedSpaceID = standing }
    }

    /// The pane to focus when entering `tabID`.
    func restoredFocus(forTab tabID: TabID, fallback: PaneID?) -> PaneID? {
        guard let layout = layout(forTab: tabID) else { return nil }
        return focusMemory.focus(enteringTab: tabID, layout: layout, fallback: fallback)
    }

    /// A space from the palette or the Space menu: the New thread page, in that project.
    func selectSpace(_ id: SpaceID) {
        guard state.spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        openNewThread(in: id)
    }

    /// A remote row shows that agent's thread, served by its host.
    func selectRemoteAgent(hostID: UUID, agentID: AgentID) {
        remoteInspectionRequest = UUID()
        remoteInspectingAgent = nil
        if destination != nil { destination = nil }
        selectedRemoteAgent = RemoteAgentRef(hostID: hostID, agentID: agentID)
        if let connection = remoteHosts.connections.first(where: { $0.id == hostID }),
           let agent = connection.state.agents.first(where: { $0.id == agentID }),
           let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) {
            remoteFocusedPaneID = agent.paneID ?? tab.layout.firstLeaf.id
        } else {
            remoteFocusedPaneID = nil
        }
        sidebarRevealRequest += 1
    }

    /// Sheet-facing wrappers for remote creation; selection follows the new
    /// agent so the sheet closes onto its thread, mirroring local creation.
    func addRemoteSpace(hostID: UUID, path: String) async throws -> SpaceID {
        try await remoteHosts.addSpace(hostID: hostID, path: path)
    }

    func createRemoteAgent(
        hostID: UUID,
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?,
        worktreeBranch: String? = nil,
        worktreeBase: String? = nil,
        worktreeFetchFirst: Bool? = nil
    ) async throws {
        let agentID = try await remoteHosts.createAgent(
            hostID: hostID,
            spaceID: spaceID,
            cwd: cwd,
            model: model,
            thinking: thinking,
            initialPrompt: initialPrompt,
            worktreeBranch: worktreeBranch,
            worktreeBase: worktreeBase,
            worktreeFetchFirst: worktreeFetchFirst
        )
        // The prompt shows while the host's pi starts, as the row the host's first snapshot carries.
        if let opening = OpeningPrompt(initialPrompt, agentID: agentID) {
            remoteThreadStores.store(for: RemoteAgentRef(hostID: hostID, agentID: agentID))
                .preview(opening.preview(model: model, thinking: thinking?.rawValue))
        }
        selectRemoteAgent(hostID: hostID, agentID: agentID)
    }

    /// ⌘1–9: the first nine Recents rows.
    func selectAgentDigit(_ digit: Int) {
        let recents = sidebarLists.recents
        guard recents.indices.contains(digit - 1) else { return }
        selectSidebarRow(recents[digit - 1].id)
    }

    /// ⌘↑/↓: move through the sidebar's rows (Needs you, then Recents), wrapping at the ends.
    func selectAdjacentAgent(_ delta: Int) {
        let rows = sidebarLists.all
        guard !rows.isEmpty else { return }
        let selected = selectedSidebarRow
        let current = rows.firstIndex { $0.id == selected } ?? (delta > 0 ? rows.count - 1 : 0)
        selectSidebarRow(rows[(current + delta + rows.count) % rows.count].id)
    }

    func layout(forTab id: TabID) -> PaneNode? {
        state.tabs.first { $0.id == id }?.layout
    }

    /// ⌥⌘←/→: move pane focus through the panes on screen in order: the thread, then the
    /// terminal panel's selected tab (`visiblePanes`).
    func focusAdjacentPane(_ delta: Int) {
        if let remote = selectedRemoteAgent, let tab = remoteVisibleTab(remote) {
            let thread = remoteInspectingAgent == remote ? nil
                : remoteHosts.connections.first { $0.id == remote.hostID }?.state.agents.first { $0.id == remote.agentID }?.paneID
            let leaves = visiblePanes(layout: tab.layout, key: TerminalPanelKey(host: remote.hostID, tab: tab.id),
                                      thread: thread, focused: remoteFocusedPaneID)
            guard leaves.count > 1 else { return }
            let currentIndex = leaves.firstIndex { $0 == remoteFocusedPaneID } ?? 0
            remoteFocusedPaneID = leaves[(currentIndex + delta + leaves.count) % leaves.count]
            return
        }
        guard let tab = activeTab else { return }
        let thread = selectedAgent.flatMap { $0.tabID == tab.id ? $0.paneID : nil }
        let leaves = visiblePanes(layout: tab.layout, key: TerminalPanelKey(host: nil, tab: tab.id), thread: thread, focused: focusedPaneID)
        guard leaves.count > 1 else { return }
        let currentIndex = leaves.firstIndex { $0 == focusedPaneID } ?? 0
        let next = (currentIndex + delta + leaves.count) % leaves.count
        focusedPaneID = leaves[next]
    }

    /// Focus follows the last pane focused in the active layout, falling back
    /// to the selected agent's own pane and then the layout's first leaf.
    func syncFocus() {
        guard let tab = activeTab else {
            focusedPaneID = nil
            return
        }
        let agentPane = selectedAgent.flatMap { $0.tabID == tab.id ? $0.paneID : nil }
        focusedPaneID = restoredFocus(forTab: tab.id, fallback: agentPane)
    }
}
