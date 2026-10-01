import CoreGraphics
import ShepherdCore
import ShepherdRemote
import ShepherdUI

extension AppLayout {
    /// The terminal panel under the thread (TerminalSplit board) until its divider moves.
    static let terminalPanelHeight: CGFloat = NWTerminalMetrics.panelHeight
    static let terminalPanelMinHeight: CGFloat = NWTerminalMetrics.minimumPanelHeight
    /// The thread keeps at least this above the panel.
    static let terminalThreadMinHeight: CGFloat = NWTerminalMetrics.minimumThreadHeight
    /// How near a third, a half or two-thirds of the layout the divider snaps.
    static let terminalSnapTolerance: CGFloat = NWTerminalMetrics.snapTolerance
    /// The panel's top edge while it is dragged: a lantern line this thick (TerminalStates).
    static let terminalDividerDragLine: CGFloat = 3
    /// How often an on-screen panel asks what its terminals run.
    static let terminalActivityInterval: Duration = .seconds(2)
}

/// Where an agent layout's leaves go on the Mac: the thread on top, and under it the terminal
/// panel (its tab strip, then the selected tab's terminal). Every leaf gets a rect whether it
/// shows or not, so a hidden tab's terminal keeps its grid (no resize, no replay) and comes back
/// instantly. Pure, so it is unit-tested (`TerminalPanelLayoutTests`).
struct TerminalPanelGeometry: Equatable {
    struct Leaf: Equatable {
        let pane: LeafPane
        let rect: CGRect
        /// On screen: the thread unless the panel is maximized, the selected tab's terminal
        /// while the panel shows.
        let shown: Bool
    }

    let thread: CGRect
    /// The thread folded to one line over the maximized panel (TerminalStates).
    var fold: CGRect? = nil
    let leaves: [Leaf]
    /// The tab strip and the terminals' area; nil while the panel is hidden.
    let tabBar: CGRect?
    let content: CGRect?
    let tabs: [TerminalPanelTab]
    let selected: TerminalPanelTab?
}

func terminalPanelGeometry(
    for layout: PaneNode,
    thread: PaneID,
    selected: TerminalPanelTab?,
    shown: Bool,
    maximized: Bool,
    height preferred: CGFloat,
    in size: CGSize
) -> TerminalPanelGeometry {
    let width = max(0, size.width)
    let total = max(0, size.height)
    let tabs = TerminalPanel.tabs(in: layout, thread: thread)
    let height = CGFloat(TerminalPanelHeight.clamp(Double(preferred), container: Double(total),
                                                   minimum: Double(AppLayout.terminalPanelMinHeight),
                                                   threadMinimum: Double(AppLayout.terminalThreadMinHeight)))
    // Maximized, the thread keeps its size under the panel (folded away, not relaid out).
    let threadRect = CGRect(x: 0, y: 0, width: width, height: max(0, total - (shown ? height : 0)))
    let barHeight = min(NWTerminalMetrics.tabBarHeight, total)
    // Maximized, the thread folds to one line above the strip.
    let foldHeight = shown && maximized ? min(NWTerminalMetrics.foldedThreadHeight, max(0, total - barHeight)) : 0
    // Hidden, the terminals keep the place they would have: their grids never change on a toggle.
    let panelTop = shown && maximized ? foldHeight : max(0, total - height)
    let panelHeight = shown && maximized ? total - foldHeight : min(height, total)
    let content = CGRect(x: 0, y: panelTop + barHeight, width: width, height: max(0, panelHeight - barHeight))

    var leaves: [TerminalPanelGeometry.Leaf] = []
    if let pane = layout.leaf(withID: thread) {
        leaves.append(.init(pane: pane, rect: threadRect, shown: !(shown && maximized)))
    }
    for tab in tabs {
        leaves.append(.init(pane: tab.leaf, rect: content, shown: shown && tab.id == selected?.id))
    }
    return TerminalPanelGeometry(
        thread: threadRect, fold: foldHeight > 0 ? CGRect(x: 0, y: 0, width: width, height: foldHeight) : nil,
        leaves: leaves,
        tabBar: shown ? CGRect(x: 0, y: panelTop, width: width, height: barHeight) : nil,
        content: shown ? content : nil, tabs: tabs, selected: selected
    )
}
