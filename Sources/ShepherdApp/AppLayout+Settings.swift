import SwiftUI
import ShepherdUI

/// Settings and the sheets: the in-window Settings surface (a 232pt nav beside a 720pt column,
/// or a wide page) and the size of every modal.
extension AppLayout {
    // Settings
    static let settingsNavWidth: CGFloat = 232
    /// The strip at the top of the nav and the page that holds the window controls and drags
    /// the window.
    static let settingsWindowStripHeight: CGFloat = 44
    /// Back to Shepherd: a 30pt row, not scaled by density.
    static let settingsBackRowHeight: CGFloat = 30
    /// Back's chevron column: 10pt, 8 before the words.
    static let settingsBackGlyphWidth: CGFloat = 10
    /// Back to Shepherd to the search field: 10pt.
    static let settingsSearchTop: CGFloat = 10
    static let settingsNavRowSpacing: CGFloat = NW.Space.xxs
    static let settingsContentWidth: CGFloat = 720
    static let settingsTop: CGFloat = 44
    static let settingsBottom: CGFloat = 48
    /// 48pt either side of the page's column.
    static let settingsGutter: CGFloat = NW.Space.xxxl + NW.Space.xl
    /// The page title: Geist 22/600, tracked −1%.
    static let settingsTitleSize: CGFloat = 22
    static let settingsTitleTracking: CGFloat = -0.01
    /// A group's footnote: Geist 12/1.5.
    static let settingsFootnoteSize: CGFloat = 12
    static let settingsFootnoteLineHeight: CGFloat = 1.5
    /// A remote host's address in its row ("horizon.starlight.internal:7433"): mono 12.
    static let settingsAddressSize: CGFloat = 12
    /// Between the page header and each group.
    static let settingsGroupSpacing: CGFloat = NW.Space.xxl + NW.Space.xs
    /// A row's content, density-scaled; the row adds 10pt above and below (`NWCardRowFrame`).
    @MainActor static var settingsRowMinHeight: CGFloat { NW.Height.scaled(NWCardRowMetrics.minHeight) }
    /// Settings ▸ Keyboard: a changed shortcut's Reset, in Geist 12.
    static let shortcutResetSize: CGFloat = 12
    /// The page's explanation: 13.5/1.5.
    static let settingsExplanationLineHeight: CGFloat = 1.5
    /// Text fields in a row (the Settings boards' 240pt, a port 100).
    static let settingsFieldWidth: CGFloat = NWSettingsControlMetrics.fieldWidth
    /// A popup's least width in a sheet (the Controls board's); on a Settings page a popup fits
    /// its value.
    static let settingsPopupWidth: CGFloat = 200
    static let settingsPortFieldWidth: CGFloat = NWSettingsControlMetrics.portFieldWidth
    static let settingsFontPreviewWidth: CGFloat = 320

    // Wide pages (Instructions, Experiments): the page fills the detail area instead of the 720pt
    // column.
    static let settingsWideTop: CGFloat = 44
    static let settingsWideSides: CGFloat = 40
    static let settingsWideBottom: CGFloat = 32
    /// Between the header and each block under it.
    static let settingsWideBlockSpacing: CGFloat = 20
    /// The header's explanation wraps at this width.
    static let settingsWideHeaderWidth: CGFloat = 820

