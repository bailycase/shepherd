import Foundation
import ShepherdCore

/// Which pane layouts the workspace mounts, and which single one is visible.
///
/// The workspace keeps every *mounted* layout in the view tree and toggles
/// visibility, rather than swapping layouts in and out of the view tree.
/// Agent layouts, global shells, and inspector tabs are always mounted —
/// their processes must run (or were created on demand). A space's shell
/// workspace mounts on first visit: mounting spawns a login shell and a
/// Ghostty surface, and a large space tree must not pay that for spaces
/// never opened. Once mounted, a layout stays mounted for the app's run.
/// Unmounting destroys the pane's Ghostty surface, so returning to an agent
/// has to rebuild it, wait for it to become ready, and replay the whole
/// screen — seconds of flash and reflow. Hidden layouts keep their surfaces,
/// their scrollback, and their process's real grid, and they stop rendering
/// (`setRenderingActive(false)` drives ghostty occlusion), so a mounted
/// hidden pane costs surface memory but no GPU time. Switching — within a
/// space or across spaces — is only ever a visibility flip, never a remount.
///
/// Pure value type so this (the part that is easy to get subtly wrong) is
/// testable without constructing a view model, which owns the session server.
struct WorkspaceSelection {
    let state: ShepherdState
    let selectedSpaceID: SpaceID?
    let selectedAgentID: AgentID?
    /// When set (a subagent row is selected), the agent's inspector tab is
    /// the visible layout instead of the agent's own.
    var inspectingAgentID: AgentID? = nil
    /// When set (a SHELLS row is selected), that global shell is the visible
    /// layout; it wins over space/agent selection.
    var selectedShellID: TabID? = nil
    /// True while a remote agent is selected: no local layout is visible (the
    /// remote pane renders instead), but everything stays mounted.
    var remoteSelectionActive: Bool = false
    /// Space shell tabs shown at least once this run. Grows only (the view
    /// model records every active tab): a mounted layout must never unmount
    /// while it exists, or switching back would destroy and replay its
    /// surface.
    var visitedTabIDs: Set<TabID> = []

    /// Layouts kept in the view tree, ordered stably by (space, tab order) —
    /// never by selection. Reordering would change the ForEach identity order
    /// and make SwiftUI rebuild the very views this exists to preserve;
    /// adding a space appends its tabs without disturbing earlier ones.
    var mountedTabs: [Tab] {
        let spaceOrder = Dictionary(
            uniqueKeysWithValues: state.spaces.enumerated().map { ($0.element.id, $0.offset) }
        )
        let agentTabIDs = Set(state.agents.map(\.tabID))
        let active = activeTabID
        // Global shells sort after every space, in their own order.
        return state.tabs.filter { tab in
            // Only space shell (space-main) tabs mount lazily; see the type
            // comment. The active tab is always mounted so a first visit
            // renders immediately — the view model marks it visited so it
            // stays mounted after selection moves on.
            let isSpaceShell = tab.spaceID != nil
                && tab.inspectorFor == nil
                && !agentTabIDs.contains(tab.id)
            return !isSpaceShell || tab.id == active || visitedTabIDs.contains(tab.id)
        }.sorted { a, b in
            let sa = a.spaceID.flatMap { spaceOrder[$0] } ?? Int.max
            let sb = b.spaceID.flatMap { spaceOrder[$0] } ?? Int.max
            return sa == sb ? a.order < b.order : sa < sb
        }
    }

    /// The workspace follows the sidebar: selected agent → its layout;
    /// otherwise the space's main (first) layout.
    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return state.tabs.first { $0.id == id }
    }

    /// Just the id, without copying a `Tab` (each carries a whole layout
    /// tree). Visibility is checked per pane on every SwiftUI update, so this
    /// path stays allocation-free.
    var activeTabID: TabID? {
        if remoteSelectionActive { return nil }
        if let shellID = selectedShellID,
           state.tabs.contains(where: { $0.id == shellID && $0.isShell }) {
            return shellID
        }
        if let inspecting = inspectingAgentID,
           let tab = state.tabs.first(where: { $0.inspectorFor == inspecting }) {
            return tab.id
        }
        if let id = selectedAgentID,
           let agent = state.agents.first(where: { $0.id == id }),
           agent.spaceID == selectedSpaceID,
           state.tabs.contains(where: { $0.id == agent.tabID }) {
            return agent.tabID
        }
        // The space's main layout: lowest order, without sorting a copy of
        // every tab in the space. Inspector layouts never stand in for a
        // space's shell workspace.
        return state.tabs
            .filter { $0.spaceID == selectedSpaceID && $0.inspectorFor == nil }
            .min { $0.order < $1.order }?
            .id
    }

    func isVisible(_ tab: Tab) -> Bool {
        tab.id == activeTabID
    }
}
