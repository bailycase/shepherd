import SwiftUI

/// Every measure the Projects surfaces draw, read off the supplied boards' exported markup (computed in a
/// browser at 1x: points are CSS pixels), never rounded to a nearby token. Each is named for the thing it sizes.
/// Where a value equals an existing token the token is used at the call site; what is here has none.

public enum NWLeadMetrics {
    // MARK: Sidebar (ProjectLead-Paused, -Question)

    /// A task thread under its Project: its dot sits at 38pt (the row's 8 + 26 + 4), so the row leads 26pt in.
    public static let sidebarTaskLeading: CGFloat = 26

    // MARK: The window's two columns (ProjectLead-Started: 1600 x 900)

    /// The main column's toolbar height, and the thing it holds (Gamecards, Overview, settings).
    public static let toolbarHeight: CGFloat = 44
    public static let toolbarGlyph: CGFloat = 14
    public static let toolbarButtonHeight: CGFloat = 28
    public static let toolbarIconWidth: CGFloat = 30
    public static let toolbarPadding: CGFloat = 12
    /// The Overview tab's dot (Paused, Resolved: something needs you), 6pt `lantern`.
    public static let toolbarDot: CGFloat = 6
    /// The Project toolbar's glyph box starts 12pt from the page edge, and its title 6pt after the glyph (ProjectLead-Started).
    public static let toolbarLeading: CGFloat = 12
    public static let toolbarTitleGap: CGFloat = 6
    /// The Threads tab's count: a 16pt `running` pill (radius 4), 10.5/600 white, 6pt after the title.
    public static let badge: CGFloat = 16
    public static let badgeSize: CGFloat = 10.5

    /// The Threads pane's box (ProjectLead-ThreadRunning markup: a 480 wrapper holding a 479 aside behind a 1pt leading line). The conversation
    /// beside it is 888pt in a 1600pt window with the 232 sidebar (1120 - 232), so its column centres on x 676.
    public static let paneWidth: CGFloat = 480
    public static let paneBorder: CGFloat = 1
    /// The message column: 680pt wide, centred, in 24pt of side padding and 16pt above.
    public static let columnWidth: CGFloat = 680
    public static let columnSidePadding: CGFloat = 24
    public static let columnTopPadding: CGFloat = 16

    // MARK: New project sheet (ProjectLead-New), measured with the bundled Geist: 560 x 640, a 1pt `lineStrong` border on
    // `bgRaised`, square corners.

    public static let sheetWidth: CGFloat = 560
    public static let sheetHeight: CGFloat = 640
    /// Header: 18pt above, 16 in on the left and 14 on the right; the title is 15/600 and the close circle 28pt (1pt `lineStrong`).
    public static let sheetHeaderTop: CGFloat = 18
    public static let sheetHeaderLeading: CGFloat = 16
    public static let sheetHeaderTrailing: CGFloat = 14
    public static let sheetClose: CGFloat = 28
    /// The 40pt slot around it (12 above, 8 below, 8 right): 60pt in all before the first label, which sits at y 61.
    public static let sheetCloseSlot: CGFloat = 40
    /// The close circle's cross: 11.5pt, a 1.5 stroke on a 12-unit grid from 2.5 to 9.5 (an SVG path, not a symbol).
    public static let sheetCloseGlyph: CGFloat = 11.5
    public static let sheetCloseStroke: CGFloat = 1.5
    /// Between the header and the first label.
    public static let sheetHeaderGap: CGFloat = 14
    /// Fields run 16pt in from each side. A label is 12.5/500 (the "optional" word 12.5/400 `textTertiary`), 6pt over its field;
    /// a field is 32pt tall, radius 8, 12pt of padding, 12.5pt text, a 1pt `lineStrong` border on `bgSunken`; 16pt between groups.
    public static let sheetSide: CGFloat = 16
    public static let sheetLabelGap: CGFloat = 6
    public static let sheetGroupGap: CGFloat = 16
    public static let sheetFieldHeight: CGFloat = 32
    public static let sheetFieldRadius: CGFloat = 8
    public static let sheetFieldPadding: CGFloat = 12
    /// The Spaces help (11.5 on 1.45 `textTertiary`) sits 6pt under its label and 10pt over the popup.
    public static let sheetHelpGap: CGFloat = 10
    public static let sheetHelpLineSpacing: CGFloat = 3
    /// The "Add a space…" popup: 32pt, radius 7, 13pt text, 12pt in on the left, 32pt on the right for its 12pt chevrons.
    public static let sheetPopupRadius: CGFloat = 7
    public static let sheetPopupText: CGFloat = 13
    public static let sheetPopupTrailing: CGFloat = 32
    public static let sheetPopupChevron: CGFloat = 12
    /// Footer: a 1pt `lineSubtle` rule, 14pt above and below 28pt buttons (radius 6, 10pt sides, 12.5/500), 16pt in on the right.
    public static let sheetFooterPadding: CGFloat = 14
    /// The footer is 57pt (rule at y 582 of 640, inside the 1pt border): 14 above its 28pt buttons and 15 below.
    public static let sheetFooterBottom: CGFloat = 15
    /// 61pt from the sheet top to the first label: the 40pt close slot between 13 above (12 and the sheet's line) and 8 below.
    public static let sheetHeaderBottom: CGFloat = 8
    /// The sheet's own 1pt line is inside its box, so the header starts 1pt lower (close at y 19, title at 23.5) and ends 1pt sooner.
    public static let sheetBorder: CGFloat = 1
    /// A footer button is its label plus 10pt each side inside a 1pt line (Cancel 40.675 + 22 = 62.7, Create project 83.41 + 22 = 105.4).
    public static let sheetButtonSide: CGFloat = 11
    public static let sheetFooterRuleY: CGFloat = 582