    // Settings ▸ Instructions: the editor beside a 330pt side column, 28pt apart.
    static let instructionsSideWidth: CGFloat = 330
    static let instructionsColumnSpacing: CGFloat = 28
    /// Between the side column's blocks.
    static let instructionsSideSpacing: CGFloat = 22
    /// A host chip: at least 34pt, a 13pt glyph, the name in mono 12.5, a 7pt dot, the state in
    /// Geist 11.
    static let instructionsChipHeight: CGFloat = 34
    static let instructionsChipGlyphSize: CGFloat = 13
    static let instructionsChipNameSize: CGFloat = 12.5
    static let instructionsChipDot: CGFloat = 7
    static let instructionsChipWordSize: CGFloat = 11
    /// File tabs: the name in mono 13 over a Geist 11.5 note, 22pt apart, a 2pt underline.
    static let instructionsTabSpacing: CGFloat = 22
    static let instructionsTabNameSize: CGFloat = 13
    static let instructionsTabNoteSize: CGFloat = 11.5
    static let instructionsTabUnderline: CGFloat = 2
    /// The editor card never shrinks below this, however short the window.
    static let instructionsEditorMinHeight: CGFloat = 180
    /// The card's header: the path in mono 12 (the comparison in Geist 12.5), "● edited" in
    /// Geist 11.5, Save's ⌘S in mono 10.5 at 60%.
    static let instructionsPathSize: CGFloat = 12
    static let instructionsCompareSize: CGFloat = 12.5
    static let instructionsEditedSize: CGFloat = 11.5
    static let instructionsShortcutSize: CGFloat = 10.5
    static let instructionsShortcutOpacity: CGFloat = 0.6
    /// The editor: mono 12.5 on 21pt lines, 10pt above and below, a 34pt gutter of mono 10.5
    /// numbers 12pt before the text.
    static let instructionsEditorTextSize: CGFloat = 12.5
    static let instructionsEditorLineHeight: CGFloat = 21
    static let instructionsEditorInset: CGFloat = 10
    static let instructionsGutterWidth: CGFloat = 34
    static let instructionsNumberSize: CGFloat = 10.5
    static let instructionsGutterGap: CGFloat = NW.Space.l
    /// The comparison's diff: mono 12 on 22pt lines, the 34pt gutter 8pt before a 14pt sign.
    static let instructionsDiffTextSize: CGFloat = 12
    static let instructionsDiffLineHeight: CGFloat = 22
    static let instructionsDiffSignWidth: CGFloat = 14
    /// How the agent reads them: small cards joined by a 10pt connector, 1.5pt wide and 17pt in; the
    /// number in a 16pt column, the title in mono 11.5 over a Geist 11 note.
    static let instructionsStepConnectorHeight: CGFloat = 10
    static let instructionsStepConnectorInset: CGFloat = 17
    static let instructionsStepConnectorWidth: CGFloat = 1.5
    static let instructionsStepNumberWidth: CGFloat = 16
    static let instructionsStepTitleSize: CGFloat = 11.5
    static let instructionsStepNoteSize: CGFloat = 11
    /// Files on each host: rows at least 48pt, a 14pt glyph, the name in mono 12.5 over the
    /// directory in mono 10.5; trailing, the detail in Geist 11.5 over an 11 note.
    static let instructionsHostRowMinHeight: CGFloat = 48
    static let instructionsHostGlyphSize: CGFloat = 14
    static let instructionsHostNameSize: CGFloat = 12.5
    static let instructionsHostDirectorySize: CGFloat = 10.5
    static let instructionsHostDetailSize: CGFloat = 11.5
    static let instructionsHostNoteSize: CGFloat = 11
    /// The other file's line: Geist 12.5/1.5.
    static let instructionsOtherFileSize: CGFloat = 12.5
    /// History: rows at least 30pt, the date in a 60pt mono column, Geist 12; the History
    /// popover's width and the most it grows before it scrolls.
    static let instructionsHistoryRowMinHeight: CGFloat = 30
    static let instructionsHistoryDateWidth: CGFloat = 60
    static let instructionsHistoryTextSize: CGFloat = 12
    static let instructionsHistoryPopoverWidth: CGFloat = 380
    static let instructionsHistoryPopoverMaxHeight: CGFloat = 340

