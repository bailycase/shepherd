import SwiftUI
import ShepherdUI

/// Review's own measures (MobileChanges, MobileDiff, iPadReview, iPadReviewSplit boards).
extension MobileLayout {
    /// The review docked beside the thread: the board's 620pt, never more than this share of
    /// the detail, so the thread keeps a readable column.
    static let reviewDockWidth: CGFloat = 620
    static let reviewDockShare: CGFloat = 0.58
    /// The full-screen review's file list.
    static let reviewFileListWidth: CGFloat = 260
    /// The summary card's progress bar.
    static let reviewProgressHeight: CGFloat = 4
    /// Between the cards of the changes screen.
    static let reviewCardSpacing: CGFloat = NW.Space.m + NW.Space.xxs
}
