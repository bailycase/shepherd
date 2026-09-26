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
    /// A label is never narrower than this, whatever its board's width on screen, unless the next
    /// board along the row comes sooner.
    public static let labelMinWidth: CGFloat = 160
    /// Where the room above a board is short (rows closer than a label at a low zoom), the label
    /// moves down toward its frame, keeping at least this gap; with less room it isn't drawn.
    public static let labelMinGap: CGFloat = NW.Space.xxs
    /// A board frame's corners.
    public static let frameRadius: CGFloat = NW.Radius.xs
    /// The selected board's `running` ring, outside the frame.
    public static let ringWidth: CGFloat = 2
    /// The frame's drop shadow (the board's 0 12 32).
    public static let frameShadowRadius: CGFloat = 16
    public static let frameShadowY: CGFloat = 12
    /// A selected element (NWSelectionRing; NWDesignTool, DZTweak): a 1.5pt `running` ring over
    /// a `runningTint` fill, 8pt square handles on its corners (a 1.5pt `running` line, radius 2),
    /// and a tag 4pt above its top-leading corner: 18pt, 6pt padding, radius 4, mono 10.5. A
    /// hovered element wears the ring alone.
    public static let elementRingWidth: CGFloat = 1.5
    public static let handleSize: CGFloat = 8
    public static let handleLineWidth: CGFloat = 1.5
    public static let handleRadius: CGFloat = 2
    public static let tagHeight: CGFloat = 18
    public static let tagPadding: CGFloat = NW.Space.s
    public static let tagRadius: CGFloat = NW.Radius.xs
    public static let tagGap: CGFloat = NW.Space.xs
    public static let tagTextSize: CGFloat = 10.5
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

    // Comments (DZCanvas, DZTweak, NWDesignTool)
    /// The canvas pin: a 26pt lantern teardrop with a 4pt point, mono 12 bold, centered on its
    /// element's top-trailing corner, with a small shadow (the boards' 0 4 12 black 40%; drawn
    /// with the knob's shadow role). In a card's header it is 18pt with a 3pt point, mono 10.
    public static let pinSize: CGFloat = 26
    public static let pinPoint: CGFloat = NW.Radius.xs
    public static let pinTextSize: CGFloat = 12
    public static let pinShadowRadius: CGFloat = NW.Space.s
    public static let pinShadowY: CGFloat = NW.Space.xs
    public static let cardPinSize: CGFloat = 18
    public static let cardPinPoint: CGFloat = 3
    public static let cardPinTextSize: CGFloat = 10
    /// Every comment line is 1px.
    public static let lineWidth: CGFloat = 1
    /// The thread beside a pin: 320pt, 12×14 padding, 10pt between its parts, radius 12; each
    /// answer 8pt under a hairline, its name over its words 4pt apart; the Reply… field 32pt,
    /// 10pt padding, radius 8, in 12.5. It sits 16pt under its element.
    public static let threadWidth: CGFloat = 320
    public static let threadPaddingVertical: CGFloat = NW.Space.l
    public static let threadPaddingHorizontal: CGFloat = 14
    public static let threadSpacing: CGFloat = 10
    public static let threadRadius: CGFloat = NW.Radius.l
    public static let threadGap: CGFloat = NW.Space.xl
    public static let entryGap: CGFloat = NW.Space.m
    public static let entrySpacing: CGFloat = NW.Space.xs
    public static let replyFieldHeight: CGFloat = NW.Height.controlL
    public static let replyFieldPadding: CGFloat = 10
    public static let replyFieldRadius: CGFloat = NW.Radius.m
    public static let replyTextSize: CGFloat = 12.5
    /// A comment's words at 13/1.5, its header in 11.5.
    public static let commentTextSize: CGFloat = 13
    public static let commentLineHeight: CGFloat = 1.5
    public static let commentMetaSize: CGFloat = 11.5
    /// A comment card: 12×14 padding, 8pt between its parts, radius 10.
    public static let commentCardPaddingVertical: CGFloat = NW.Space.l
    public static let commentCardPaddingHorizontal: CGFloat = 14
    public static let commentCardSpacing: CGFloat = NW.Space.m
    public static let commentCardRadius: CGFloat = 10

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

    // Tweak (DZTweak, NWDesignTool)
    /// The Tweak tab's header and groups: 14×18 padding, a hairline under each.
    public static let tweakPaddingVertical: CGFloat = 14
    public static let tweakPaddingHorizontal: CGFloat = 18
    /// The header's lines: the path in mono 11, the note in 11.5, 4pt apart.
    public static let tweakPathSize: CGFloat = 11
    public static let tweakNoteSize: CGFloat = 11.5
    public static let tweakHeaderSpacing: CGFloat = NW.Space.xs
    /// A group's section label sits 6pt above its rows.
    public static let tweakLabelGap: CGFloat = NW.Space.s
    /// A row: at least 30pt (a slider) or 32pt, its label in 12.5 in a 92pt column, 12pt before
    /// the control.
    public static let tweakSliderRowHeight: CGFloat = 30
    public static let tweakRowHeight: CGFloat = 32
    public static let tweakLabelWidth: CGFloat = 92
    public static let tweakLabelSize: CGFloat = 12.5
    public static let tweakRowSpacing: CGFloat = NW.Space.l
    /// Chips and pickers sit 6pt apart at the row's trailing edge.
    public static let tweakControlSpacing: CGFloat = NW.Space.s
    /// The scope's note: 6pt under its row, 11.5/1.45.
    public static let tweakScopeNoteGap: CGFloat = NW.Space.s
    public static let tweakScopeNoteLineSpacing: CGFloat = 5
    /// The footer: 12×14 padding, a hairline above.
    public static let tweakFooterPaddingVertical: CGFloat = NW.Space.l
    public static let tweakFooterPaddingHorizontal: CGFloat = 14
    /// A token chip: 26pt, 8pt padding, radius 6, a 10pt swatch (radius 3) 6pt from the name in
    /// mono 11.5.
    public static let tokenChipHeight: CGFloat = 26
    public static let tokenChipPadding: CGFloat = NW.Space.m
    public static let tokenChipRadius: CGFloat = NW.Radius.s
    public static let tokenChipSpacing: CGFloat = NW.Space.s
    public static let tokenChipSwatch: CGFloat = 10
    public static let tokenChipSwatchRadius: CGFloat = 3
    public static let tokenChipTextSize: CGFloat = 11.5
}
