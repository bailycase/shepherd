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

/// Where an agent layout's panes go on the Mac: the thread on top, and under it the terminal
/// panel (its tab strip, then the selected tab's panes with their own splits). Every pane gets a
/// rect whether it shows or not, so a hidden tab's terminal keeps its grid (no resize, no replay)
/// and comes back instantly. Pure, so it is unit-tested (`TerminalPanelLayoutTests`).
struct TerminalPanelGeometry: Equatable {
    struct Leaf: Equatable {
        let pane: LeafPane
        let rect: CGRect
        /// On screen: the thread unless the panel is maximized, the selected tab's panes while
        /// the panel shows.
        let shown: Bool
        /// The pane's header over its terminal, in a tab of more than one pane (TerminalPane).
        var header: CGRect? = nil
    }

    let thread: CGRect
    /// The thread folded to one line over the maximized panel (TerminalStates).
    var fold: CGRect? = nil
    let leaves: [Leaf]
    /// The selected tab's inner dividers, in the layout's coordinates.
    let separators: [PaneTreeGeometry.Separator]
    /// The tab strip and the panes' area; nil while the panel is hidden.
    let tabBar: CGRect?
    let content: CGRect?
    let tabs: [TerminalPanelTab]
    let selected: TerminalPanelTab?

    static func == (a: TerminalPanelGeometry, b: TerminalPanelGeometry) -> Bool {
        a.thread == b.thread && a.fold == b.fold && a.leaves == b.leaves && a.tabBar == b.tabBar && a.content == b.content
            && a.tabs == b.tabs && a.selected == b.selected && a.separators.map(\.rect) == b.separators.map(\.rect)
    }
}

func terminalPanelGeometry(
    for layout: PaneNode,
    thread: PaneID,
    selected: TerminalPanelTab?,
    shown: Bool,
    maximized: Bool,
    height preferred: CGFloat,
    in size: CGSize,
    liveRatios: [PaneSplitPath: Double] = [:]
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
    // Hidden, the panes keep the place they would have: their grids never change on a toggle.
    let panelTop = shown && maximized ? foldHeight : max(0, total - height)
    let panelHeight = shown && maximized ? total - foldHeight : min(height, total)
    let content = CGRect(x: 0, y: panelTop + barHeight, width: width, height: max(0, panelHeight - barHeight))

    var leaves: [TerminalPanelGeometry.Leaf] = []
    var separators: [PaneTreeGeometry.Separator] = []
    if let pane = layout.leaf(withID: thread) {
        leaves.append(.init(pane: pane, rect: threadRect, shown: !(shown && maximized)))
    }
    for tab in tabs {
        let isSelected = tab.id == selected?.id
        let geometry = paneTreeGeometry(for: tab.node, in: content.size, liveRatios: isSelected ? liveRatios : [:])
        // Several panes: each takes a header over its terminal, so the tab's panes tell apart.
        let headed = geometry.leaves.count > 1
        for leaf in geometry.leaves {
            let rect = leaf.rect.offsetBy(dx: content.minX, dy: content.minY)
            if headed {
                let header = min(NWTerminalMetrics.paneHeaderHeight, rect.height)
                leaves.append(.init(pane: leaf.pane,
                                    rect: CGRect(x: rect.minX, y: rect.minY + header, width: rect.width, height: rect.height - header),
                                    shown: shown && isSelected,
                                    header: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: header)))
            } else {
                leaves.append(.init(pane: leaf.pane, rect: rect, shown: shown && isSelected))
            }
        }
        if isSelected && shown {
            separators += geometry.separators.map {
                .init(id: $0.id, node: $0.node, axis: $0.axis,
                      rect: $0.rect.offsetBy(dx: content.minX, dy: content.minY),
                      containerRect: $0.containerRect.offsetBy(dx: content.minX, dy: content.minY))
            }
        }
    }
    return TerminalPanelGeometry(
        thread: threadRect, fold: foldHeight > 0 ? CGRect(x: 0, y: 0, width: width, height: foldHeight) : nil,
        leaves: leaves, separators: separators,
        tabBar: shown ? CGRect(x: 0, y: panelTop, width: width, height: barHeight) : nil,
        content: shown ? content : nil, tabs: tabs, selected: selected
    )
}
