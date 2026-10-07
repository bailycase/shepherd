import SwiftUI
import ShepherdUI

extension AppLayout {
    static let subagentSettingsGap: CGFloat = 22
    static let subagentFilterWidth: CGFloat = 302
    static let subagentFinderSize: CGFloat = 11.5
    static let subagentFinderVisualHeight: CGFloat = 22
    static let subagentToolbarGap: CGFloat = 10
    static let subagentActionPadding: CGFloat = 14
    static let subagentActionRadius: CGFloat = 8
    static let subagentActionSize: CGFloat = 13
    static let subagentRowHeight: CGFloat = 60
    static let subagentRowContentHeight: CGFloat = 56
    static let subagentRowPadding: CGFloat = 14
    static let subagentRowNameSize: CGFloat = 13
    static let subagentDescriptionSize: CGFloat = 12.5
    static let subagentMetaSize: CGFloat = 11
    static let subagentBadgePadding: CGFloat = 5
    static let subagentBadgeSize: CGFloat = 10.5
    static let subagentGlyphTile: CGFloat = 28
    static let subagentGlyphRadius: CGFloat = 7
    static let subagentGlyphSize: CGFloat = 14
    static let subagentChevronSize: CGFloat = 12
    static let subagentSectionSize: CGFloat = 11
    static let subagentSectionTracking: CGFloat = 0.06
    static let subagentRowLineExtra: CGFloat = 3

    // SubagentEdit board: the form behind a subagent's row.
    /// 18 between the header and the form, 22 between its two columns, the form's column 400 wide.
    static let subagentEditGap: CGFloat = 18
    static let subagentEditColumnGap: CGFloat = 22
    static let subagentEditFormWidth: CGFloat = 400
    static let subagentEditInstructionsMinWidth: CGFloat = 280
    static let subagentEditNarrowInstructionsHeight: CGFloat = 360
    static let subagentEditFieldGap: CGFloat = 16
    static let subagentEditLabelGap: CGFloat = 6
    static let subagentEditToolsGap: CGFloat = 8
    static let subagentEditLabelSize: CGFloat = 12
    static let subagentEditHintSize: CGFloat = 11.5
    /// The board's `/` is unstyled text, so it takes the page's default 16.
    static let subagentEditSlashSize: CGFloat = 16
    /// Header buttons: 30 high, 12.5 type, radius 7, 12 in (Save 14).
    static let subagentEditButtonHeight: CGFloat = 30
    static let subagentEditButtonSize: CGFloat = 12.5
    static let subagentEditButtonPadding: CGFloat = 12
    static let subagentEditSavePadding: CGFloat = 14
    static let subagentEditButtonRadius: CGFloat = 7
    static let subagentEditPathRadius: CGFloat = 5
    static let subagentEditPathPadding: CGFloat = 7
    /// Fields and popups: 32 high, radius 8, 13 type, 10 in. The description is 58 high from 8 below its top.
    static let subagentEditFieldHeight: CGFloat = 32
    static let subagentEditFieldRadius: CGFloat = 8
    static let subagentEditFieldSize: CGFloat = 13
    static let subagentEditFieldPadding: CGFloat = 10
    static let subagentEditDescriptionHeight: CGFloat = 58
    static let subagentEditDescriptionTop: CGFloat = 8
    static let subagentEditDescriptionLineExtra: CGFloat = 3
    static let subagentEditPopupGap: CGFloat = 12
    static let subagentEditPopupChevron: CGFloat = 11
    /// Tool chips: 26 high, radius 6, mono 12, 10 in, 6 apart.
    static let subagentEditChipHeight: CGFloat = 26
    static let subagentEditChipRadius: CGFloat = 6
    static let subagentEditChipSize: CGFloat = 12
    static let subagentEditChipPadding: CGFloat = 10
    static let subagentEditChipGap: CGFloat = 6
    /// Switches: 32 × 18, a 14pt knob 2 in, 10 before the label (12.5) and its note (11.5).
    static let subagentEditSwitchWidth: CGFloat = 32
    static let subagentEditSwitchHeight: CGFloat = 18
    static let subagentEditKnob: CGFloat = 14
    static let subagentEditKnobInset: CGFloat = 2
    static let subagentEditSwitchGap: CGFloat = 10
    static let subagentEditSwitchLabelSize: CGFloat = 12.5
    static let subagentEditSwitchesTop: CGFloat = 4
    /// The instructions pane: 1.65 lines of mono 12.5, 14 in and (the project editor's) 12 above and below.
    static let subagentInstructionLineHeight: CGFloat = 20.625
    static let subagentInstructionInset: CGFloat = 14
    static let subagentEditNoteLineExtra: CGFloat = 3
    static let subagentEditNoteSize: CGFloat = 11.5
    static let subagentEditCountSize: CGFloat = 11
}
