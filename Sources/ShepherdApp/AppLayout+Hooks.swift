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
    /// A matcher chip and a badge: 20pt and 18pt tall.
    static let hooksChipHeight: CGFloat = 20
    static let hooksBadgeHeight: CGFloat = 18
    /// The dimmed rows of hooks waiting for review and files not read.
    static let hooksPendingOpacity: Double = 0.72
    static let hooksOffOpacity: Double = 0.6
    /// The state dot in a file row.
    static let hooksDotSize: CGFloat = 6
    /// The Edit and Review sheets: 640pt wide; Edit is 840pt tall.
    static let hooksSheetWidth: CGFloat = 640
    static let hooksSheetHeight: CGFloat = 840
    /// The sheets' close button: a 26pt circle.
    static let hooksCloseSize: CGFloat = 26
    /// Review's key column and its checkbox.
    static let hooksKeyWidth: CGFloat = 96
    static let hooksCheckSize: CGFloat = 16
    static let hooksReviewHeadHeight: CGFloat = 44
    /// The command editor's height and the time limit field's width.
    static let hooksCommandHeight: CGFloat = 52
    static let hooksTimeoutWidth: CGFloat = 64
    static let hooksTimeoutColumn: CGFloat = 120
    static let hooksJSONHeight: CGFloat = 520

    // Thread rows (HookThreadScene)
    /// The row's glyph: 13pt in a 13pt column, 8pt before the verb.
    static let hookGlyphSize: CGFloat = 13
    static let hookRowHeight: CGFloat = 26
    /// The box and the link sit under the verb: past the glyph and its gap.
    static let hookBoxIndent: CGFloat = 13 + SH.Space.m
    /// The proposal card's key column.
    static let hookCardKeyWidth: CGFloat = 96
    /// The composer's hook glyph and its review dot.
    static let hookComposerDot: CGFloat = 6
}
