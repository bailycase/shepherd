import ShepherdUI
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
    /// A note's text sits this far past its rule (`NWThreadMetrics.ruleWidth`).
    static let noteIndent: CGFloat = 10

    // Starting
    /// How long a thread that draws something (a new agent's empty state, history read from
    /// disk) waits for pi before the composer says pi is starting: well past a normal start (pi
    /// answers about 0.8 s after ⌘N, and 1 s after a relaunch), so only a slow pi shows it.
    static let startingIndicatorDelay: Duration = .seconds(2)
    /// The same wait while the thread has nothing to draw yet (a remote agent's, or one whose
    /// session file cannot be read): a blank thread is explained sooner.
    static let blankStartingIndicatorDelay: Duration = .milliseconds(500)
    /// The composer's "Starting…": its spinner, and the gap after it.
    static let startingSpinner: CGFloat = 10
    static let startingSpacing: CGFloat = 6

    // Empty thread
    /// A fresh agent's framed empty state sits this far down, with its path in Geist Mono at
    /// this size ("New agent in ~/path").
    static let emptyThreadTop: CGFloat = 80
    static let emptyThreadPathSize: CGFloat = 15

    // Subagent card activity rows (Subagents.swift)
    static let toolNameWidth: CGFloat = 40

    // Composer and its menus
    /// Space under the composer card, and the fade above it.
    static let composerBottom: CGFloat = 16
    static let composerFade: CGFloat = 48
    /// A menu opens this far above the card, and keeps this far from the thread's top edge.
    static let menuGap: CGFloat = 8
    static let menuMargin: CGFloat = 8
    /// The thinking chip's lightbulb.
    static let chipSymbol: CGFloat = 11
    /// Half the narrowest width a real layout ever proposes the control row (the narrowest
    /// thread column less the composer's compact gutters and the row's own side paddings, 352pt).
    /// A narrower proposal is the window's minimum-size pass, which asks at no width or the
    /// paddings' (`ComposerControlsMinimum`); halving leaves a margin on both sides.
    static let composerControlsNarrowest: CGFloat = (threadMinWidth - 2 * gutterCompact - 2 * NW.Space.s) / 2
    /// Holding Send this long while pi works opens the Send menu (as a right-click does).
    static let sendHoldDelay: Duration = .milliseconds(500)

    // The queue ("Up next", above the card)
    /// How long a Deleted row offers Undo before it closes (the countdown waits while the row
    /// is hovered).
    static let queueUndoWindow: Duration = .seconds(5)
    /// An open editor renews its hold on the host this often; the host lets a hold lapse after
    /// two minutes, so a client that went away cannot keep the queue from going.
    static let queueHoldRenewal: Duration = .seconds(60)
    // The question panel, in the composer card: between its head, title, message, and answers;
    // and the message's height before it scrolls.
    static let questionSpacing: CGFloat = 10
    static let questionMessageMaxHeight: CGFloat = 140
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
