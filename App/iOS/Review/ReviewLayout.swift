import SwiftUI
import ShepherdUI

/// Review's own measures (MobileChanges, MobileDiff, iPadReview, iPadReviewSplit boards).
extension MobileLayout {
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
    /// The type of the pane's compare row and file switcher (DuoOpenSidePane, iPadReview: 13 over the diff's 12).
    static let reviewPaneRowFont: CGFloat = 13
    /// The send bar (iPadReview: at least 56pt) and a full-screen file row (56pt).
    static let reviewSendBarHeight: CGFloat = 56
    static let reviewFileRowHeight: CGFloat = 56
    /// A viewed file in the full-screen list.
    static let reviewViewedOpacity: Double = 0.6
    /// The base picker's popover.
    static let reviewBasePickerSize = CGSize(width: 380, height: 520)
    /// Between the cards of the changes screen.
    static let reviewCardSpacing: CGFloat = SH.Space.m + SH.Space.xxs
}

/// The touch boards' own measures (the gt- rows, cards and bars of the Changes, Commit and
/// Issues & PRs boards): 16pt cards, 52pt rows and bars, 15 over 13 type.
extension MobileLayout {
    static let touchCardRadius: CGFloat = SH.Radius.xxl
    static let touchRowHeight: CGFloat = 52
    /// A row's text: the body at 15 and what sits under it at 13.
    static let touchBodyFont: CGFloat = 15
    static let touchDetailFont: CGFloat = 13
    /// The title over a screen's content (the boards' 22).
    static let touchTitleFont: CGFloat = 22
    /// The floating bar at the bottom: 52pt, its items split by a 20pt rule.
    static let touchBarHeight: CGFloat = 52
    static let touchBarRuleHeight: CGFloat = 20
    /// The segmented switch (Summary | Changes | Checks): 36pt, its selected pill inset 3pt.
    static let touchSegmentHeight: CGFloat = 36
    static let touchSegmentInset: CGFloat = 3
    /// The search field and the filter pills under it.
    static let touchFieldHeight: CGFloat = 40
    static let touchPillHeight: CGFloat = 36
    /// The glyph column of a status row (the boards' 28).
    static let touchGlyphColumn: CGFloat = SH.Space.xxl + SH.Space.xs
    /// A sheet's main button.
    static let touchPrimaryHeight: CGFloat = 50
    /// The same on iPad, sized to its words.
    static let touchCompactHeight: CGFloat = 40
    static let touchDisabledOpacity: Double = 0.4
    /// How far the screen fades into the bar's background above it.
    static let touchBarFade: CGFloat = 28
}
