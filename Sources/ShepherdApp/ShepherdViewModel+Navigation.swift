import Foundation
import AppKit
import ShepherdCore

/// Memoized sidebar projections, owned by the view model
/// (`sidebarDerivations`) and refreshed only when their inputs change.
/// Everything here derives from (visible spaces, agents, collapsed set);
/// the forest additionally caches on spaces alone since it ignores agents.
struct SidebarDerivations {
    struct TreeInput: Equatable {
        var spaces: [Space]
        var agents: [Agent]
        var collapsed: Set<SpaceID>
    }

    var forestInput: [Space]?
    var forest: [(space: Space, depth: Int)] = []

    var treeInput: TreeInput?
    var tree: [(space: Space, agents: [Agent], depth: Int)] = []
    var ordered: [Agent] = []
    /// ⌘1–9 badge numbers for the first nine ordered agents.
    var badges: [AgentID: Int] = [:]
}

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
        state.agents.count { $0.status == .blocked } + childRuns.attentionCount
    }

    /// Fleet-wide status counts for the sidebar's dot strip, in a fixed
    /// scan order (attention first). Absent statuses are omitted.
    var statusCounts: [(status: AgentStatus, count: Int)] {
        [AgentStatus.blocked, .working, .done, .idle].compactMap { status in
            let count = state.agents.count { $0.status == status }
            return count > 0 ? (status, count) : nil
        }
    }

    /// Blocked queue position of the selected agent, for the status line's
    /// `1 of 3 waiting`. Nil when nothing is blocked.
    var waitingQueue: (position: Int?, total: Int)? {
        let blocked = agentsInForestOrder.filter { $0.status == .blocked }
        guard !blocked.isEmpty else { return nil }
        let position = blocked.firstIndex { $0.id == selectedAgentID }.map { $0 + 1 }
        return (position, blocked.count)
    }

    /// Every space with its agents, in sidebar (declaration) order. `depth`
    /// nests a space under the nearest space whose path contains its path —
    /// spaces are added explicitly, but the parent/child display is derived,
    /// so adding `~/mono/sub-project` after `~/mono` automatically
    /// shows it as a project under MONO.
    /// Spaces that render as rows: everything except the reserved hidden
    /// automations space (whose agents surface through AUTOMATIONS instead).
    var visibleSpaces: [Space] {
        state.spaces.filter { !$0.hidden }
    }

    var spaceTree: [(space: Space, agents: [Agent], depth: Int)] {
        refreshedSidebarDerivations().tree
    }

    /// Recompute the memoized sidebar projections when (and only when) their
    /// inputs changed. The equality checks are linear in spaces + agents;
    /// the recomputes they guard are quadratic in spaces.
    private func refreshedSidebarDerivations() -> SidebarDerivations {
        let input = SidebarDerivations.TreeInput(
            spaces: visibleSpaces,
            agents: state.agents,
            collapsed: collapsedSpaces
        )
        if sidebarDerivations.treeInput == input { return sidebarDerivations }
        let visible = Self.visibleSpaceForest(forest: cachedSpaceForest(input.spaces), collapsed: input.collapsed)
        sidebarDerivations.tree = visible.map { entry in
            (entry.space, Self.sidebarAgents(of: entry.space.id, in: input.agents), entry.depth)
        }
        // Same rows minus collapsed spaces' agents — the ⌘1–9 / palette order.
        sidebarDerivations.ordered = sidebarDerivations.tree
            .filter { !input.collapsed.contains($0.space.id) }
            .flatMap(\.agents)
        sidebarDerivations.badges = Dictionary(
            uniqueKeysWithValues: sidebarDerivations.ordered.prefix(9).enumerated()
                .map { ($0.element.id, $0.offset + 1) }
        )
        sidebarDerivations.treeInput = input
        return sidebarDerivations
    }

    /// Memoized `Self.spaceForest(visibleSpaces)`.
    private func cachedSpaceForest(_ spaces: [Space]) -> [(space: Space, depth: Int)] {
        if sidebarDerivations.forestInput != spaces {
            sidebarDerivations.forest = Self.spaceForest(spaces)
            sidebarDerivations.forestInput = spaces
        }
        return sidebarDerivations.forest
    }

    /// A space's agents in sidebar order: worktree agents first — they read
    /// as part of the space's checkout tree, directly under its header —
    /// then standard agents; declaration order within each group. Every
    /// order producer (tree, ⌘1–9, palette) must use this so badges and
    /// rows never disagree.
    static func sidebarAgents(of space: SpaceID, in agents: [Agent]) -> [Agent] {
        let inSpace = agents.filter { $0.spaceID == space }
        return inSpace.filter { $0.worktreeBranch != nil }
            + inSpace.filter { $0.worktreeBranch == nil }
    }

    /// Flattened depth-first forest of spaces by path containment: children
    /// directly follow their parent, top-level spaces keep declaration order.
    /// Pure, separated for tests.
    static func spaceForest(_ spaces: [Space]) -> [(space: Space, depth: Int)] {
        func normalized(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        }
        // Normalize each path once: `expandingTildeInPath` inside the O(n²)
        // parent search made this function dominate sidebar renders.
        let pathByID = Dictionary(spaces.map { ($0.id, normalized($0.path)) }) { first, _ in first }
        // Parent = the space with the longest path that properly contains
        // this one's (matching on whole path components).
        func parent(of space: Space) -> Space? {
            guard let path = pathByID[space.id] else { return nil }
            return spaces
                .filter { candidate in
                    guard candidate.id != space.id, let candidatePath = pathByID[candidate.id] else {
                        return false
                    }
                    return path.hasPrefix(candidatePath + "/")
                }
                .max { (pathByID[$0.id]?.count ?? 0) < (pathByID[$1.id]?.count ?? 0) }
        }
        let childrenByParent = Dictionary(grouping: spaces.compactMap { space in
            parent(of: space).map { (parentID: $0.id, space: space) }
        }, by: \.parentID).mapValues { $0.map(\.space) }
        let roots = spaces.filter { parent(of: $0) == nil }

        var result: [(space: Space, depth: Int)] = []
        func append(_ space: Space, depth: Int) {
            result.append((space, depth))
            for child in childrenByParent[space.id] ?? [] {
                append(child, depth: depth + 1)
            }
        }
        for root in roots { append(root, depth: 0) }
        return result
    }

    /// Every agent in full forest order, ignoring collapse — the waiting
    /// queue counts blocked agents even inside collapsed spaces.
    private var agentsInForestOrder: [Agent] {
        cachedSpaceForest(visibleSpaces).flatMap {
            Self.sidebarAgents(of: $0.space.id, in: state.agents)
        }
    }

    /// Shared traversal for the sidebar tree and its shortcut order. A
    /// collapsed ancestor hides every deeper entry until the traversal returns
    /// to that ancestor's depth.
    static func visibleSpaceForest(
        _ spaces: [Space],
        collapsed: Set<SpaceID>
    ) -> [(space: Space, depth: Int)] {
        visibleSpaceForest(forest: spaceForest(spaces), collapsed: collapsed)
    }

    /// Collapse filter over a precomputed forest, so cached callers skip the
    /// quadratic forest build.
    static func visibleSpaceForest(
        forest: [(space: Space, depth: Int)],
        collapsed: Set<SpaceID>
    ) -> [(space: Space, depth: Int)] {
        var hiddenBelow: Int? = nil
        return forest.compactMap { entry in
            if let limit = hiddenBelow {
                if entry.depth > limit { return nil }
                hiddenBelow = nil
            }
            if collapsed.contains(entry.space.id) {
                hiddenBelow = entry.depth
            }
            return entry
        }
    }

    /// Pure ordered-agent projection, separated for tests.
    static func orderedAgents(
        in state: ShepherdState,
        collapsed: Set<SpaceID> = []
    ) -> [Agent] {
        visibleSpaceForest(state.spaces.filter { !$0.hidden }, collapsed: collapsed).flatMap { entry -> [Agent] in
            guard !collapsed.contains(entry.space.id) else { return [] }
            return sidebarAgents(of: entry.space.id, in: state.agents)
        }
    }

    /// Pure tree filter, separated for tests.
    static func agents(in state: ShepherdState, space: SpaceID) -> [Agent] {
        state.agents.filter { $0.spaceID == space }
    }

    func agent(id: AgentID?) -> Agent? {
        guard let id else { return nil }
        return state.agents.first { $0.id == id }
    }

    // MARK: Selection

    func selectAgent(_ id: AgentID) {
        guard let agent = state.agents.first(where: { $0.id == id }) else { return }
        // Ordinary selection returns the workspace to the agent's terminal;
        // openChildInspector re-raises the inspector after this call.
        inspectingAgentID = nil
        selectedShellID = nil
        selectedRemoteAgent = nil
        selectionHistory.removeAll { $0 == id }
        selectionHistory.append(id)
        selectedAgentID = id
        selectedSpaceID = agent.spaceID
        revealLocalSpace(agent.spaceID)
        focusedPaneID = restoredFocus(forTab: agent.tabID, fallback: agent.paneID)
    }

    /// Reselect the most recently selected agent that still exists, after
    /// `dying` goes away. Falls back to the space shell when history is empty.
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
    }

    /// The pane to focus when entering `tabID`.
    func restoredFocus(forTab tabID: TabID, fallback: PaneID?) -> PaneID? {
        guard let layout = layout(forTab: tabID) else { return nil }
        return focusMemory.focus(enteringTab: tabID, layout: layout, fallback: fallback)
    }

    /// A space's `shell` row shows the space's shell workspace.
    func selectSpace(_ id: SpaceID) {
        guard state.spaces.contains(where: { $0.id == id }) else { return }
        inspectingAgentID = nil
        selectedShellID = nil
        selectedRemoteAgent = nil
        selectedSpaceID = id
        selectedAgentID = nil
        revealLocalSpace(id)
        syncFocus()
    }

    // MARK: Sidebar reveal

    /// Ancestors of `space` in the sidebar's containment forest, nearest
    /// first. A collapsed ancestor hides the space's row entirely, so these
    /// are exactly the disclosures a selection has to open. Pure, for tests.
    static func ancestorSpaceIDs(of space: SpaceID, in spaces: [Space]) -> [SpaceID] {
        let forest = spaceForest(spaces)
        guard let index = forest.firstIndex(where: { $0.space.id == space }) else { return [] }
        var depth = forest[index].depth
        var ancestors: [SpaceID] = []
        for entry in forest[..<index].reversed() where entry.depth < depth {
            ancestors.append(entry.space.id)
            depth = entry.depth
            if depth == 0 { break }
        }
        return ancestors
    }

    /// Every local selection funnels through here. A row hidden by a closed
    /// disclosure cannot be scrolled into view, so open what hides it: the
    /// THIS MAC root (unified tree, where a collapsed local machine hides the
    /// whole local tree) and the selected space's ancestors. The space's own
    /// disclosure stays as the user left it — its header row is still
    /// visible, and that is what `sidebarRevealTarget` falls back to.
    func revealLocalSpace(_ id: SpaceID?) {
        if localMachineCollapsed { localMachineCollapsed = false }
        // Every local selection also asks the sidebar to scroll to the
        // selected row, even when the selection itself didn't change.
        sidebarRevealRequest += 1
        guard let id else { return }
        let ancestors = Set(Self.ancestorSpaceIDs(of: id, in: visibleSpaces))
        if !ancestors.isDisjoint(with: collapsedSpaces) {
            collapsedSpaces.subtract(ancestors)
        }
    }

    /// The sidebar row a selection change should scroll into view: the
    /// selected local agent's row, or its space's header row when the space
    /// is collapsed (the agent has no row then). Nil when nothing local is
    /// on screen to reveal — a shell or remote agent owns the workspace, or
    /// the space has no visible row (hidden, or under a collapsed parent).
    /// Pure, separated for tests.
    static func sidebarRevealTarget(
        selectedAgentID: AgentID?,
        selectedSpaceID: SpaceID?,
        shellSelected: Bool,
        remoteSelected: Bool,
        spaces: [Space],
        collapsed: Set<SpaceID>
    ) -> AnyHashable? {
        guard !shellSelected, !remoteSelected, let spaceID = selectedSpaceID else { return nil }
        let visible = visibleSpaceForest(spaces.filter { !$0.hidden }, collapsed: collapsed)
        guard visible.contains(where: { $0.space.id == spaceID }) else { return nil }
        if let selectedAgentID, !collapsed.contains(spaceID) { return AnyHashable(selectedAgentID) }
        return AnyHashable(spaceID)
    }

    /// Scroll id of the row the sidebar should reveal for the current
    /// selection; the sidebar scrolls to it on every `sidebarRevealRequest`
    /// bump, which is what makes ⌘1–9, ⌘↑/↓ and ⌃⇧digits reveal a row that
    /// scrolled off. A remote selection targets its row in the unified tree
    /// (`RemoteAgentRef` is its own type, so it can never collide with a
    /// local agent or space id).
    var sidebarRevealTarget: AnyHashable? {
        if let remote = selectedRemoteAgent { return AnyHashable(remote) }
        return Self.sidebarRevealTarget(
            selectedAgentID: selectedAgentID,
            selectedSpaceID: selectedSpaceID,
            shellSelected: selectedShellID != nil,
            remoteSelected: selectedRemoteAgent != nil,
            spaces: state.spaces,
            collapsed: collapsedSpaces
        )
    }

    /// A REMOTE row shows that agent's terminal, streamed from its host.
    func selectRemoteAgent(hostID: UUID, agentID: AgentID) {
        inspectingAgentID = nil
        selectedShellID = nil
        selectedRemoteAgent = RemoteAgentRef(hostID: hostID, agentID: agentID)
        lastRemoteAgentByHost[hostID] = agentID
        // Same rule as the local tree: a selected row must not stay hidden
        // behind a closed host or remote-space disclosure.
        collapsedHosts.remove(hostID)
        if let connection = remoteHosts.connections.first(where: { $0.id == hostID }),
           let agent = connection.state.agents.first(where: { $0.id == agentID }),
           let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) {
            if isRemoteSpaceCollapsed(hostID: hostID, spaceID: agent.spaceID) {
                toggleRemoteSpaceCollapsed(hostID: hostID, spaceID: agent.spaceID)
            }
            remoteFocusedPaneID = agent.paneID ?? tab.layout.firstLeaf.id
        } else {
            remoteFocusedPaneID = nil
        }
        sidebarRevealRequest += 1
    }

    // MARK: Machine jumps (⌃⇧1…⌃⇧9)

    /// Machines in sidebar order: local first, then hosts in configured
    /// order. ⌃⇧1 is always local; ⌃⇧2… map to hosts. Drives the chords and
    /// the header keycaps, so the two can never disagree.
    var machineJumpTargets: [UUID?] {
        [nil] + remoteHosts.connections.map { $0.id }
    }

    /// ⌃⇧digit: jump to a machine — local restores the previous local
    /// selection; a host restores its last-selected agent (or the first).
    func jumpToMachine(_ digit: Int) {
        let targets = machineJumpTargets
        guard targets.indices.contains(digit - 1) else { return }
        guard let hostID = targets[digit - 1] else {
            // Local: leave remote, back to the last local selection.
            selectedRemoteAgent = nil
            if selectedAgentID == nil {
                selectedAgentID = state.agents.first { $0.spaceID == selectedSpaceID }?.id
            }
            revealLocalSpace(selectedSpaceID)
            syncFocus()
            return
        }
        guard let connection = remoteHosts.connections.first(where: { $0.id == hostID }),
              connection.phase == .connected else { return }
        let agents = connection.state.agents
        let target = lastRemoteAgentByHost[hostID].flatMap { last in
            agents.first { $0.id == last }?.id
        } ?? agents.first?.id
        guard let target else {
            // No agents on the host yet: at least uncollapse it so the jump
            // visibly lands somewhere.
            collapsedHosts.remove(hostID)
            return
        }
        collapsedHosts.remove(hostID)
        selectRemoteAgent(hostID: hostID, agentID: target)
    }

    /// "⌃⇧2"-style hover hint for a machine root; nil past the digit range.
    func machineKeycap(forHost hostID: UUID?) -> String? {
        machineJumpTargets.firstIndex(where: { $0 == hostID })
            .flatMap { $0 < 9 ? "⌃⇧\($0 + 1)" : nil }
    }

    func toggleHostCollapsed(_ id: UUID) {
        if collapsedHosts.contains(id) {
            collapsedHosts.remove(id)
        } else {
            collapsedHosts.insert(id)
        }
    }

    /// Sheet-facing wrappers for remote creation; selection follows the new
    /// agent so the sheet closes onto its terminal, mirroring local creation.
    func addRemoteSpace(hostID: UUID, path: String) async throws -> SpaceID {
        try await remoteHosts.addSpace(hostID: hostID, path: path)
    }

    func createRemoteAgent(
        hostID: UUID,
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?
    ) async throws {
        let agentID = try await remoteHosts.createAgent(
            hostID: hostID,
            spaceID: spaceID,
            cwd: cwd,
            model: model,
            thinking: thinking,
            initialPrompt: initialPrompt
        )
        selectRemoteAgent(hostID: hostID, agentID: agentID)
    }

    /// A space header toggles its disclosure in the sidebar tree.
    func toggleSpaceCollapsed(_ id: SpaceID) {
        if collapsedSpaces.contains(id) {
            collapsedSpaces.remove(id)
        } else {
            collapsedSpaces.insert(id)
        }
    }

    /// Sidebar display order (spaces, then their agents; collapsed spaces
    /// hidden) — drives ⌘1–9 and the badges, so the shortcuts always match
    /// what is on screen.
    var orderedAgents: [Agent] {
        refreshedSidebarDerivations().ordered
    }

    func shortcutBadge(for id: AgentID) -> Int? {
        guard showAgentShortcutBadges else { return nil }
        return refreshedSidebarDerivations().badges[id]
    }

    /// ⌘↑/↓: move through agents in visible sidebar order, wrapping at the ends.
    func selectAdjacentAgent(_ delta: Int) {
        let agents = orderedAgents
        guard !agents.isEmpty else { return }
        let current = agents.firstIndex { $0.id == selectedAgentID }
            ?? (delta > 0 ? agents.count - 1 : 0)
        selectAgent(agents[(current + delta + agents.count) % agents.count].id)
    }

    func layout(forTab id: TabID) -> PaneNode? {
        state.tabs.first { $0.id == id }?.layout
    }

    /// ⌥⌘←/→: move pane focus through the active tab's leaves in order.
    func focusAdjacentPane(_ delta: Int) {
        if let remote = selectedRemoteAgent,
           let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }),
           let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
           let layout = connection.state.tabs.first(where: { $0.id == agent.tabID })?.layout {
            let leaves = layout.leaves
            guard leaves.count > 1 else { return }
            let currentIndex = leaves.firstIndex { $0.id == remoteFocusedPaneID } ?? 0
            remoteFocusedPaneID = leaves[(currentIndex + delta + leaves.count) % leaves.count].id
            return
        }
        guard let layout = activeTab?.layout else { return }
        let leaves = layout.leaves
        guard leaves.count > 1 else { return }
        let currentIndex = leaves.firstIndex { $0.id == focusedPaneID } ?? 0
        let next = (currentIndex + delta + leaves.count) % leaves.count
        focusedPaneID = leaves[next].id
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
