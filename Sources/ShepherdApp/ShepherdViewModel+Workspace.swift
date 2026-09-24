import Foundation
import AppKit
import ShepherdCore
import ShepherdSessions

extension ShepherdViewModel {
    /// The workspace follows the sidebar: selected agent → its layout;
    /// otherwise the space's main (first) layout.
    var activeTab: Tab? { workspaceSelection.activeTab }

    /// Which layouts the workspace mounts, and which one shows.
    private var workspaceSelection: WorkspaceSelection {
        WorkspaceSelection(
            state: state,
            selectedSpaceID: selectedSpaceID,
            selectedAgentID: selectedAgentID,
            remoteSelectionActive: selectedRemoteAgent != nil,
            parkedTabIDs: parkedTabIDs,
            pendingMountTabIDs: pendingMountTabIDs
        )
    }

    // MARK: Mounting at launch

    /// Layouts mounted per run-loop turn once the first frame is up.
    static let mountBatch = 2

    /// The first workspace with agents mounts its visible layout first: every other layout
    /// waits (`pendingMountTabIDs`) for `drainPendingMounts`.
    func planMounting() {
        guard !mountingPlanned, !state.agents.isEmpty else { return }
        mountingPlanned = true
        let pending = Set(state.tabs.map(\.id)).subtracting([activeTabID].compactMap { $0 })
        if pending != pendingMountTabIDs { pendingMountTabIDs = pending }
    }

    /// Mounts the next few pending layouts, the visible space's first. False once none are left.
    @discardableResult
    func mountNextPending() -> Bool {
        let next = workspaceSelection.mountOrder.prefix(Self.mountBatch)
        guard !next.isEmpty else {
            if !pendingMountTabIDs.isEmpty { pendingMountTabIDs = [] }
            return false
        }
        pendingMountTabIDs.subtract(next)
        return !pendingMountTabIDs.isEmpty
    }

    /// Run by the workspace after its first frame: mounts the pending layouts a few at a time,
    /// letting the run loop draw between batches, so no turn builds many layouts at once.
    func drainPendingMounts() async {
        repeat {
            // Past the turn that drew the last frame (the first frame, first).
            try? await Task.sleep(for: .milliseconds(1))
        } while !Task.isCancelled && mountNextPending()
    }

    /// Cold parking bookkeeping, driven from `noteActiveTabVisited` so every
    /// selection path is covered: the newly visible layout is unparked and
    /// forgotten as hidden; every other mounted layout that has no hidden
    /// timestamp yet gets one now.
    private func noteActiveTabForParking() {
        let active = activeTabID
        if let active {
            parkedTabIDs.remove(active)
            // Shown before its turn to mount: it stays mounted from now on.
            if pendingMountTabIDs.contains(active) { pendingMountTabIDs.remove(active) }
            tabHiddenSince.removeValue(forKey: active)
        }
        let liveTabIDs = Set(state.tabs.map(\.id))
        for tab in mountedTabs where tab.id != active && tabHiddenSince[tab.id] == nil {
            tabHiddenSince[tab.id] = Date()
        }
        tabHiddenSince = tabHiddenSince.filter { liveTabIDs.contains($0.key) }
        parkedTabIDs = parkedTabIDs.filter { liveTabIDs.contains($0) }
        syncParkSweepTimer()
    }

