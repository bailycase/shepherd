import SwiftUI

/// The Design tool's own measures (DZCanvas, NavDesigns, NWDesignTool), as the boards draw them.
/// Sizes the boards give off the type ramp (13.5, 12.5, 11.5, 10.5) are set with `Font.nwSans`
/// and `Font.nwMono`.
public enum NWDesignMetrics {
    // The header and the chat pane
    /// The breadcrumb's nib and words.
    public static let headerGlyph: CGFloat = 14
    public static let headerTextSize: CGFloat = 13
    /// The chat pane's tabs: a 40pt row, 18pt in, tabs 18pt apart in 12.5, counts in mono 10,
    /// the current one over a 2pt underline.
    public static let paneTabsHeight: CGFloat = 40
    public static let paneTabsLeading: CGFloat = 18
    public static let paneTabSpacing: CGFloat = 18
    public static let paneTabTextSize: CGFloat = 12.5
    public static let paneTabCountSize: CGFloat = 10
    public static let paneTabUnderline: CGFloat = 2

    // The canvas
    /// The canvas's dots: 1px, every 22pt.
    public static let gridSpacing: CGFloat = 22
    /// A board's label: its row, and the room between it and the frame (24pt from the frame's
    /// top edge to the label's).
    public static let labelHeight: CGFloat = 16
    public static let labelGap: CGFloat = 8
    /// Between a board's name and its size in the label.
    public static let labelSpacing: CGFloat = NW.Space.m
    public static let labelSize: CGFloat = 12
    public static let labelSizeTextSize: CGFloat = 10.5
    /// A label is never narrower than this, whatever its board's width on screen.
    public static let labelMinWidth: CGFloat = 160
    /// A board frame's corners.
    public static let frameRadius: CGFloat = NW.Radius.xs
    /// The selected board's `running` ring, outside the frame.
    public static let ringWidth: CGFloat = 2
    /// The frame's drop shadow (the board's 0 12 32).
    public static let frameShadowRadius: CGFloat = 16
    public static let frameShadowY: CGFloat = 12
    /// Where a fitted canvas puts the boards' top-leading corner (44pt in, 52pt down).
    public static let fitLeading: CGFloat = 44
    public static let fitTop: CGFloat = 52
    /// The canvas toolbar: 16pt from the bottom-leading corner, a 38pt bar (4pt padding, radius
    /// 12), 30pt circle tools with 15pt glyphs, an 18pt divider with 4pt margins, the zoom in mono 11.
    public static let toolbarInset: CGFloat = NW.Space.xl
    public static let toolbarHeight: CGFloat = 38
    public static let toolbarPadding: CGFloat = NW.Space.xs
    public static let toolbarRadius: CGFloat = NW.Radius.l
    public static let toolSize: CGFloat = 30
    public static let toolGlyph: CGFloat = 15
    public static let toolbarDividerHeight: CGFloat = 18
    public static let toolbarDividerMargin: CGFloat = NW.Space.xs
    public static let zoomTextSize: CGFloat = 11

    // A design card (NavDesigns)
    public static let cardRadius: CGFloat = 10
    public static let cardThumbnailHeight: CGFloat = 172
    /// The thumbnail's dots, every 16pt.
    public static let cardGridSpacing: CGFloat = 16
    /// The first board in the thumbnail: 256×160 for a desktop board, 74×160 for a phone.
    public static let cardDesktopBoard = CGSize(width: 256, height: 160)
    public static let cardPhoneBoard = CGSize(width: 74, height: 160)
    public static let cardPaddingVertical: CGFloat = NW.Space.l
    public static let cardPaddingHorizontal: CGFloat = 14
    public static let cardLineSpacing: CGFloat = 5
    public static let cardNameSize: CGFloat = 13.5
    public static let cardMetaSize: CGFloat = 11.5
    public static let cardEditedSize: CGFloat = 11
    /// The selected card's `textPrimary` ring.
    public static let cardRingWidth: CGFloat = 2

    // New design's starting points
    public static let startGlyph: CGFloat = 13
    public static let startTitleSize: CGFloat = 12
    public static let startLineSize: CGFloat = 12.5
    public static let startNoteSize: CGFloat = 11

    // A design system card and chip
    public static let systemCardSpacing: CGFloat = NW.Space.l
    public static let systemNameSize: CGFloat = 12.5
    public static let systemSourceSize: CGFloat = 11.5
    public static let systemCountSize: CGFloat = 11
    public static let swatchSize: CGFloat = 14
    public static let swatchSpacing: CGFloat = 3
    public static let chipHeight: CGFloat = 24
    public static let chipPadding: CGFloat = NW.Space.m
    public static let chipRadius: CGFloat = NW.Radius.s
    public static let chipSwatch: CGFloat = 8
    public static let chipSwatchRadius: CGFloat = 2
    public static let chipSwatchSpacing: CGFloat = NW.Space.xxs
    public static let chipTextSize: CGFloat = 11.5
}
