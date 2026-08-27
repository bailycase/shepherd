import Foundation
import ShepherdCore

/// Remembers the pane last focused in each layout so returning to an agent
/// (⌘1–9, a sidebar click, ⌘⇧]) lands on the pane you were actually working
/// in — the side shell, say — instead of snapping back to the agent's pi pane
/// every time.
///
/// Entries are only ever *hints*: a remembered pane is used solely when it
/// still exists in the layout being entered, so splits, closed panes, and
/// restored state can never send focus somewhere stale.
struct PaneFocusMemory {
    private var panes: [TabID: PaneID] = [:]

    /// Record the pane focused in `tabID`.
    mutating func record(pane: PaneID, inTab tabID: TabID) {
        panes[tabID] = pane
    }

    /// Forget layouts that no longer exist (retired or deleted agents) so the
    /// map cannot grow without bound.
    mutating func prune(liveTabs: Set<TabID>) {
        panes = panes.filter { liveTabs.contains($0.key) }
    }

    func remembered(forTab tabID: TabID) -> PaneID? {
        panes[tabID]
    }

    /// The pane to focus when entering `layout`: the one last focused there if
    /// it is still present, else `fallback` (the agent's own pane), else the
    /// layout's first leaf.
    func focus(enteringTab tabID: TabID, layout: PaneNode, fallback: PaneID?) -> PaneID {
        if let remembered = panes[tabID], layout.contains(remembered) {
            return remembered
        }
        if let fallback, layout.contains(fallback) {
            return fallback
        }
        return layout.firstLeaf.id
    }
}