    // Settings ▸ Skills (SettingsSkills): the installed skills beside a 280pt rail, 28pt apart,
    // 18pt under the header.
    static let skillsBlockSpacing: CGFloat = 18
    static let skillsColumnSpacing: CGFloat = 28
    static let skillsRailWidth: CGFloat = 280
    static let skillsRailSpacing: CGFloat = 22
    static let skillsExplanationWidth: CGFloat = 700
    static let skillsFilterWidth: CGFloat = 240
    /// The list and the rail's cards: 10pt corners.
    static let skillsCardRadius: CGFloat = 10
    /// The list's columns: a switch, the skill, its source, how it's used, when it changed, and
    /// the disclosure chevron, 16pt apart; its header 30pt tall, a row at least 54.
    static let skillsHeaderHeight: CGFloat = 30
    static let skillsRowMinHeight: CGFloat = 54
    static let skillsColumnGap: CGFloat = 16
    static let skillsSwitchColumn: CGFloat = 30
    static let skillsSourceColumn: CGFloat = 176
    static let skillsUseColumn: CGFloat = 84
    static let skillsUpdatedColumn: CGFloat = 60
    static let skillsChevronColumn: CGFloat = 14
    static let skillsLabelSize: CGFloat = 10.5
    static let skillsNameSize: CGFloat = 13
    static let skillsSummarySize: CGFloat = 12.5
    static let skillsMetaSize: CGFloat = 11.5
    static let skillsTagHeight: CGFloat = 20
    /// A row's detail: its blocks start under the skill's name (16 + 30 + 16), 14pt apart, its
    /// three columns 28pt apart.
    static let skillsDetailLeading: CGFloat = 62
    static let skillsDetailSpacing: CGFloat = 14
    static let skillsDetailColumnSpacing: CGFloat = 28
    static let skillsDetailTextSize: CGFloat = 12
    /// The rail: 12.5/1.55 prose, notes 12/1.45, and the In every prompt card's 13pt title.
    static let skillsRailTextSize: CGFloat = 12.5
    static let skillsRailLineHeight: CGFloat = 1.55
    static let skillsNoteSize: CGFloat = 12
    static let skillsNoteLineHeight: CGFloat = 1.45
    static let skillsOptionTitleSize: CGFloat = 13

    // Browse skills.sh and Add from repo (SettingsSkillsBrowse, SettingsSkillsSearch,
    // SettingsSkillsRepo): a 1060 × 812 sheet, its list 560pt wide beside the preview.
    static let skillsSheetWidth: CGFloat = 1060
    static let skillsSheetHeight: CGFloat = 812
    static let skillsSheetMinWidth: CGFloat = 860
    static let skillsSheetMinHeight: CGFloat = 600
    static let skillsSheetListWidth: CGFloat = 560
    static let skillsSheetSides: CGFloat = 22
    static let skillsSheetTitleSize: CGFloat = 17
    static let skillsSheetCloseSize: CGFloat = 28
    static let skillsSearchHeight: CGFloat = 38
    static let skillsSearchTextSize: CGFloat = 14
    static let skillsTopicHeight: CGFloat = 26
    static let skillsResultMinHeight: CGFloat = 58
    static let skillsResultRankWidth: CGFloat = 22
    static let skillsResultInstallsWidth: CGFloat = 96
    static let skillsProgressWidth: CGFloat = 64
    static let skillsProgressHeight: CGFloat = 3
    static let skillsPreviewNameSize: CGFloat = 18
    static let skillsPreviewTextSize: CGFloat = 13
    static let skillsPreviewHeaderHeight: CGFloat = 34
    static let skillsPreviewLineHeight: CGFloat = 20
    static let skillsPreviewGutter: CGFloat = 34
    static let skillsPreviewNumberSize: CGFloat = 10.5
    static let skillsPreviewFade: CGFloat = 56
    /// The SKILL.md preview's height: Browse's, Search's, and Add from repo's.
    static let skillsPreviewBrowseHeight: CGFloat = 240
    static let skillsPreviewSearchHeight: CGFloat = 280
    static let skillsPreviewRepoHeight: CGFloat = 340
    static let skillsPickerRowHeight: CGFloat = 34
    static let skillsPickerNameWidth: CGFloat = 168
    static let skillsFooterHeight: CGFloat = 60
    static let skillsRepoFieldHeight: CGFloat = 38
    static let skillsRepoFieldTextSize: CGFloat = 13.5

