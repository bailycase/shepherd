import CoreGraphics
import Testing
@testable import ShepherdRemote

/// The iPad split view's shape: the sidebar slides over the thread only in a window taller than
/// it is wide; the side pane docks by the Mac's rule.
@Suite("Pad split layout")
struct PadSplitLayoutTests {
    @Test(arguments: [
        (CGSize(width: 1032, height: 1376), true),  // 13-inch iPad, portrait
        (CGSize(width: 1376, height: 1032), false), // 13-inch iPad, landscape
        (CGSize(width: 507, height: 1032), true),   // half of a landscape iPad in Split View
        (CGSize(width: 1032, height: 1032), false), // a square Stage Manager window
        (CGSize.zero, false),                       // before the first layout
    ])
    func theSidebarOverlaysOnlyATallWindow(window: CGSize, overlays: Bool) {
        #expect(PadSplitLayout.sidebarOverlays(window: window) == overlays)
    }

    @Test(arguments: [
        (CGFloat(951), CGFloat(300), false),  // iPhone Duo's inner display: the sidebar steps aside
        (CGFloat(875), CGFloat(300), false),  // the same, less its vertical bar column
        (CGFloat(1376), CGFloat(300), true),  // 13-inch iPad, landscape: both fit
        (CGFloat(1180), CGFloat(300), true),  // 11-inch iPad, landscape
        (CGFloat(1082), CGFloat(300), true),  // exactly 300 + 1 + 400 + 1 + 380
        (CGFloat(1081), CGFloat(300), false),
    ])
    func theSidebarStaysOnlyWhereThreadAndPaneKeepTheirMinimums(window: CGFloat, sidebar: CGFloat, fits: Bool) {
        #expect(PadSplitLayout.sidebarFitsBesidePane(window: window, sidebar: sidebar) == fits)
    }

    @Test func thePaneDocksAtHalfTheColumnWithinItsBounds() {
        // The Duo's inner display, sidebar hidden: thread and pane each about half.
        #expect(PadSplitLayout.pane(column: 951) == .beside(width: 475.5))
        // A 13-inch iPad beside its sidebar: half the detail.
        #expect(PadSplitLayout.pane(column: 1075) == .beside(width: 537.5))
        // Wider than 1200: capped at the default 600.
        #expect(PadSplitLayout.pane(column: 1600) == .beside(width: 600))
        // Just wide enough: the thread keeps 400, the pane its 380.
        #expect(PadSplitLayout.pane(column: 781) == .beside(width: 380))
        #expect(PadSplitLayout.pane(column: 800) == .beside(width: 399))
    }

    @Test func aColumnTooNarrowForBothGivesThePaneTheColumn() {
        #expect(PadSplitLayout.pane(column: 780) == .alone)
        #expect(PadSplitLayout.pane(column: 0) == .alone)
    }

    @Test func unfoldingMovesTheTopTabScreensIntoThePane() {
        // A diff over the changes: both are the Changes tab, and the stack empties.
        #expect(PadSplitLayout.unfold([.changes, .changes])! == (0, .changes))
        // A run over Automations: Automations stays, the pane opens on Subagents.
        #expect(PadSplitLayout.unfold([nil, .subagents])! == (1, .subagents))
        // Terminal pushed over Changes: the top one's tab opens.
        #expect(PadSplitLayout.unfold([.changes, .terminal])! == (0, .terminal))
    }

    @Test func unfoldingKeepsAStackWhoseTopIsNoTab() {
        #expect(PadSplitLayout.unfold([]) == nil)
        #expect(PadSplitLayout.unfold([nil]) == nil)
        #expect(PadSplitLayout.unfold([.changes, nil]) == nil)
    }
}
