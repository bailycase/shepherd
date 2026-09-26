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

    // Board actions (NWBoardActions; NWDesignTool, DZCanvas)
    /// NWDesignTool's bar: 4pt padding, radius 12, 2pt between items; items 28pt tall, 10pt
    /// padding, radius 8, a 13pt glyph 6pt from the label in 12.5; ••• a 28pt circle.
    public static let actionsPadding: CGFloat = NW.Space.xs
    public static let actionsSpacing: CGFloat = NW.Space.xxs
    public static let actionsRadius: CGFloat = NW.Radius.l
    public static let actionItemHeight: CGFloat = NW.Height.controlM
    public static let actionItemPadding: CGFloat = 10
    public static let actionItemRadius: CGFloat = NW.Radius.m
    public static let actionItemGap: CGFloat = NW.Space.s
    public static let actionGlyph: CGFloat = 13
    public static let actionTextSize: CGFloat = 12.5
    /// DZCanvas draws the bar smaller: 32pt at radius 10, items 26pt at radius 6 with 8pt
    /// padding, in 12; ••• a 26pt circle with a 14pt glyph.
    public static let compactActionsHeight: CGFloat = NW.Height.controlL
    public static let compactActionsRadius: CGFloat = 10
    public static let compactActionItemHeight: CGFloat = 26
    public static let compactActionItemPadding: CGFloat = NW.Space.m
    public static let compactActionItemRadius: CGFloat = NW.Radius.s
    public static let compactActionTextSize: CGFloat = 12
    public static let moreGlyph: CGFloat = 14
    /// The bar sits 2pt above its board's label (DZCanvas: 58pt above the frame at 42%).
    public static let actionsGap: CGFloat = NW.Space.xxs

    // "Ask for another direction" (DZCanvas)
    /// A 300×190 dashed tile (1px `lineStrong`, radius 6), 36pt after the last board, top-aligned
    /// with it: a 16pt `plus` over the words in 12 `textTertiary`, 6pt apart.
    public static let directionTileSize = CGSize(width: 300, height: 190)
    public static let directionTileRadius: CGFloat = NW.Radius.s
    public static let directionTileGap: CGFloat = 36
    public static let directionTileGlyph: CGFloat = 16
    public static let directionTileTextSize: CGFloat = 12
    public static let directionTileSpacing: CGFloat = NW.Space.s
    public static let directionTileDash: [CGFloat] = [3, 3]

    // Notes on the canvas (not drawn on a board: canvas points, scaled with the zoom)
    /// A title note's words (`title1` and the other titles), semibold.
    public static let titleNoteSize: CGFloat = 64
    /// A sticky: its words at 16, 16pt padding, radius 8, 240 wide unless it says.
    public static let stickyTextSize: CGFloat = 16
    public static let stickyPadding: CGFloat = 16
    public static let stickyRadius: CGFloat = 8
    public static let stickyWidth: CGFloat = 240

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

    /// "Build one from a repo": its 12pt `plus`.
    public static let buildTileGlyph: CGFloat = 12

    // A design system's page (DZSystem)
    /// The section list: 200pt, 18×10 padding; rows 30pt, 10pt padding, 12.5, counts in mono 10.5.
    public static let railWidth: CGFloat = 200
    public static let railPaddingVertical: CGFloat = 18
    public static let railPaddingHorizontal: CGFloat = 10
    public static let railRowHeight: CGFloat = 30
    public static let railRowPadding: CGFloat = 10
    public static let railTextSize: CGFloat = 12.5
    public static let railCountSize: CGFloat = 10.5
    /// A token swatch: 56pt at radius 8, the name in mono 11.5, the value in mono 10.5.
    public static let tokenSwatchHeight: CGFloat = 56
    public static let tokenSwatchRadius: CGFloat = NW.Radius.m
    public static let tokenSwatchNameSize: CGFloat = 11.5
    public static let tokenSwatchDetailSize: CGFloat = 10.5
    /// A type style's row: the name in mono 11 in a 90pt column, the spec in mono 10.5.
    public static let typeNameSize: CGFloat = 11
    public static let typeNameWidth: CGFloat = 90
    public static let typeSpecSize: CGFloat = 10.5
    /// A component's specimen: a 92pt tile at radius 8, 10pt above its name in 12.5 and its
    /// template in mono 10.5.
    public static let specimenHeight: CGFloat = 92
    public static let specimenRadius: CGFloat = NW.Radius.m
    public static let specimenSpacing: CGFloat = 10
    public static let specimenNameSize: CGFloat = 12.5
    public static let specimenTemplateSize: CGFloat = 10.5

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

    // Export (DZExport)
    /// The sheet: a 560pt card at radius 14 on the popover's fill, line and shadow; its header
    /// 16×18 with "Export" in `title` and a 28pt close button; sections 14×18, their label 6pt
    /// above what they hold; the footer 12×18 with its buttons 8pt apart.
    public static let exportWidth: CGFloat = 560
    public static let exportRadius: CGFloat = 14
    public static let exportHeaderPaddingVertical: CGFloat = NW.Space.xl
    public static let exportPaddingHorizontal: CGFloat = 18
    public static let exportSectionPaddingVertical: CGFloat = 14
    public static let exportLabelGap: CGFloat = NW.Space.s
    public static let exportFooterPaddingVertical: CGFloat = NW.Space.l
    public static let exportFooterSpacing: CGFloat = NW.Space.m
    /// A board's row: 30pt, 12.5, 10pt between the checkbox, the name and the size (mono 10.5).
    public static let exportRowHeight: CGFloat = 30
    public static let exportRowTextSize: CGFloat = 12.5
    public static let exportRowSpacing: CGFloat = 10
    public static let exportRowSizeTextSize: CGFloat = 10.5
    /// Past this many rows the boards scroll (not drawn: DZExport lists four).
    public static let exportVisibleRows: CGFloat = 8
    /// A format card: 2 to a row, 8pt apart; 10×12 padding, radius 8, a 1px line; a 14pt radio
    /// 8pt from the format in 13 semibold; its line in 11.5/1.4, 24pt in, 4pt under it.
    public static let exportFormatSpacing: CGFloat = NW.Space.m
    public static let exportFormatPaddingVertical: CGFloat = 10
    public static let exportFormatPaddingHorizontal: CGFloat = NW.Space.l
    public static let exportFormatRadius: CGFloat = NW.Radius.m
    public static let exportFormatGap: CGFloat = NW.Space.xs
    public static let exportFormatRadioGap: CGFloat = NW.Space.m
    public static let exportFormatTitleSize: CGFloat = 13
    public static let exportFormatLineSize: CGFloat = 11.5
    public static let exportFormatLineHeight: CGFloat = 1.4
    public static let exportFormatIndent: CGFloat = 24
    /// "Use it somewhere else": 24pt buttons 8pt apart, a 13pt glyph, and the note 8pt under
    /// them in 11.5 `textTertiary`.
    public static let exportShareSpacing: CGFloat = NW.Space.m
    public static let exportShareGlyph: CGFloat = 13
    public static let exportNoteSize: CGFloat = 11.5
}
