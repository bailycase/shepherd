import SwiftUI
import ShepherdUI

/// Issues & PRs (PRReview, PRReviewMerge, IssueReview, PRSidebarPinned): the page's columns,
/// the sidebar list's rows and the menus. The header is `SHPageMetrics.headerHeight`.
extension AppLayout {
    /// The page's reading column (the boards' 680) and its right rail (260), 32 apart.
    static let forgeContentWidth: CGFloat = 680
    static let forgeRailWidth: CGFloat = 260
    static let forgeColumnGap: CGFloat = SH.Space.xxxl
    static let forgeTwoColumnMinWidth = forgeContentWidth + forgeRailWidth + forgeColumnGap + 2 * SH.Space.xxl
    /// Above the state tag, and under the last row (clear of the floating field).
    static let forgeTopPadding: CGFloat = SH.Space.xxl + SH.Space.s
    static let forgeBottomPadding: CGFloat = 96
    /// The floating Ask the agent and Leave a comment field (the boards' 620).
    static let forgeComposerWidth: CGFloat = 620
    static let forgeComposerHeight: CGFloat = 44
    static let forgeComposerBottom: CGFloat = SH.Space.l + SH.Space.xxs
    static let forgeSendButton: CGFloat = SH.Height.controlL
    /// The author's initial beside a row's byline, and beside the page's byline and the rail's names.
    static let forgeRowAvatar: CGFloat = 14
    static let forgeAvatar: CGFloat = 20
    /// Between a sidebar row's title and its byline; above and below a row.
    static let forgeRowGap: CGFloat = SH.Space.xs
    static let forgeRowVertical: CGFloat = SH.Space.s + SH.Space.xxs
    /// A section caption's room above its rows.
    static let forgeSectionTop: CGFloat = SH.Space.l + SH.Space.xs
    /// Each Issues | Pull requests segment, horizontal when both fit, otherwise stacked.
    static let forgeSwitchHeight: CGFloat = SH.Height.controlL
    /// A rail section's rows.
    static let forgeRailRow: CGFloat = 30
    /// The merge menu (PRReviewMerge) and a pin's preview (PRSidebarPinned).
    static let forgeMergeMenuWidth: CGFloat = 320
    static let forgePinPreviewWidth: CGFloat = 300
    /// A pin's preview waits this long under the pointer, so passing over the list opens none.
    static let forgePinPreviewDelay: Duration = .milliseconds(450)
    /// The submit review popover, and its text's height.
    static let forgeReviewWidth: CGFloat = 360
    static let forgeReviewTextHeight: CGFloat = 96
    /// A failing job's log tail on the Checks tab.
    static let forgeLogMaxHeight: CGFloat = 220
    /// The loading page's bars (PRReviewLoading): widths as fractions of the column.
    static let forgeSkeletonBar: CGFloat = 12
    static let forgeSkeletonTitle: CGFloat = 28
}