    // Settings ▸ Experiments: the experiments beside a 320pt side column, 32pt apart.
    static let experimentsSideWidth: CGFloat = 320
    static let experimentsColumnSpacing: CGFloat = 32
    /// Between the main column's blocks, and the side column's.
    static let experimentsBlockSpacing: CGFloat = 22
    static let experimentsSideSpacing: CGFloat = 24
    /// An experiment's card: a 36pt tile holding an 18pt glyph, the name in Geist 14/600 beside a
    /// mono 10.5 tag 18pt tall, and a 12.5/1.5 description at most 620pt wide.
    static let experimentTileSize: CGFloat = 36
    static let experimentGlyphSize: CGFloat = 18
    static let experimentNameSize: CGFloat = 14
    static let experimentTagSize: CGFloat = 10.5
    static let experimentTagHeight: CGFloat = 18
    static let experimentDescriptionSize: CGFloat = 12.5
    static let experimentDescriptionLineHeight: CGFloat = 1.5
    static let experimentDescriptionWidth: CGFloat = 620
    /// Its options: rows whose content is at least 48pt (68 with their padding), a 13/500 title over a 12/1.45 note, checkboxes 14pt apart.
    static let experimentOptionMinHeight: CGFloat = 48
    static let experimentOptionTitleSize: CGFloat = 13
    static let experimentOptionNoteSize: CGFloat = 12
    static let experimentOptionNoteLineHeight: CGFloat = 1.45
    static let experimentCheckboxSpacing: CGFloat = 14
    /// A suggestion: a 13pt source glyph, the name in 12.5/600, where and when in 12, a 24pt
    /// target chip in Geist 11.5 with 11pt glyphs and a 9pt chevron, the line in mono 12.5/1.5, the
    /// reason in 12/1.45.
    static let suggestionGlyphSize: CGFloat = 13
    static let suggestionNameSize: CGFloat = 12.5
    static let suggestionOriginSize: CGFloat = 12
    static let suggestionTargetHeight: CGFloat = 24
    static let suggestionTargetSize: CGFloat = 11.5
    static let suggestionTargetGlyphSize: CGFloat = 11
    static let suggestionChevronSize: CGFloat = 9
    static let suggestionLineSize: CGFloat = 12.5
    static let suggestionLineHeight: CGFloat = 1.5
    static let suggestionReasonSize: CGFloat = 12
    static let suggestionReasonLineHeight: CGFloat = 1.45
    /// How it works: each step's number in an 18pt ring, the sentence in 12.5/1.5.
    static let experimentStepRing: CGFloat = 18
    static let experimentStepTextSize: CGFloat = 12.5
    /// Added from suggestions: rows at least 44pt, the line in 12.5 over an 11 note.
    static let addedRowMinHeight: CGFloat = 44
    static let addedLineSize: CGFloat = 12.5
    static let addedNoteSize: CGFloat = 11

    // Sheets
    static let renameSheetWidth: CGFloat = 420
    static let confirmSheetWideWidth: CGFloat = 520
    static let newAgentSheetWidth: CGFloat = 560
    static let newWorktreeSheetWidth: CGFloat = 520
    static let finalizeSheetWidth: CGFloat = 560
    /// The review's Commit… sheet, and the most its file list grows before it scrolls.
    static let commitSheetWidth: CGFloat = 520
    static let commitFileListMaxHeight: CGFloat = 232
    static let remoteWorktreeSheetWidth: CGFloat = 620
    /// A remote automation's details and runs, and how tall its run list grows before it scrolls.
    static let automationSheetWidth: CGFloat = 560
    static let automationRunsMaxHeight: CGFloat = 200
    static let directoryPickerWidth: CGFloat = 480
    static let directoryListHeight: CGFloat = 260
    static let promptEditorHeight: CGFloat = 96
    static let descriptionEditorHeight: CGFloat = 72
    static let baseFieldMaxWidth: CGFloat = 200
    static let identityNameFieldMaxWidth: CGFloat = 140
    static let modelSuggestionsMaxHeight: CGFloat = 260
    static let modelSuggestionsVisible = 12
    /// A spinner beside a sheet's caption ("Generating…").
    static let sheetSpinner: CGFloat = 11
    /// The tool-output sheet ("… n more lines", Open Output): its minimum and ideal size.
    static let toolOutputMinWidth: CGFloat = 720
    static let toolOutputIdealWidth: CGFloat = 860
    static let toolOutputMinHeight: CGFloat = 480
    static let toolOutputIdealHeight: CGFloat = 620
}
