import SwiftUI
import ShepherdUI

/// Subagent surfaces: the tray above the composer and the inspector in the right pane. The
/// tray's rows and the inspector's parts carry their own dimensions (ShepherdUI, Agents).
extension AppLayout {
    /// Rows an open tray shows before it scrolls inside, so it never takes the thread's room.
    static let trayExpandedMaxRows = 8

    // Inspector
    /// The inspector is a card beside the thread (GXSubagents' `.insp` in its 420pt column, less the column's 16pt): 404pt wide,
    /// 24pt in from the window's trailing and bottom edges (the 8pt window padding and the column's 16), 8pt from the thread.
    static let inspectorCardWidth: CGFloat = 404
    static let inspectorCardTrailing: CGFloat = SHSidePaneMetrics.cardInset + 16
    static let inspectorCardBottom: CGFloat = SHSidePaneMetrics.cardInset + 16
    /// What the card takes beside the thread: its gap before it and its trailing inset.
    static let inspectorCardEdge: CGFloat = SHSidePaneMetrics.cardGap + inspectorCardTrailing
    static let inspectorTurnSpacing: CGFloat = 16
    /// "72 earlier turns · Show all" · "Reading earlier output".
    static let inspectorFooterHeight: CGFloat = 28
    static let steerMaxLines = 6
    /// The Subagents board's 10pt inset above the Steer card, and above its field.
    static let steerTopInset: CGFloat = 10
    /// The card's body (`.gsv-body`): 24pt under its head, 16pt in from its sides and 12pt above the Steer field.
    static let inspectorBodyPadding = EdgeInsets(top: SH.Space.xxl, leading: SH.Space.xl, bottom: SH.Space.l, trailing: SH.Space.xl)
    /// The Steer field (`.gsv-steer`): 12pt in from the card and under it, padded 6·6·6·12, its send 8pt from its words.
    static let steerMargin = SH.Space.l
    static let steerPadding = EdgeInsets(top: SH.Space.s, leading: SH.Space.l, bottom: SH.Space.s, trailing: SH.Space.s)
    static let steerGap = SH.Space.m
    /// Touched files listed under a finished run's result before "n more".
    static let inspectorMaxFiles = 5
}