    // MARK: Overview (ProjectLead-EmptyV2)

    /// The page title: a 16pt glyph and the name (15/600) 8pt apart, 60pt down from the window's top (16 under the toolbar).
    public static let overviewGlyph: CGFloat = 16
    public static let overviewTitleGap: CGFloat = 8
    public static let overviewTop: CGFloat = 16
    /// 12pt between the title, the goal and the two cards.
    public static let overviewGap: CGFloat = 12
    /// The goal's lines are 13.5 on 1.6: 21.6pt, i.e. 8.1pt over a 13.5 font's own height.
    public static let overviewGoalLineSpacing: CGFloat = 4
    /// A suggestion row: 29pt between 14pt glyphs.
    public static let suggestionRow: CGFloat = 29

    // MARK: Conversation turns

    public static let dayLabelSize: CGFloat = 11.5
    /// A user bubble: 13.5pt on 1.5 lines, 12 by 16 padding, 1pt `lineStrong`, radius 8, on `bgBubble`, at most 520pt.
    public static let bubbleMaxWidth: CGFloat = 520
    public static let bubblePaddingV: CGFloat = 12
    public static let bubblePaddingH: CGFloat = 16
    public static let bubbleLineHeight: CGFloat = 1.5
    /// Agent prose: 13.5pt on 1.6 lines.
    public static let proseLineHeight: CGFloat = 1.6
    /// Between a bubble, prose and a task card in the column.
    public static let turnGap: CGFloat = 16

    // MARK: Task card in the conversation (a thread the project started)

