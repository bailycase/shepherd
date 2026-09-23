import SwiftUI

/// Subagent surfaces: the cards' stack in the thread and the inspector in the right pane. The
/// cards, strip, ledger, and inspector parts carry their own dimensions (ShepherdUI, Agents).
extension AppLayout {
    /// Between sibling cards, and between the strip and the cards under it.
    static let subagentStackSpacing: CGFloat = 8

    // Inspector
    static let inspectorPadding: CGFloat = 14
    static let inspectorTurnSpacing: CGFloat = 16
    /// "72 earlier turns · Show all" · "Following live".
    static let inspectorFooterHeight: CGFloat = 28
    static let steerMaxLines = 6
    /// Touched files listed under a finished run's result before "n more".
    static let inspectorMaxFiles = 5
}
