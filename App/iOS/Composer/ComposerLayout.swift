import SwiftUI
import ShepherdUI

/// The composer's own measures (thread track), beside `MobileLayout`'s.
extension MobileLayout {
    /// An attachment thumbnail's pixels (a 20pt chip thumbnail at 3x).
    static let attachmentThumbnailPixels = CGSize(width: 60, height: 60)
    /// Space between the composer's parts: the queue, the command list, the chips, the field.
    static let composerSpacing: CGFloat = NW.Space.m
    /// The composer's padding under the field.
    static let composerBottom: CGFloat = NW.Space.m
    /// The Up next rows' most height before they scroll: three rows at the default text size
    /// (scaled with Dynamic Type), and never more than `queueShare` of the composer's room.
    static let queueRowsMaxHeight: CGFloat = CGFloat(NWTouchQueueMetrics.visibleRows) * NWTouchQueueMetrics.rowHeight
    static let queueShare: CGFloat = 0.45
    /// The share of the composer's room a question's text and answers may take before they
    /// scroll; the rest keeps its actions in reach.
    static let questionScrollShare: CGFloat = 0.7
    /// The share of the thread's height the composer may take.
    static let composerShare: CGFloat = 0.65
    /// The editor sheet's field: at least this many lines.
    static let queueEditorLines = 3
    /// A wide question panel (iPad) lays its options in columns at least this wide.
    static let questionColumn: CGFloat = NWTouchQuestionMetrics.columnMinWidth
}
