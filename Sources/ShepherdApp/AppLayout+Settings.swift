import SwiftUI
import ShepherdUI

/// Settings and the sheets: the in-window Settings surface (a 232pt nav beside a 720pt column)
/// and the size of every modal.
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
