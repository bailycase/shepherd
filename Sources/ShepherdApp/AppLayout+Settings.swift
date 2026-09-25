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
    /// Density-scaled.
    @MainActor static var settingsRowMinHeight: CGFloat { NW.Height.scaled(52) }
    /// Text fields and popups in a row (the Controls board's field and popup widths).
    static let settingsFieldWidth: CGFloat = 220
    static let settingsPopupWidth: CGFloat = 200
    static let settingsPortFieldWidth: CGFloat = 88
    static let settingsFontPreviewWidth: CGFloat = 320

    // Wide pages (Instructions): the page fills the detail area instead of the 720pt column.
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
    /// How pi reads them: small cards joined by a 10pt connector, 1.5pt wide and 17pt in; the
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
