import Foundation
import ShepherdCore

/// Which pane layouts the workspace mounts, and which single one is visible.
///
/// The workspace keeps every *mounted* layout (each agent's thread plus any terminal panes
/// beside it) in the view tree and toggles visibility, rather than swapping layouts in and
/// out of the view tree. Unmounting destroys the pane's Ghostty surface, so returning to an agent
/// has to rebuild it, wait for it to become ready, and replay the whole
/// screen — seconds of flash and reflow. Hidden layouts keep their surfaces,
/// their scrollback, and their process's real grid, and they stop rendering
/// (`setRenderingActive(false)` drives ghostty occlusion), so a mounted
/// hidden pane costs surface memory but no GPU time. Switching — within a
/// space or across spaces — is only ever a visibility flip, never a remount.
///
/// The exception is cold parking: a hidden pane still parses every byte in
/// Ghostty and holds its surface (~9 MB and up to 0.6 cores under flood,
/// see docs/benchmarks). Layouts holding a terminal pane, hidden longer than
/// `parkDelay` and outside the `hotRetainLimit` most recently visible ones,
/// unmount; their processes and the host-side screen keep running, so
/// returning re-mounts from a snapshot (single-digit ms) instead of a blank
/// surface. A layout that is only a thread never parks.
///
/// At launch the layouts mount in turn (`pendingMountTabIDs`): the visible
/// one in the first frame, the rest after it.
///
/// Pure value type so this (the part that is easy to get subtly wrong) is
/// testable without constructing a view model, which owns the session server.
struct WorkspaceSelection {
    let state: ShepherdState
    let selectedSpaceID: SpaceID?
    let selectedAgentID: AgentID?
    /// True while a remote agent is selected: no local layout is visible (the
    /// remote pane renders instead), but everything stays mounted.
    var remoteSelectionActive: Bool = false
    /// Layouts to keep unmounted (decided by `coldParkCandidates`, applied
    /// by the view model). Never contains the active tab.
    var parkedTabIDs: Set<TabID> = []
    /// Layouts not mounted yet at launch: the visible one mounts first, and the view model
    /// mounts the rest after its first frame, a few per run-loop turn (`mountOrder`).
    var pendingMountTabIDs: Set<TabID> = []

    /// Hidden this long before a layout is eligible to park. Long enough
    /// that flipping between two agents never parks either.
    static let parkDelay: Duration = .seconds(30)
    /// Most recently visible layouts that never park, however long hidden.
    static let hotRetainLimit = 4

    /// Layouts hidden since before `now - parkDelay` that are not among the
    /// `hotRetainLimit` most recently shown. `hiddenSince` holds the moment
    /// each layout stopped being the active one. Only layouts holding a terminal
    /// pane (`terminalTabs`) park: a thread-only layout has no surface to release and
    /// polls nothing while hidden, so it stays mounted and returning to it is a flip.
    static func coldParkCandidates(
        hiddenSince: [TabID: Date],
        activeTabID: TabID?,
        terminalTabs: Set<TabID>,
        now: Date = Date()
    ) -> Set<TabID> {
        let hot = hiddenSince
            .filter { $0.key != activeTabID }
            .sorted { $0.value > $1.value }
            .prefix(hotRetainLimit)
            .map(\.key)
        let cutoff = now.addingTimeInterval(-Double(parkDelay.components.seconds))
        return Set(hiddenSince.filter { id, since in
            id != activeTabID && since <= cutoff && !hot.contains(id) && terminalTabs.contains(id)
        }.map(\.key))
    }

    /// The layouts holding a terminal pane: any leaf but the agent's own thread.
    static func terminalTabs(in state: ShepherdState) -> Set<TabID> {
        Set(state.tabs.filter { tab in
            tab.layout.leaves.contains { primaryAgent(in: tab, pane: $0, agents: state.agents) == nil }
        }.map(\.id))
    }

    /// Layouts kept in the view tree, ordered stably by (space, tab order) —
    /// never by selection. Reordering would change the ForEach identity order
    /// and make SwiftUI rebuild the very views this exists to preserve;
    /// adding a space appends its tabs without disturbing earlier ones, and a
    /// layout mounting later lands in its place without moving the others.
    var mountedTabs: [Tab] {
        let active = activeTabID
        return Self.stable(state.tabs.filter { tab in
            tab.id == active || (!parkedTabIDs.contains(tab.id) && !pendingMountTabIDs.contains(tab.id))
        }, in: state)
    }

    /// The order the pending layouts mount in: the visible layout's space first, then the rest
    /// in their stable order.
    var mountOrder: [TabID] {
        let space = activeTab?.spaceID ?? selectedSpaceID
        let pending = Self.stable(state.tabs.filter { pendingMountTabIDs.contains($0.id) }, in: state)
        return (pending.filter { $0.spaceID == space } + pending.filter { $0.spaceID != space }).map(\.id)
    }

    private static func stable(_ tabs: [Tab], in state: ShepherdState) -> [Tab] {
        let spaceOrder = Dictionary(
            uniqueKeysWithValues: state.spaces.enumerated().map { ($0.element.id, $0.offset) }
        )
        return tabs.sorted { a, b in
            let sa = a.spaceID.flatMap { spaceOrder[$0] } ?? Int.max
            let sb = b.spaceID.flatMap { spaceOrder[$0] } ?? Int.max
            return sa == sb ? a.order < b.order : sa < sb
        }
    }

    /// The workspace follows the sidebar: the selected agent's layout, or nothing (an empty
    /// workspace) when no agent is selected.
    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return state.tabs.first { $0.id == id }
    }

    /// Just the id, without copying a `Tab` (each carries a whole layout
    /// tree). Visibility is checked per pane on every SwiftUI update, so this
    /// path stays allocation-free.
    var activeTabID: TabID? {
        if remoteSelectionActive { return nil }
        guard let id = selectedAgentID,
              let agent = state.agents.first(where: { $0.id == id }),
              agent.spaceID == selectedSpaceID,
              state.tabs.contains(where: { $0.id == agent.tabID }) else { return nil }
        return agent.tabID
    }

    func isVisible(_ tab: Tab) -> Bool {
        tab.id == activeTabID
    }
}
