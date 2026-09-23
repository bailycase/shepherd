import SwiftUI

/// The thread column and its composer (NWThread and NWComposer boards). The components' own
/// sizes are `NWThreadMetrics` and `NWComposerMetrics` in ShepherdUI.
extension AppLayout {
    // Thread
    /// The column's widest (Navigation board: "thread column · max 820 · prose 640").
    static let threadMaxWidth: CGFloat = 820
    /// Agent prose keeps the board's 640pt measure even though the column is wider.
    static let proseMaxWidth: CGFloat = 640
    static let userMaxWidth: CGFloat = 600
    static let gutter: CGFloat = 32
    /// Gutter when the window is too narrow for the column plus the full gutter.
    static let gutterCompact: CGFloat = 16
    static let threadTop: CGFloat = 28
    static let turnSpacing: CGFloat = 28
    /// Between a turn's parts: thinking, prose, its activity, cards, the changes card, the footer.
    static let turnItemSpacing: CGFloat = 14
    /// Between consecutive activity lines.
    static let activitySpacing: CGFloat = 6
    /// Between blocks inside one part (subagent cards in a stack).
    static let blockSpacing: CGFloat = 10

    // Subagent card activity rows (Subagents.swift)
    static let toolNameWidth: CGFloat = 40

    // Composer and its menus
    /// Space under the composer card, and the fade above it.
    static let composerBottom: CGFloat = 16
    static let composerFade: CGFloat = 48
    /// A menu opens this far above the card.
    static let menuGap: CGFloat = 8
    /// Row height of the directory picker's list (RemoteDirectoryPicker).
    static let menuRowHeight: CGFloat = 36
    /// The New Agent sheet's model list.
    static let modelPickerWidth: CGFloat = 380

    /// The thread's side gutters in a thread `width` wide: the full gutter while the widest
    /// column fits between two of them, else the compact one, so a narrow thread keeps its
    /// column rather than its margins.
    static func threadGutter(width: CGFloat) -> CGFloat {
        width >= threadMaxWidth + 2 * gutter ? gutter : gutterCompact
    }
}
