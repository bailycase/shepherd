import SwiftUI
import ShepherdUI

/// Settings' own measures (home track): the boards' MobileSettings, MobileInstructions,
/// MobileInstructionsEdit, MobileExperiments and iPadSettingsInstructions.
extension MobileLayout {
    // MARK: The iPad's list beside the page

    /// The list column.
    static let settingsListWidth: CGFloat = 300
    /// Around the list's rows.
    static let settingsListInset: CGFloat = NW.Space.m + NW.Space.xxs
    /// Between the list's rows.
    static let settingsListRowSpacing: CGFloat = NW.Space.xxs
    /// A list row's selection.
    static let settingsListRowRadius: CGFloat = 10
    /// Above a page shown beside the list, under the bar.
    static let settingsColumnTop: CGFloat = NW.Space.xl

    // MARK: Rows

    /// A row's note (12.5/1.45), its `code` a step smaller.
    static let settingsNoteSize: CGFloat = 12.5
    static let settingsNoteCodeSize: CGFloat = 11.5
    static let settingsNoteLineHeight: CGFloat = 1.45
    /// A menu's value before it truncates.
    static let settingsMenuMaxWidth: CGFloat = 200
    /// About's icon: the crook on its tile.
    static let settingsAboutTile: CGFloat = 24
    static let settingsAboutCrook: CGFloat = 14

    // MARK: Instructions

    /// A file's row (a name over its note).
    static let instructionsFileRowHeight: CGFloat = 64
    /// A host's row.
    static let instructionsHostRowHeight: CGFloat = 52
    /// The phone's editor: mono 13 on 21pt lines.
    static let instructionsPhoneTextSize: CGFloat = 13
    static let instructionsPhoneLineHeight: CGFloat = 21
    static let instructionsPhoneGutter: CGFloat = 28
    /// The iPad's editor: mono 14 on 26pt lines.
    static let instructionsPadTextSize: CGFloat = 14
    static let instructionsPadLineHeight: CGFloat = 26
    static let instructionsPadGutter: CGFloat = 34
    /// Line numbers, in the gutter.
    static let instructionsNumberSize: CGFloat = 10.5
    /// Between the numbers and the text, and after the text.
    static let instructionsGutterGap: CGFloat = NW.Space.m
    /// Above the first line and below the last.
    static let instructionsEditorInset: CGFloat = NW.Space.m + NW.Space.xxs
    /// Dynamic Type grows the editor's text this far, so a line still holds a sentence.
    static let instructionsMaximumTextSize: CGFloat = 22
    /// The iPad's editor at its shortest.
    static let instructionsEditorMinHeight: CGFloat = 250
    /// The iPad page's sides, and between its blocks.
    static let instructionsPadSides: CGFloat = 20
    static let instructionsPadSpacing: CGFloat = NW.Space.xl
    /// Every host | Per host: a 300pt track at radius 9, 30pt segments at radius 7, 13pt.
    static let instructionsScopeWidth: CGFloat = 300
    static let instructionsScopeRadius: CGFloat = 9
    static let instructionsScopeSegmentHeight: CGFloat = 30
    static let instructionsScopeSegmentRadius: CGFloat = 7
    static let instructionsScopeTextSize: CGFloat = 13
    /// The files as tabs: 22pt apart, names in mono 13, a 2pt underline.
    static let instructionsTabSpacing: CGFloat = 22
    static let instructionsTabTextSize: CGFloat = 13
    static let instructionsTabUnderline: CGFloat = 2
    /// History's popover.
    static let instructionsHistoryWidth: CGFloat = 360
    static let instructionsHistoryMaxHeight: CGFloat = 440

    // MARK: Experiments

    /// The experiment's tile.
    static let experimentTile: CGFloat = 30
    /// A source it learns from.
    static let experimentSourceRowHeight: CGFloat = 46
    /// A waiting line, in mono 13.
    static let suggestionLineHeight: CGFloat = 1.45
}