    /// 34pt tall, radius 8, 1pt `lineStrong` on `bgRaised`, padding 4/12/4/8, 8pt gaps.
    public static let taskCardHeight: CGFloat = 34
    public static let taskCardRadius: CGFloat = 8
    public static let taskCardPadding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 12)
    public static let taskDot: CGFloat = 6
    public static let taskQuestionRowHeight: CGFloat = 24
    public static let taskTitleSize: CGFloat = 12.5
    public static let taskStatusSize: CGFloat = 11.5
    /// A task reference in prose (ProjectLead-Question `.pc-link`): 4pt sides, a 6pt dot and 4pt gap before the title, radius 4
    /// (`NW.Radius.xs`), `runningTint`, the line box tall.
    public static let taskLinkPad: CGFloat = 4
    public static let taskLinkDot: CGFloat = 6
    public static let taskLinkGap: CGFloat = 4
    /// A file chip in the card: 22pt tall, 6pt sides, 4pt gap, 1pt `lineSubtle`, radius 6, mono 10.5, glyph 10.
    public static let chipHeight: CGFloat = 22
    public static let chipPaddingH: CGFloat = 6
    public static let chipGap: CGFloat = 4
    public static let chipRadius: CGFloat = 6
    public static let chipGlyph: CGFloat = 10
    /// A chip is pressed over this height (the desktop minimum); it is drawn chipHeight, centred in it.
    public static let chipPressHeight: CGFloat = 24
    /// A file chip's name: mono 10.5.
    public static let chipText: CGFloat = 10.5
    /// The board never shortens a file name (its chips are nowrap); a name past this ellipsizes in the middle so one file cannot
    /// take the card. (A guard the markup has no value for, sized to hold the board's longest name, `checkout-widget.html`, plus room.)
    public static let chipNameMaxWidth: CGFloat = 160
    /// The worker's Steps card (ProjectLead-ThreadRunning, -Resolved): 12pt padding, 6pt between rows, a 1pt `lineStrong` border at
    /// radius 12 and no fill; each row is an 8pt gap between a 14pt glyph box and 12.5pt text. The current step's ring is 11pt with a
    /// 1.5pt stroke open at the right; a pending step's is 11pt with a 1pt dashed stroke.
    /// (Padding and radius are `stepsPadding` and `stepsRadius` below.)
    public static let stepsGap: CGFloat = 6
    public static let stepsGlyphBox: CGFloat = 14
    public static let stepsRing: CGFloat = 11
    public static let stepsCurrentStroke: CGFloat = 1.5
    public static let stepsPendingStroke: CGFloat = 1
    public static let stepsPendingDash: [CGFloat] = [2, 2]
    /// The summary strip over the composer ("2 of 3 done · 1 needs you"): 37pt, radius 12, a 19pt disclosure row inside.
    public static let summaryHeight: CGFloat = 37
    public static let summaryRadius: CGFloat = 12
    public static let summaryRowHeight: CGFloat = 19
    public static let summaryChevron: CGFloat = 10
    public static let summaryPadding: CGFloat = 8

    // MARK: Question card (ProjectLead-Question)

    /// Option rows 52.67pt (8/12 padding, a 22pt key, 12.5/500 title over 11.5 on 1.45), 1pt `lineSubtle` between.
    public static let optionKey: CGFloat = 22
    public static let optionKeyRadius: CGFloat = 6
    public static let optionKeySize: CGFloat = 10.5
    public static let optionPaddingV: CGFloat = 8
    public static let optionPaddingH: CGFloat = 12
    public static let optionGap: CGFloat = 12
    public static let optionTextLineHeight: CGFloat = 1.45
    /// An option's detail: 11.5pt text on 16.67pt lines (11.5 x 1.45). The caption style already sets 1.35 (15.5pt), so the extra
    /// leading is the 1.45 board line height minus that.
    public static let optionDetailLeading: CGFloat = 11.5 * (1.45 - 1.35)
    public static let optionTitleLine: CGFloat = 17
    public static let optionDetailLine: CGFloat = 16.67
    /// Between an option's title and its detail.
    public static let optionTitleGap: CGFloat = 2
    /// The question's own line: 38pt, padded 12 on every side with the text on 14pt lines.
    public static let questionPadding: CGFloat = 12
    /// 12 above and at the sides, 8 below (the board: 499.98 + 38, options from 538).
    public static let questionBottom: CGFloat = 8
    /// The card's own 1pt border, above the question line.
    public static let questionBorder: CGFloat = 1
    public static let questionHeight: CGFloat = 38
    /// The footer line ("Or just reply in chat…"): 32pt, padded 8 / 12.
    public static let questionFooterHeight: CGFloat = 32

    // MARK: Composer (the Project's own, ProjectLead-Started)

    /// Between the cards over the composer (a question, an offer, the summary strip): 16pt (the board: card ends 729, strip begins 745).
    public static let dockGap: CGFloat = 16
    public static let composerHeight: CGFloat = 94
    public static let composerRadius: CGFloat = 8
    public static let composerFieldHeight: CGFloat = 56
    public static let composerBottom: CGFloat = 16
    /// The controls row sits 9pt under the field and flush to the card's 1pt line (Attach y 856..882 and Send 855..883 in a card 790..884),
    /// where the ordinary composer leaves 4 above and 6 below.
    public static let composerControlsTop: CGFloat = 9
    public static let composerControlsBottom: CGFloat = 1

    // MARK: Pause banner (ProjectLead-PausedV2)

    /// 46pt tall, 856pt wide inside the 888 section (16pt in), radius 8, 1pt `lineStrong` on `bgRaised`, padding 8/8/8/12.
    public static let bannerHeight: CGFloat = 46
    public static let bannerInset: CGFloat = 16
    public static let bannerTop: CGFloat = 12
    public static let bannerPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)
    public static let bannerGap: CGFloat = 12
    public static let bannerGlyph: CGFloat = 14

    // MARK: Right pane (Threads)

    /// The pane's header tabs: 28pt buttons 2pt apart (Threads 8pt in, then Files, Automations, New thread).
    public static let paneHeaderInset: CGFloat = 8
    public static let paneTabGap: CGFloat = 2
    public static let paneHeaderButton: CGFloat = 28
    /// "Welcome back, Baily." Geist 28/600 on 1.15, 8pt in (x1137 = 1121 + 16), 18pt down from the toolbar.
    public static let welcomeSize: CGFloat = 28
    public static let welcomeLineHeight: CGFloat = 1.15
    public static let panePadding: CGFloat = 16
    /// A group header ("Working 3"): 28pt tall, `bgRaised`, radius 6, 12pt chevron, 12.5 title, 12.5 count.
    public static let groupHeaderHeight: CGFloat = 28
    public static let groupChevron: CGFloat = 12
    /// A thread row: 42pt (38 once resolved), 4/12/4/8 padding, a 6pt dot, 12.5/500 title over 11.5 detail and a
    /// 10.5 age. (No subagent pill: a Project's agents never use subagents.)
    public static let threadRowHeight: CGFloat = 42
    public static let resolvedRowHeight: CGFloat = 38
    public static let threadRowDot: CGFloat = 6
    public static let ageSize: CGFloat = 10.5
    public static let rowGap: CGFloat = 2

    /// The pane's footer card ("The project is paused." / "This thread is resolved."): 50pt, 8pt radius.
    public static let footerHeight: CGFloat = 50
    public static let footerInset: CGFloat = 16
    public static let footerGlyph: CGFloat = 14

    /// A worker's thread in the pane: prose and its composer sit 16pt in from the pane's left edge; the composer card ends 16pt
    /// before the prose does (32pt from the pane's right edge).
    public static let paneThreadGutter: CGFloat = 16
    /// The pane's scroll area pads 12pt above its first line (`--space-l`; the markup: header 44, "Today" at y 56), not the conversation's 16.
    public static let paneThreadTop: CGFloat = 12
    public static let paneComposerTrailing: CGFloat = 16

    /// The Files tab's preview of one file: at most this tall before it scrolls.
    public static let filePreviewHeight: CGFloat = 240

    // MARK: Space offer card (ProjectLead-AddsSpace)

    /// "gamecards-web / ~/code/gamecards-web · This Mac  Not now  Add to project": 50.75pt, radius 12, 1pt `lineStrong` on `bgRaised`,
    /// padded 8/8/8/12 with a 12pt gap. The folder glyph is 14pt; the name 12.5/500 over a 10.5 mono path; both buttons are 28pt.
    public static let offerRadius: CGFloat = 12
    public static let offerHeight: CGFloat = 50.75
    public static let offerPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8)
    public static let offerGap: CGFloat = 12
    public static let offerButtonGap: CGFloat = 12
    public static let offerPathSize: CGFloat = 10.5

    // MARK: Thread detail (ProjectLead-Resolved / -ThreadRunning)

    /// Breadcrumb: "Threads" then a 12pt chevron then the title (12.5/600); 26pt icon buttons, 6pt radius.
    public static let detailButton: CGFloat = 26
    public static let steps: CGFloat = 66
    public static let stepsRadius: CGFloat = 12
    public static let stepsPadding: CGFloat = 12
    /// The 12pt padding is inside the 1pt border (the markup's border-box is 66 = 1 + 12 + 17 + 6 + 17 + 12 + 1); `nwBorder` draws over it.
    public static let stepsBorder: CGFloat = 1
    public static let fileChipRadius: CGFloat = 8
}
