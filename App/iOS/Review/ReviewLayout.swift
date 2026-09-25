import SwiftUI
import ShepherdUI

/// Review's own measures (MobileChanges, MobileDiff, iPadReview, iPadReviewSplit boards).
extension MobileLayout {
    /// The Changes pane docked beside the thread: the board's 640pt, never more than this share
    /// of the detail, so the thread keeps a readable column.
    static let reviewDockWidth: CGFloat = 640
    static let reviewDockShare: CGFloat = 0.58
    /// The full-screen review's file list.
    static let reviewFileListWidth: CGFloat = 260
    /// The summary card's progress bar.
    static let reviewProgressHeight: CGFloat = 4
    /// A diff this wide or wider draws side by side unless the reviewer chose (ChangesStates:
    /// split from 900pt).
    static let reviewSplitMinWidth: CGFloat = 900
    /// The pane's tab row and the toolbar under it (iPadReview: 52 and 54pt).
    static let reviewPaneHeaderHeight: CGFloat = 52
    static let reviewToolbarHeight: CGFloat = 54
    /// The compare row (38pt) and a file's head (44pt).
    static let reviewCompareHeight: CGFloat = 38
    /// The base picker's popover.
    static let reviewBasePickerSize = CGSize(width: 380, height: 520)
    /// Between the cards of the changes screen.
    static let reviewCardSpacing: CGFloat = NW.Space.m + NW.Space.xxs
}
