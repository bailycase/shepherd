import ShepherdUI
import SwiftUI

/// The thread column and its composer (SHThread and SHComposer boards). The components' own
/// sizes are `SHThreadMetrics` and `SHComposerMetrics` in ShepherdUI.
extension AppLayout {
    // Thread
    /// The column's widest (Navigation board: "thread column · max 820 · prose 640").
    static let threadMaxWidth: CGFloat = 820
    /// Agent prose keeps the board's 640pt measure even though the column is wider.
    static let proseMaxWidth: CGFloat = 640
    static let userMaxWidth: CGFloat = 600
    static let gutter: CGFloat = 32
    /// Older pages the context meter's Largest and Show summary load, at most, to find an entry.
    static let findPageLimit = 20
    /// Gutter when the window is too narrow for the column plus the full gutter.
    static let gutterCompact: CGFloat = 16
    static let threadTop: CGFloat = 28
    static let turnSpacing: CGFloat = 28
    /// The viewport heights the eager tail's cover is worked out at: a window drag changes the
    /// tail a few times, not at every point of height.
    static let eagerCoverStep: CGFloat = 200
    /// How far past the viewport the eager tail's low height estimate must reach before the
    /// older rows can stay lazy (`NativeRowHeight`): a quarter-window of slack for where the
    /// estimate runs high.
    static let eagerCoverFactor: CGFloat = 1.25
    /// How many points of estimated height (`NativeRowHeight`) the eager tail covers in a
    /// thread `height` tall.
    static func eagerCoverHeight(forViewport height: CGFloat) -> Int {
        let bucket = max(eagerCoverStep, (height / eagerCoverStep).rounded(.up) * eagerCoverStep)
        return Int((bucket * eagerCoverFactor).rounded(.up))
    }
    /// How many viewports of rows (by the low height estimate, `eagerCoverHeight` each) the eager tail covers at least, whatever its
    /// rows cost (`NativeThreadStore.eagerTailRows`): the reader's screen and the one above it are never the lazy stack's estimates.
    static let eagerTailViewports = 2
    /// How many rows at most cross between the eager tail and the lazy stack each time a thread's rows change (`ThreadEagerTail`): a
    /// turn's two, which a thread of cheap rows moves it by anyway. A crossing builds the row again and drops its state.
    static let eagerTailCrossing = 2
    /// The height of rows, by the low estimate, that the eager tail covers at least in a thread whose `eagerCoverHeight` is `cover`.
    static func eagerTailHeight(cover: Int) -> Int { cover * eagerTailViewports }
    /// Between a turn's parts: thinking, prose, its activity, cards, the changes card, the footer.
    static let turnItemSpacing: CGFloat = 14
    /// Between consecutive activity lines.
    static let activitySpacing: CGFloat = 6
    /// Between blocks inside one part (subagent cards in a stack).
    static let blockSpacing: CGFloat = 10
    /// A note's text sits this far past its rule (`SHThreadMetrics.ruleWidth`).
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

    // Resting
    /// How long the main window stays unseen before the thread on screen rests (`NativeThreadStore.rest`): a Space swipe
    /// or Mission Control covers it for less, and rests nothing.
    static let threadRestDelay: Duration = .seconds(1)

    // Restoring a thread's rows (`ThreadRestore`)
    /// How long a restore waits after the update that drew a step before it draws the next: the frame goes out, and the person's
    /// keys and scrolls are read, between steps.
    static let restorePause: Duration = .milliseconds(1)
    /// How long a restore waits to look again while the reader scrolls or is away from the tail.
    static let restoreRetry: Duration = .milliseconds(100)
    /// How long a hidden thread that follows its tail waits before it lets its lazy stack go (`ThreadRestore.withdrawStack`): taking
    /// the stack's realized rows down costs the main thread tens to hundreds of milliseconds, which must not land in the turn that shows another thread.
    static let hiddenStackDelay: Duration = .seconds(2)
    /// How many of the threads left most recently keep their lazy stack (`ThreadReaderPins.leftRecently`): bringing a stack back costs
    /// the main thread what measuring the rows at its start does (about 5 ms a MiB of them), and the threads a person goes back and forth
    /// between are these. Each holds what its stack realized, which the budget does not count.
    static let keptStacks = 3
    /// How long a hidden thread whose stack is kept (`keptStacks`) waits to ask again whether it still is.
    static let hiddenStackRecheck: Duration = .seconds(1)
    /// How many `restoreRetry` the first lazy stack waits for the replies at the end of the tail to have their blocks (a large reply is
    /// parsed off the main thread, a giant one in about a second) before it comes anyway: a reader cannot scroll past the eager tail meanwhile.
    static let restoreParseRetries = 30
    /// The estimated bytes (`NativeThreadStore.restoreStep`) of rows one step draws, at most; a row larger than it goes whole.
    /// About a code-heavy reply, whose views take tens of milliseconds to build.
    static let restoreStepBytes = 4 << 20
    /// How long after a key or a scroll the person still counts as at work (`UserActivity`), which a restore and the passes that
    /// let hidden threads' rows go wait out.
    static let inputRecentWindow: Duration = .milliseconds(750)

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
    /// Extra breathing room between the transcript tail and the floating composer.
    static let composerTranscriptGap: CGFloat = SH.Space.xxl
    static let composerFade: CGFloat = 48
    /// A menu opens this far above the card, and keeps this far from the thread's top edge.
    static let menuGap: CGFloat = 8
    static let menuMargin: CGFloat = 8
    /// A chip's symbol, as big as the Fast bolt.
    static let chipSymbol = SHComposerMetrics.chipSymbol
    /// Half the narrowest width a real layout ever proposes the control row (the narrowest
    /// thread column less the composer's compact gutters and the row's own side paddings, 352pt).
    /// A narrower proposal is the window's minimum-size pass, which asks at no width or the
    /// paddings' (`ComposerControlsMinimum`); halving leaves a margin on both sides.
    static let composerControlsNarrowest: CGFloat = (threadMinWidth - 2 * gutterCompact - 2 * SH.Space.s) / 2
    /// Holding Send this long while pi works opens the Send menu (as a right-click does).
    static let sendHoldDelay: Duration = .milliseconds(500)

    // The queue ("Up next", above the card)
    /// How long a Deleted row offers Undo before it closes (the countdown waits while the row
    /// is hovered).
    static let queueUndoWindow: Duration = .seconds(5)
    /// An open editor renews its hold on the host this often; the host lets a hold lapse after
    /// two minutes, so a client that went away cannot keep the queue from going.
    static let queueHoldRenewal: Duration = .seconds(60)
    /// Row height of the directory picker's list (RemoteDirectoryPicker).
    static let menuRowHeight: CGFloat = 36

    /// The thread's side gutters in a thread `width` wide: the full gutter while the widest
    /// column fits between two of them, else the compact one, so a narrow thread keeps its
    /// column rather than its margins.
    static func threadGutter(width: CGFloat) -> CGFloat {
        width >= threadMaxWidth + 2 * gutter ? gutter : gutterCompact
    }
}
