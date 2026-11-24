import SwiftUI

/// Subagent surfaces: the tray above the composer and the inspector in the right pane. The
/// tray's rows and the inspector's parts carry their own dimensions (ShepherdUI, Agents).
extension AppLayout {
    /// Rows an open tray shows before it scrolls inside, so it never takes the thread's room.
    static let trayExpandedMaxRows = 8

    // Inspector
    static let inspectorPadding: CGFloat = 14
    static let inspectorTurnSpacing: CGFloat = 16
    /// "72 earlier turns · Show all" · "Following live".
    static let inspectorFooterHeight: CGFloat = 28
    static let steerMaxLines = 6
    /// The Subagents board's 10pt inset above the Steer card, and above its field.
    static let steerTopInset: CGFloat = 10
    /// The redesign's steer box (`.isteer`): 10pt in from the pane and under it, padded 10·10·8·12, its words 6pt over Steer.
    static let steerBoxMargin = EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10)
    static let steerBoxPadding = EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 10)
    static let steerBoxGap: CGFloat = 6
    /// Touched files listed under a finished run's result before "n more".
    static let inspectorMaxFiles = 5
}