    /// Park layouts that have been hidden past the delay. Runs only while
    /// a layout that can park (one holding a terminal pane) is hidden and
    /// unparked, so a workspace of thread-only agents pays nothing.
    private func syncParkSweepTimer() {
        let terminalTabs = WorkspaceSelection.terminalTabs(in: state)
        let pending = tabHiddenSince.keys.contains { !parkedTabIDs.contains($0) && terminalTabs.contains($0) }
        guard pending else {
            parkSweepTimer?.invalidate()
            parkSweepTimer = nil
            return
        }
        guard parkSweepTimer == nil else { return }
        parkSweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepColdPanes() }
        }
    }

    func sweepColdPanes(now: Date = Date()) {
        let candidates = WorkspaceSelection.coldParkCandidates(
            hiddenSince: tabHiddenSince, activeTabID: activeTabID, terminalTabs: WorkspaceSelection.terminalTabs(in: state), now: now
        ).subtracting(parkedTabIDs)
        guard !candidates.isEmpty else {
            syncParkSweepTimer()
            return
        }
        for tab in state.tabs where candidates.contains(tab.id) {
            for leaf in tab.layout.leaves { sessions.parkPane(leaf.id) }
        }
        parkedTabIDs.formUnion(candidates)
        syncParkSweepTimer()
    }

    /// Called by the workspace view on every active-tab change, which covers all selection
    /// paths: keeps cold-parking bookkeeping current.
    func noteActiveTabVisited() {
        noteActiveTabForParking()
    }

    /// Every layout the workspace keeps mounted (see `WorkspaceSelection`).
    var mountedTabs: [Tab] { workspaceSelection.mountedTabs }

    /// The visible layout's id, without copying a `Tab`.
    var activeTabID: TabID? { workspaceSelection.activeTabID }

    /// The one mounted layout the user actually sees.
    func isVisibleTab(_ tab: Tab) -> Bool { workspaceSelection.isVisible(tab) }

    // MARK: Persistence plumbing

    /// Append one workspace write to the serialized server-mutation tail.
    /// Local state may lead briefly for responsive UI, but a failed write
    /// always restores both mirrors from the server's committed snapshot.
    func enqueuePersistence(
        _ description: String,
        operation: @escaping @Sendable (SessionServer) async throws -> Void
    ) {
        let previous = persistenceTail
        persistenceTail = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self else { return }
            do {
                try await operation(self.server)
            } catch {
                // Silent by design: a failed background write self-heals via
                // reconcile, and audible feedback here beeps from test runs
                // and post-hoc races (e.g. removing an already-removed tab).
                NSLog("Shepherd: \(description) failed: \(error)")
                self.reconcileFromServer()
            }
        }
    }

    /// Reconcile optimistic UI state after a queued persistence failure.
    private func reconcileFromServer() {
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
    }

    // MARK: Panes

    func splitFocusedPane(axis: SplitAxis) {
        if let remote = selectedRemoteAgent {
            if remoteInspectingAgent == remote, let tab = remoteVisibleTab(remote) {
                controlRemoteInspector(remote, action: .split(paneID: remoteFocusedPaneID ?? tab.layout.firstLeaf.id, axis: axis))
                return
            }
            if remoteReviews[remote]?.paneID == remoteFocusedPaneID { NSSound.beep(); return }
        }
        if let remote = selectedRemoteAgent,
           let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }),
           let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
           let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) {
            let anchor = remoteFocusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil }
                ?? agent.paneID ?? tab.layout.firstLeaf.id
            Task {
                do {
                    remoteFocusedPaneID = try await remoteHosts.openPane(
                        hostID: remote.hostID,
                        agentID: remote.agentID,
                        relativeTo: anchor,
                        axis: axis
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        guard let tab = activeTab else { NSSound.beep(); return }
        let focus = focusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? tab.layout.firstLeaf.id
        guard let leaf = tab.layout.leaf(withID: focus) else { return }
        do { try verifyCheckoutAvailable(leaf.cwd) }
        catch { remoteActionError = String(describing: error); return }
        let newPane = LeafPane(cwd: leaf.cwd)
        guard let newLayout = tab.layout.splitting(pane: focus, axis: axis, newPane: newPane) else { return }
        setLayout(newLayout, forTab: tab.id)
        focusedPaneID = newPane.id
    }

    /// Split a terminal pane off the agent's thread and type `command` into its fresh shell
    /// (visible and cancelable, not a hidden exec).
    func openTerminalPane(besideAgent agent: Agent, running command: String) {
        guard let tab = state.tabs.first(where: { $0.id == agent.tabID }) else { return }
        let anchor = agent.paneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? tab.layout.firstLeaf.id
        guard let leaf = tab.layout.leaf(withID: anchor) else { return }
        let pane = LeafPane(cwd: leaf.cwd)
        guard let layout = tab.layout.splitting(pane: anchor, axis: .vertical, newPane: pane) else { return }
        setLayout(layout, forTab: tab.id)
        focusedPaneID = pane.id
        Task {
            guard let session = await sessions.awaitSession(forPane: pane.id, timeout: .seconds(10)) else { return }
            server.write(sessionID: session, data: Data((command + "\n").utf8))
        }
    }

    func closeFocusedPane() {
        if let remote = selectedRemoteAgent {
            if remoteInspectingAgent == remote, let tab = remoteVisibleTab(remote) {
                controlRemoteInspector(remote, action: .close(paneID: remoteFocusedPaneID ?? tab.layout.firstLeaf.id))
                return
            }
            if let review = remoteReviews[remote], remoteFocusedPaneID == review.paneID { cancelReview(review); return }
            guard let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
                  let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) else {
                NSSound.beep()
                return
            }
            let focus = remoteFocusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil }
                ?? agent.paneID ?? tab.layout.firstLeaf.id
            guard tab.layout.leaf(withID: focus)?.agentID == nil else {
                NSSound.beep()
                return
            }
            Task {
                do {
                    try await remoteHosts.closePane(
                        hostID: remote.hostID,
                        agentID: remote.agentID,
                        paneID: focus
                    )
                    remoteFocusedPaneID = agent.paneID ?? tab.layout.firstLeaf.id
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        guard let tab = activeTab else { NSSound.beep(); return }
        let focus = focusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? tab.layout.firstLeaf.id
        // The pane running an agent's own pi process is the thread; ⌘W
        // never closes it (⌘⇧W deletes the agent). Closing it would strand
        // a running pi with no pane to come back to.
        if tab.layout.leaf(withID: focus)?.agentID != nil {
            NSSound.beep()
            return
        }
        if !closeLocalPane(focus) {
            // A layout always keeps its last pane.
            NSSound.beep()
        }
    }

    /// Close a local leaf using the same layout mutation as ⌘W. Review panes
    /// have no terminal session, but using this path keeps their persisted
    /// split and focus behavior identical to ordinary panes.
    @discardableResult
    func closeLocalPane(_ paneID: PaneID) -> Bool {
        guard let tabIndex = state.tabs.firstIndex(where: { $0.layout.contains(paneID) }),
              let pane = state.tabs[tabIndex].layout.leaf(withID: paneID),
              pane.agentID == nil,
              let newLayout = state.tabs[tabIndex].layout.closing(pane: paneID) else {
            return false
        }
        let tabID = state.tabs[tabIndex].id
        sessions.detachPane(paneID)
        setLayout(newLayout, forTab: tabID)
        discardReviewSession(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = newLayout.firstLeaf.id
        }
        return true
    }

    func commitSplitRatio(tabID: TabID, split: PaneNode, ratio: Double) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else { return }
        setLayout(tab.layout.replacingSplit(split, withRatio: ratio), forTab: tabID)
    }

    func commitRemoteSplitRatio(ref: RemoteAgentRef, split: PaneNode, ratio: Double) {
        if remoteInspectingAgent == ref {
            controlRemoteInspector(ref, action: .resize(split: split, ratio: ratio))
            return
        }
        Task {
            try? await remoteHosts.resizePaneSplit(
                hostID: ref.hostID,
                agentID: ref.agentID,
                split: split,
                ratio: ratio
            )
        }
    }

    func setLayout(_ layout: PaneNode, forTab id: TabID) {
        guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs[index].layout = layout
        sessions.stateDidChange(state)
        enqueuePersistence("layout update") { try await $0.updateLayoutStructure(tabID: id, layout: layout) }
    }

    // MARK: Session lifecycle

    /// A process ended: its pane closes. An agent whose process ended is
    /// retired with its whole layout (auxiliary shells die too; the pi
    /// transcript stays on disk). A space's last shell respawns fresh so the
    /// space keeps a workspace.
    func handleSessionExited(paneID: PaneID) {
        guard let tabIndex = state.tabs.firstIndex(where: { $0.layout.contains(paneID) }) else { return }
        let tab = state.tabs[tabIndex]
        let exitedAgentID = tab.layout.leaf(withID: paneID)?.agentID

        if let agentID = exitedAgentID {
            cancelReviews(for: agentID)
            childRuns.clear(agent: agentID)
            state.agents.removeAll { $0.id == agentID }
            if selectedAgentID == agentID {
                selectPreviousAgent(after: agentID)
            } else {
                selectionHistory.removeAll { $0 == agentID }
            }
            for leaf in tab.layout.leaves {
                sessions.detachPane(leaf.id)
            }
            state.tabs.remove(at: tabIndex)
            sessions.stateDidChange(state)
            enqueuePersistence("agent exit cleanup") { try await $0.deleteAgent(agentID) }
        } else if let newLayout = tab.layout.closing(pane: paneID) {
            state.tabs[tabIndex].layout = newLayout
            sessions.stateDidChange(state)
            let tabID = tab.id
            enqueuePersistence("pane exit cleanup") { try await $0.updateLayoutStructure(tabID: tabID, layout: newLayout) }
        } else {
            let fresh = PaneNode.leaf(LeafPane(cwd: tab.layout.firstLeaf.cwd))
            state.tabs[tabIndex].layout = fresh
            sessions.stateDidChange(state)
            let tabID = tab.id
            enqueuePersistence("shell exit cleanup") { try await $0.updateLayoutStructure(tabID: tabID, layout: fresh) }
        }
        syncFocus()
    }

    // MARK: Agents

    func renameSelectedAgent() {
        if let remote = selectedRemoteAgent {
            remoteRenameTarget = remote
            return
        }
        guard let id = selectedAgentID else { return }
        agentRenameTarget = id
    }

    func deleteSelectedAgent() {
        if let remote = selectedRemoteAgent {
            requestRemoteDelete(remote)
            return
        }
        guard let agent = selectedAgent else { return }
        if agent.worktreeBranch != nil { worktreeDeleteTarget = agent.id }
        else { deleteAgent(agent.id) }
    }

    /// A hand-typed name is final: pi's namer must never overwrite it.
    func renameAgent(_ id: AgentID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let agent = state.agents.first(where: { $0.id == id }),
              agent.name != trimmed else { return }
        enqueuePersistence("agent rename") { try await $0.renameAgent(id, to: trimmed) }
    }

    /// Persist retirement and wait for the actual process exits before removing a checkout.
    func deleteWorktreeAgent(_ id: AgentID, removeWorktree: Bool) {
        guard removeWorktree else { deleteAgent(id); return }
        guard let agent = state.agents.first(where: { $0.id == id }),
              let branch = agent.worktreeBranch,
              let repo = state.spaces.first(where: { $0.id == agent.spaceID })?.path else { return }
        let path = agent.worktreePath ?? GitWorktree.destination(repo: repo, branch: branch)
        let sessionIDs = state.tabs.filter { $0.id == agent.tabID }
            .flatMap { $0.layout.leaves.compactMap(\.sessionID) }
        Task {
            do {
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
                try verifyCheckoutAvailable(canonical)
                try verifyCheckoutUnused(canonical, except: id)
                hostBusyWorktrees.insert(canonical)
                defer { hostBusyWorktrees.remove(canonical) }
                let fingerprint = try await Task.detached { try GitWorktree.deletionFingerprint(worktree: path) }.value
                try await deleteAgentPersisted(id, worktreeOperation: true)
                let deadline = ContinuousClock.now + .seconds(10)
                for sessionID in sessionIDs {
                    while await server.sessionInfo(sessionID: sessionID)?.isAlive == true {
                        guard ContinuousClock.now < deadline else { throw GitWorktree.Failure(message: "Agent processes have not stopped. Checkout was kept.") }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                try verifyCheckoutUnused(canonical, except: id)
                try await Task.detached { try GitWorktree.remove(repo: repo, branch: branch, worktree: path, fingerprint: fingerprint) }.value
            } catch { remoteActionError = String(describing: error) }
        }
    }

    /// `completion` hears the outcome once the deletion is persisted (a peer's `agent_delete`
    /// waits on it).
    func deleteAgent(_ id: AgentID, completion: (@MainActor (Error?) -> Void)? = nil) {
        enqueuePersistence("agent deletion") { [weak self] _ in
            guard let self else { return }
            do {
                try await self.deleteAgentPersisted(id)
                await MainActor.run { completion?(nil) }
            } catch {
                await MainActor.run {
                    self.remoteActionError = String(describing: error)
                    completion?(error)
                }
                throw error
            }
        }
    }

    func deleteAgentPersisted(_ id: AgentID, worktreeOperation: Bool = false) async throws {
        if !worktreeOperation, let agent = state.agents.first(where: { $0.id == id }),
           let branch = agent.worktreeBranch,
           let repo = state.spaces.first(where: { $0.id == agent.spaceID })?.path {
            let path = URL(fileURLWithPath: agent.worktreePath ?? GitWorktree.destination(repo: repo, branch: branch))
                .resolvingSymlinksInPath().standardized.path
            guard !hostBusyWorktrees.contains(path) else { throw GitWorktree.Failure(message: "A worktree operation is running for this checkout") }
        }
        let doomedTabs = state.tabs.filter { tab in
            state.agents.contains { $0.id == id && $0.tabID == tab.id }
        }
        try await server.deleteAgent(id)
        for leaf in doomedTabs.flatMap({ $0.layout.leaves }) { sessions.detachPane(leaf.id) }
        cancelReviews(for: id)
        subagentInspector.runByAgent.removeValue(forKey: id)
        childRuns.clear(agent: id)
        if selectedAgentID == id { selectPreviousAgent(after: id) }
        else { selectionHistory.removeAll { $0 == id } }
        adopt(server.state)
        sessions.stateDidChange(state)
    }

}

extension PaneNode {
    /// Replace the ratio of the split structurally equal to `target`. Leaf IDs
    /// are unique, so at most one node matches.
    func replacingSplit(_ target: PaneNode, withRatio ratio: Double) -> PaneNode {
        if self == target, case .split(let axis, _, let first, let second) = self {
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
        switch self {
        case .leaf:
            return self
        case .split(let axis, let r, let first, let second):
            return .split(
                axis: axis,
                ratio: r,
                first: first.replacingSplit(target, withRatio: ratio),
                second: second.replacingSplit(target, withRatio: ratio)
            )
        }
    }
}
