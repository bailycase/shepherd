import SwiftUI
import ShepherdUI

/// Settings' own measures (home track): the boards' MobileSettings, MobileInstructions,
/// MobileInstructionsEdit, MobileSkills, MobileExperiments and iPadSettingsInstructions.
extension MobileLayout {
    // MARK: The iPad's list beside the page

    /// The list column.
    static let settingsListWidth: CGFloat = 300
    /// Around the list's rows.
    static let settingsListInset: CGFloat = SH.Space.m + SH.Space.xxs
    /// Between the list's rows.
    static let settingsListRowSpacing: CGFloat = SH.Space.xxs
    /// A list item (iPadSettingsInstructions: 40pt), and the gap above a group label or group.
    static let settingsListItemHeight: CGFloat = 40
    static let settingsListGroupGap: CGFloat = SH.Space.xl
    /// A list row's selection.
    static let settingsListRowRadius: CGFloat = 10
    /// Above a page shown beside the list, under the bar.
    static let settingsColumnTop: CGFloat = SH.Space.xl

    // MARK: The boards' parts (SettingsParts)

    /// A card's corners (the boards' 16pt).
    static let settingsCardRadius: CGFloat = SH.Radius.xxl
    /// A row: 52pt at least, 16pt in at the sides, 10pt above and below its text.
    static let settingsRowHeight: CGFloat = 52
    static let settingsRowInset: CGFloat = SH.Space.xl
    static let settingsRowPadding: CGFloat = SH.Space.m + SH.Space.xxs
    /// The column a row's leading glyph sits in, and that glyph.
    static let settingsLeadingWidth: CGFloat = 28
    static let settingsGlyphSize: CGFloat = 16
    /// A row's chevron.
    static let settingsChevronSize: CGFloat = 14
    /// A caption, a note, a value, a lead: the boards' 13pt.
    static let settingsCaptionSize: CGFloat = 13
    /// The switch: 52×32 with a 28pt knob.
    static let settingsSwitchWidth: CGFloat = 52
    static let settingsSwitchHeight: CGFloat = 32
    static let settingsSwitchInset: CGFloat = SH.Space.xxs
    /// A pill button: 36pt, its text 14pt, 14pt in.
    static let settingsPillHeight: CGFloat = 36
    static let settingsPillTextSize: CGFloat = 14
    static let settingsPillInset: CGFloat = 14
    /// The page's primary action: 50pt.
    static let settingsPrimaryHeight: CGFloat = 50
    /// The search capsule: 40pt, 14pt in.
    static let settingsSearchHeight: CGFloat = 40
    static let settingsSearchInset: CGFloat = 14
    /// The segmented pill: 36pt with 3pt around its segments.
    static let settingsSegmentHeight: CGFloat = 36
    static let settingsSegmentInset: CGFloat = 3
    /// The page title's tracking (-.02em), and the iPad bar: 52pt, its title 18pt, 24pt in on the list and 32 on a page.
    static let settingsHeadingTracking: CGFloat = 0.02
    /// The lead sits 10pt under the title (the boards' -10pt margin over the section gap).
    static let settingsLeadPull: CGFloat = SH.Space.l - SH.Space.xxs
    static let settingsPadBarHeight: CGFloat = 52
    static let settingsPadBarTitleSize: CGFloat = 18
    static let settingsPadBarInset: CGFloat = SH.Space.xl + SH.Space.m
    static let settingsPadPageInset: CGFloat = SH.Space.xxxl
    /// Between a page's groups.
    static let settingsSectionSpacing: CGFloat = SH.Space.xl + SH.Space.xs

    // MARK: Rows

    /// A row's note (the boards' 13 on 18pt lines), its `code` a step smaller.
    static let settingsNoteSize: CGFloat = 13
    static let settingsNoteCodeSize: CGFloat = 12
    static let settingsNoteLineHeight: CGFloat = 1.38
    /// A menu's value before it truncates.
    static let settingsMenuMaxWidth: CGFloat = 150

    // MARK: Instructions

    /// A file's row (a name over its note).
    static let instructionsFileRowHeight: CGFloat = 64
    /// How many earlier saves of each file the phone's History lists.
    static let instructionsHistoryPerFile = 2
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
    static let instructionsGutterGap: CGFloat = SH.Space.m
    /// Above the first line and below the last.
    static let instructionsEditorInset: CGFloat = SH.Space.m + SH.Space.xxs
    /// Dynamic Type grows the editor's text this far, so a line still holds a sentence.
    static let instructionsMaximumTextSize: CGFloat = 22
    /// The iPad's editor at its shortest.
    static let instructionsEditorMinHeight: CGFloat = 250
    /// The iPad page's sides, and between its blocks.
    static let instructionsPadSides: CGFloat = 20
    static let instructionsPadSpacing: CGFloat = SH.Space.xl
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

