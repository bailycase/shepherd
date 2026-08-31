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
            inspectingAgentID: inspectingAgentID,
            selectedShellID: selectedShellID,
            remoteSelectionActive: selectedRemoteAgent != nil,
            visitedTabIDs: visitedSpaceShellTabs
        )
    }

    /// Record the currently visible layout so it stays mounted after
    /// selection moves on (space shell tabs mount lazily — see
    /// `WorkspaceSelection`). Called by the workspace view on every
    /// active-tab change, which covers all selection paths.
    func noteActiveTabVisited() {
        if let id = activeTabID { visitedSpaceShellTabs.insert(id) }
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
        let newPane = LeafPane(cwd: leaf.cwd)
        guard let newLayout = tab.layout.splitting(pane: focus, axis: axis, newPane: newPane) else { return }
        setLayout(newLayout, forTab: tab.id)
        focusedPaneID = newPane.id
    }

    func closeFocusedPane() {
        if let remote = selectedRemoteAgent,
           let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }),
           let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
           let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) {
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
        if let newLayout = tab.layout.closing(pane: focus) {
            sessions.detachPane(focus)
            setLayout(newLayout, forTab: tab.id)
            focusedPaneID = newLayout.firstLeaf.id
        } else if tab.isShell {
            // ⌘W on a shell's last pane closes the shell — that is what
            // closing "the shell" means; there is no process worth guarding.
            deleteShell(tab.id)
        } else {
            // A layout always keeps its last pane; exit the process instead.
            NSSound.beep()
        }
    }

    func commitSplitRatio(tabID: TabID, split: PaneNode, ratio: Double) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }) else { return }
        setLayout(tab.layout.replacingSplit(split, withRatio: ratio), forTab: tabID)
    }

    func commitRemoteSplitRatio(ref: RemoteAgentRef, split: PaneNode, ratio: Double) {
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

        if let inspected = tab.inspectorFor {
            // The inspector's shell ended (user exited it): the ephemeral
            // layout goes with it, and the workspace falls back to the
            // agent's terminal.
            sessions.detachPane(paneID)
            state.tabs.remove(at: tabIndex)
            if inspectingAgentID == inspected { inspectingAgentID = nil }
            inspectedChild.removeValue(forKey: inspected)
            sessions.stateDidChange(state)
            let tabID = tab.id
            enqueuePersistence("inspector exit cleanup") { try await $0.removeTab(tabID) }
            syncFocus()
            return
        }

        if let agentID = exitedAgentID {
            endAgentLaunch(agentID)
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

    /// A hand-typed name is final: pi's namer must never overwrite it.
    func renameAgent(_ id: AgentID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let agent = state.agents.first(where: { $0.id == id }),
              agent.name != trimmed else { return }
        enqueuePersistence("agent rename") { try await $0.renameAgent(id, to: trimmed) }
    }

    /// Confirmed Delete Worktree Agent: retire the agent, and optionally tear
    /// down the worktree checkout + branch that Shepherd created for it. The
    /// removal runs off-main after a short grace so the agent's processes
    /// (whose cwd is inside the worktree) are gone first.
    func deleteWorktreeAgent(_ id: AgentID, removeWorktree: Bool) {
        guard let agent = state.agents.first(where: { $0.id == id }) else { return }
        let branch = agent.worktreeBranch
        let repo = state.spaces.first { $0.id == agent.spaceID }?.path
        let worktree = agent.worktreePath
        deleteAgent(id)
        guard removeWorktree, let branch, let repo else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            do {
                try GitWorktree.remove(repo: repo, branch: branch, worktree: worktree)
            } catch {
                NSLog("Shepherd: worktree removal failed: \(error.localizedDescription)")
            }
        }
    }

    func deleteAgent(_ id: AgentID) {
        guard let agent = state.agents.first(where: { $0.id == id }),
              let tabIndex = state.tabs.firstIndex(where: { $0.id == agent.tabID }) else { return }
        let tab = state.tabs[tabIndex]

        // Detach every view first. The server mutation below owns process
        // termination, so exit callbacks cannot race a half-removed UI tree.
        for leaf in tab.layout.leaves {
            sessions.detachPane(leaf.id)
        }

        endAgentLaunch(id)
        childRuns.clear(agent: id)
        state.agents.removeAll { $0.id == id }
        state.tabs.remove(at: tabIndex)
        if selectedAgentID == id {
            selectPreviousAgent(after: id)
        } else {
            selectionHistory.removeAll { $0 == id }
        }
        sessions.stateDidChange(state)
        syncFocus()

        enqueuePersistence("agent deletion") { try await $0.deleteAgent(id) }
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
