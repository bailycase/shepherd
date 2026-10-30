import SwiftUI
import ShepherdUI

/// The composer's own measures (thread track), beside `MobileLayout`'s.
extension MobileLayout {
    /// An attachment thumbnail's pixels (a 20pt chip thumbnail at 3x).
    static let attachmentThumbnailPixels = CGSize(width: 60, height: 60)
    /// Space between the composer's parts: the queue, the command list, the chips, the field.
    static let composerSpacing: CGFloat = SH.Space.m
    /// The composer's padding under the field.
    static let composerBottom: CGFloat = SH.Space.m
    /// The Up next rows' most height before they scroll: three rows (a steering one included)
    /// with half of a fourth peeking, at the default text size (scaled with Dynamic Type), and
    /// never more than `queueShare` of the composer's room.
    static let queueRowsMaxHeight: CGFloat = (CGFloat(SHTouchQueueMetrics.visibleRows) + 0.5) * SHTouchQueueMetrics.rowHeight
    static let queueShare: CGFloat = 0.45
    /// An open tray's rows before they scroll, and their share of the composer's room: the
    /// subagents and Up next share one card, so each keeps some of it.
    static let trayRowsMaxHeight: CGFloat = 5.5 * SH.Height.touch
    static let trayShare: CGFloat = 0.35
    /// The share of the composer's room a question's text and answers may take before they
    /// scroll; the rest keeps its actions in reach.
    static let questionScrollShare: CGFloat = 0.7
    /// The share of the thread's height the composer may take.
    static let composerShare: CGFloat = 0.65
    /// How often an open editor renews its queued message's hold (the host drops one after two
    /// minutes), as the Mac's does.
    static let queueHoldRenewal: Duration = .seconds(60)
    /// The editor sheet's field: at least this many lines.
    static let queueEditorLines = 3
    /// Older pages the context sheet's Largest and Show summary load, at most, to find an entry.
    static let findPageLimit = 20
}
