import SwiftUI
import ShepherdUI

/// The Design tool's screens (NavDesigns, DZStart, DZCanvas). The canvas's, the cards' and the
/// header's own measures are `SHDesignMetrics`.
extension AppLayout {
    // The Designs page: its measures are `SHDesignsHomeMetrics`
    /// A card's thumbnail is kept this many pixels wide (its board draws at most 200pt).
    static let designThumbnailPixelWidth: CGFloat = 512

    // Design references (DesignRefStates)
    /// A chip's picture is kept at most this many pixels on its long side (its preview draws it
    /// 316pt wide).
    static let referencePicturePixels: CGFloat = 640
    /// A board card's picture in the thread (ThreadBoardShown): a thread column's width at 2x.
    static let boardCardPicturePixels: CGFloat = 1800
    /// A picker row's board picture is kept this many pixels wide (drawn 40pt).
    static let referenceRowPicturePixels: CGFloat = 160
    /// An element's picture in a picker row: its thumbnail's size, in pixels at 2x.
    static let referenceCropPixels = CGSize(width: SHReferenceMetrics.thumbnail.width * 2, height: SHReferenceMetrics.thumbnail.height * 2)
    /// A board an element's picture is cut from is kept at most this many pixels wide.
    static let referenceCropSourcePixels: CGFloat = 1280

    // New design (DZStart): the column starts 96pt under the bar
    static let newDesignTop: CGFloat = 96
    /// The headline over its line, the line (a 520pt column) under it, and the composer 28pt on.
    static let newDesignSubtitleSpacing: CGFloat = SH.Space.m
    static let newDesignSubtitleWidth: CGFloat = 520
    static let newDesignComposerGap: CGFloat = 28
    static let newDesignComposerWidth: CGFloat = 860
    static let newDesignFieldMinHeight: CGFloat = 72
    /// The starting points: 26pt under the composer, their label 10pt over them, 10pt apart, three
    /// to a row.
    static let newDesignCardsTop: CGFloat = 26
    static let newDesignCardsLabelGap: CGFloat = 10
    static let newDesignCardsGap: CGFloat = 10
    /// Capture a page's address popover.
    static let newDesignCapturePopoverWidth: CGFloat = 340

    // A design system's page (DZSystem); the section list and the swatches are `SHDesignMetrics`
    /// The content's padding, and between its sections.
    static let designSystemPaddingVertical: CGFloat = 24
    static let designSystemPaddingHorizontal: CGFloat = 32
    static let designSystemSectionSpacing: CGFloat = 26
    /// The name in mono 22 over its source in 12.5.
    static let designSystemNameSize: CGFloat = 22
    static let designSystemSourceSize: CGFloat = 12.5
    /// Colors six to a row, 14pt apart; components three, 16pt apart.
    static let designSystemColorColumns = 6
    static let designSystemColorGap: CGFloat = 14
    static let designSystemComponentColumns = 3
    static let designSystemComponentGap: CGFloat = 16
    /// A type specimen is drawn at its size up to this (not drawn: a style larger than a row).
    static let designSystemSpecimenMaxSize: Double = 96

    // A design
    /// The chat pane beside the canvas.
    static let designChatWidth: CGFloat = 420
    /// The Comments tab: the chat's 18pt padding and 14pt between its cards.
    static let designCommentsPadding: CGFloat = 18
    static let designCommentsSpacing: CGFloat = 14
    /// A data-props text field in the Tweak tab (not drawn: the board's slider width).
    static let designTweakFieldWidth: CGFloat = 190
}
