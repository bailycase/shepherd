import SwiftUI
import ShepherdUI

/// Issues & PRs (PRReview, PRReviewMerge, IssueReview, PRSidebarPinned): the page's columns,
/// the sidebar list's rows and the menus. The header is `SHPageMetrics.headerHeight`.
extension AppLayout {
    /// The page's reading column (the boards' `.gch-read`: up to 720) and its right rail (272), 56 apart.
    static let forgeContentWidth: CGFloat = 720
    static let forgeRailWidth: CGFloat = 272
    static let forgeColumnGap: CGFloat = 56
    /// The narrowest a reading column gets beside the rail; narrower, the rail goes under it.
    static let forgeReadingMinWidth: CGFloat = 480
    static let forgeTwoColumnMinWidth = forgeReadingMinWidth + forgeRailWidth + forgeColumnGap + forgePageLeading + forgePageTrailing
    /// `.gch-cols`: 28 in at the leading edge, 24 at the trailing, 22 above the tag row, 120 under the last row
    /// (clear of the dock), and the rail 4 lower than the column.
    static let forgePageLeading: CGFloat = 28
    static let forgePageTrailing: CGFloat = 24
    static let forgeTopPadding: CGFloat = 22
    static let forgeBottomPadding: CGFloat = 120
    static let forgeRailTop: CGFloat = SH.Space.xs
    /// The fade under the scrolled page, where the dock floats (`.gch-scroll:after`).
    static let forgeFadeHeight: CGFloat = 96
    /// The title (`.gch-h1`: 26 on 32, tracked -0.015em) and its pencil.
    static let forgeTitleSize: CGFloat = 26
    static let forgeTitleLine: CGFloat = 32
    static let forgeTitleTracking: CGFloat = -0.39
    static let forgeAvatarSize: CGFloat = 18
    static let forgeAvatarFont: CGFloat = 10
    /// The Checks tab: 26 above its head, rows 38 tall (14 in, 10 between), the log 38 in, its lines at 19 on 12.
    static let forgeChecksTop: CGFloat = 26
    static let forgeCheckRow: CGFloat = 38
    static let forgeCheckInset: CGFloat = 14
    static let forgeCheckGap: CGFloat = 10
    static let forgeCheckLogLeading: CGFloat = 38
    static let forgeLogLineSpacing: CGFloat = 5
    /// The state card (`.gch-ban`): 14 in at the sides, 11 above and 12 below.
    static let forgeBannerSide: CGFloat = 14
    static let forgeBannerTop: CGFloat = 11
    static let forgeBannerBottom: CGFloat = SH.Space.l
    /// The title's lines: 32 on a 26 face.
    static let forgeTitleLineSpacing: CGFloat = 0
    /// The page's tabs (`.segc`: 26 with 2 in, items 22 tall and 10 in, 5 between a label and its stats).
    static let forgeTabHeight: CGFloat = 22
    static let forgeTabPadding: CGFloat = 10
    static let forgeTabGap: CGFloat = 5
    /// The Activity header: a line over it with 16 above its words, 28 below the body.
    static let forgeActivityHeadTop: CGFloat = SH.Space.xl
    static let forgeActivityTop: CGFloat = 28
    /// A plain Activity row (`.act`: 32), and a comment's box (`.rvw`: radius 10, 10 in) with the hunk's number column (40).
    static let forgeActivityRow: CGFloat = 32
    static let forgeBoxRadius: CGFloat = 10
    static let forgeBoxInset: CGFloat = 10
    static let forgeHunkNumber: CGFloat = 40
    static let forgeTagHeight: CGFloat = 20
    /// An empty page's words (`.gch-empb`): 420 wide, 80 above the window's bottom edge; its links 18 apart.
    static let forgeEmptyWidth: CGFloat = 420
    static let forgeEmptyBottom: CGFloat = 80
    static let forgeEmptyActionGap: CGFloat = 18
    static let forgeEmptyTitleSize: CGFloat = 15
    /// The page's chips (`.prs`): 12 on 2 and 8 in, radius 10.
    static let forgeTagRadius: CGFloat = 10
    /// The dock's Ask the agent and Leave a comment field (the boards' `.gch-dockw`: up to 720, 28 in, 16 up).
    static let forgeComposerWidth: CGFloat = 720
    static let forgeComposerBottom: CGFloat = SH.Space.xl
    /// The author's initial beside a row's byline, and beside the page's byline and the rail's names.
    static let forgeRowAvatar: CGFloat = 14
    static let forgeAvatar: CGFloat = 20
    /// Between a sidebar row's title and its byline; above and below a row.
    static let forgeRowGap: CGFloat = SH.Space.xs
    static let forgeRowVertical: CGFloat = SH.Space.s + SH.Space.xxs
    /// A section caption's room above its rows.
    static let forgeSectionTop: CGFloat = SH.Space.l + SH.Space.xs
    /// The destination's title row (`.gch-fhd`: 32) and the Issues | Pull requests switch (28, 10 in from the sides).
    static let forgeSidebarHeaderHeight: CGFloat = SH.Height.controlL
    static let forgeSwitchHeight: CGFloat = SH.Height.controlM
    static let forgeSidebarControlInset: CGFloat = 10
    /// The search field's padding (9), and a menu's small chevron.
    static let forgeSearchPadding: CGFloat = 9
    static let forgeChevron: CGFloat = 9
    /// A row's room under its meta line (7; 6 over the title).
    static let forgeRowBottom: CGFloat = 7
    /// The search field's glyph and padding on either side of its placeholder, as measured to pick it.
    static let forgeSearchChrome: CGFloat = SH.Space.l + SH.Space.xs
    /// A rail section's rows.
    static let forgeRailRow: CGFloat = 26
    /// A rail section's caption row (22) and the 14 under its rows before and after its line.
    static let forgeRailHead: CGFloat = 22
    static let forgeRailGap: CGFloat = SH.Space.xl - SH.Space.xxs
    /// The merge menu (PRReviewMerge) and a pin's preview (PRSidebarPinned).
    static let forgeMergeMenuWidth: CGFloat = 340
    static let forgePinPreviewWidth: CGFloat = 320
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

    /// The side pane's Pull request tab (PRPane, PRPaneMerged): its 220 rail beside the column
    /// once the pane is wide enough for both, the merged state's 40 title bar, and a line
    /// comment's hunk (its last lines).
    static let prPaneRailWidth: CGFloat = 200
    static let prPaneTwoColumnMinWidth: CGFloat = 600
    static let prPaneHunkLines = 2
    /// GXPanePR: the head row (state, number, link buttons), the plain event rows, the outlined boxes, the footer and the title.
    static let prPaneHeadHeight: CGFloat = 42
    static let prPaneEventHeight: CGFloat = 32
    static let prPaneEventGlyph: CGFloat = 18
    static let prPaneBoxRadius: CGFloat = 10
    static let prPaneFooterHeight: CGFloat = 46
    static let prPaneTabHeight: CGFloat = 26
    static let prPaneTitleSize: CGFloat = 20
    static let prPaneColumnLeading: CGFloat = 18
    static let prPaneColumnTrailing: CGFloat = 22
}
