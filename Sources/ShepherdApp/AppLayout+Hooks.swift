import SwiftUI
import ShepherdUI

/// Settings › Hooks, its sheets, a space's Hooks tab and the hook rows in a thread (Hooks* and
/// HookThreadScene boards).
extension AppLayout {
    /// The event rail: 210pt, rows 30pt.
    static let hooksRailWidth: CGFloat = 210
    static let hooksRailRowHeight: CGFloat = 30
    /// A hook row: at least 46pt; a file row 42pt; a reader row 52pt.
    static let hooksRowHeight: CGFloat = 46
    static let hooksFileRowHeight: CGFloat = 42
    static let hooksReaderRowHeight: CGFloat = 52
    /// The source column of a hook row (240pt on the page, 160pt in a space's tab).
    static let hooksSourceWidth: CGFloat = 240
    static let hooksSpaceSourceWidth: CGFloat = 160
    /// The Sources table's columns: format 84, count 64, state 260, action 92.
    static let hooksFormatWidth: CGFloat = 84
    static let hooksCountWidth: CGFloat = 64
    static let hooksStateWidth: CGFloat = 260
    static let hooksActionWidth: CGFloat = 92
    /// A matcher chip: 20pt tall.
    static let hooksChipHeight: CGFloat = 20
    /// The dimmed rows of files not read.
    static let hooksOffOpacity: Double = 0.6
    /// The state dot in a file row.
    static let hooksDotSize: CGFloat = 6
    /// The Edit sheet: 640pt wide, 840pt tall.
    static let hooksSheetWidth: CGFloat = 600
    static let hooksSheetHeight: CGFloat = 700
    /// The sheets' close button: a 26pt circle.
    static let hooksCloseSize: CGFloat = 26
    /// The command editor's height and the time limit field's width.
    static let hooksCommandHeight: CGFloat = 52
    static let hooksTimeoutWidth: CGFloat = 64
    static let hooksTimeoutColumn: CGFloat = 120
    static let hooksJSONHeight: CGFloat = 520
    /// A test's Output stream scrolls past this height.
    static let hooksOutputHeight: CGFloat = 200

    // Thread rows (HookThreadScene)
    /// The row's glyph: 13pt in a 13pt column, 8pt before the verb.
    static let hookGlyphSize: CGFloat = 13
    static let hookRowHeight: CGFloat = 26
    /// The box and the link sit under the verb: past the glyph and its gap.
    static let hookBoxIndent: CGFloat = 13 + SH.Space.m
    /// The proposal card's key column.
    static let hookCardKeyWidth: CGFloat = 96
    /// The output box under a hook row: mono 12 on 19pt lines.
    static let hookBoxSize: CGFloat = 12
    static let hookBoxLine: CGFloat = 19.0 / 12
    /// The proposal card (`hk-card`): radius 12, 14pt in; the title 10 over and under, a fact's row 3, the test 10 under the
    /// facts and 7 in its tile, the foot 6 under that with 10 over and 12 under.
    static let hookCardRadius: CGFloat = 12
    static let hookCardInset: CGFloat = 14
    static let hookCardHeaderVertical: CGFloat = 10
    static let hookCardRowVertical: CGFloat = 3
    static let hookCardTestTop: CGFloat = 10
    static let hookCardTestVertical: CGFloat = 7
    static let hookCardFooterTop: CGFloat = 16
    static let hookCardFooterBottom: CGFloat = 12
    static let hookCardScopeGap: CGFloat = 6
    static let hookCardChevron: CGFloat = 9
    /// The ask card (`ask`): radius 14, 14 over, 8 in, 10 under; a 7pt dot before a 14/21 title; blocks 10 apart.
    static let hookAskRadius: CGFloat = 14
    static let hookAskTop: CGFloat = 14
    static let hookAskSides: CGFloat = 8
    static let hookAskBottom: CGFloat = 10
    static let hookAskInset: CGFloat = 12
    static let hookAskTitleTrailing: CGFloat = 10
    static let hookAskGap: CGFloat = 10
    static let hookAskDot: CGFloat = 7
    static let hookAskDotTop: CGFloat = 7
    static let hookAskTitleSize: CGFloat = 14
    static let hookAskTitleLine: CGFloat = 21.0 / 14
    static let hookAskBlockTop: CGFloat = 10
    static let hookAskFootTop: CGFloat = 6
    static let hookAskFootInset: CGFloat = 4
    static let hookAskButtonGap: CGFloat = 6
    static let hookAskButtonHeight: CGFloat = 30
    static let hookAskAllowPadding: CGFloat = 14
    static let hookAskDenyPadding: CGFloat = 12
    /// The most a consent prompt's command takes before it scrolls (about ten code lines).
    static let hookCommandMaxHeight: CGFloat = 180
}