    /// The space overview shows the first few lines without taking over the page.
    static let spaceInlineEditorHeight = SH.Height.touch * 3

    // MARK: Skills

    /// A skill's row (MobileSkills): its name in sans 15 bold over its description at 12.5, 3pt
    /// apart, at least 58pt.
    static let skillRowHeight: CGFloat = 60
    static let skillNameSize: CGFloat = 15
    /// The chevron's column at a skill row's end (the row opens the skill).
    static let skillChevronSlot: CGFloat = SH.Space.xl
    static let skillSummarySize: CGFloat = 13
    static let skillLineSpacing: CGFloat = 3
    /// The switch at a row's end (`SHSwitch` is 30pt wide), kept clear of the row's text.
    static let skillSwitchSlot: CGFloat = 52
    /// A search result's status at its end: Install, Installed, Update, or "1 of 3 hosts".
    static let skillStatusSlot: CGFloat = 96
    /// A skill's name over its detail or its preview.
    static let skillTitleSize: CGFloat = 17
    /// A previewed SKILL.md: its first 60 lines in mono 12 on 19pt lines, numbered in a 28pt
    /// column, under a 36pt header.
    static let skillPreviewLines = 60
    static let skillPreviewTextSize: CGFloat = 12
    static let skillPreviewLineHeight: CGFloat = 19
    static let skillPreviewGutter: CGFloat = 28
    static let skillPreviewHeaderHeight: CGFloat = 36
    /// Add from repo's field.
    static let skillRepoFieldHeight: CGFloat = 44

    // MARK: Hooks

    /// A hook's row on the phone (MobileHooks): two lines of command over its matcher and source.
    static let hookRowHeight: CGFloat = 64
    /// A hook's row on the iPad and a file's row in Sources (iPadHooks, MobileHookSources).
    static let hookCompactRowHeight: CGFloat = 56
    /// Sources' row on the phone, and a field row of the edit form.
    static let hookLinkRowHeight: CGFloat = 52
    static let hookFieldRowHeight: CGFloat = 48
    /// The matcher chip: mono 11, 20pt on the phone, 22 on the iPad and in Matches, its dashes
    /// when it matches everything.
    static let hookChipTextSize: CGFloat = 11
    static let hookChipHeight: CGFloat = 20
    static let hookPadChipHeight: CGFloat = 22
    static let hookChipDash: [CGFloat] = [3, 2]
    /// The event's name beside its label: mono 11.
    static let hookEventSize: CGFloat = 11
    /// A list head: 13 semibold.
    static let hookHeadSize: CGFloat = 13
    /// The host's hook count and the Sources row's file count.
    static let hookCountSize: CGFloat = 13
    /// The iPad row's source column, and Sources' format and state columns.
    static let hookPadSourceWidth: CGFloat = 170
    static let hookPadFormatWidth: CGFloat = 110
    static let hookPadStateWidth: CGFloat = 220
    /// The state column never narrower than "Loaded · 12 hooks"; a long reason wraps.
    static let hookPadStateMinWidth: CGFloat = 140
    /// The edit form: its labels' column (When, Saved in, Matcher; also the time limit's), mono 14
    /// in its fields, the command at least 72pt.
    static let hookLabelWidth: CGFloat = 96
    /// A test's Output stream scrolls past this height.
    static let hookOutputHeight: CGFloat = 200
    static let hookFieldMonoSize: CGFloat = 14
    static let hookCommandMinHeight: CGFloat = 72
    /// The JSON pane: mono 12 at least 240pt.
    static let hookJSONSize: CGFloat = 12
    static let hookJSONMinHeight: CGFloat = 240
    /// Form | JSON and Hooks | Sources: a 9pt track around 7pt segments, 32pt on the phone, 36 on the iPad.
    static let hookSegmentTrackRadius: CGFloat = 9
    static let hookSegmentRadius: CGFloat = 7
    static let hookSegmentHeight: CGFloat = 32
    static let hookPadSegmentHeight: CGFloat = 36
    static let hookSegmentTextSize: CGFloat = 13
    static let hookPadSegmentTextSize: CGFloat = 14
    /// A file's state dot.
    static let hookDot: CGFloat = 6
    /// Hooks | Sources beside the iPad's list.
    /// A form field's text in the edit sheet.
    static let hookFieldTextSize: CGFloat = 14
    static let hookPadSegmentsWidth: CGFloat = 190
}
