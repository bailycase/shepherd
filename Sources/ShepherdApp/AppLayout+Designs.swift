import SwiftUI
import ShepherdUI

/// The Design tool's screens (NavDesigns, DZStart, DZCanvas). The canvas's, the cards' and the
/// header's own measures are `NWDesignMetrics`.
extension AppLayout {
    // The Designs page
    /// Between the page's sections.
    static let designsSectionSpacing: CGFloat = 26
    /// A card's thumbnail is kept this many pixels wide (its board draws at most 256pt).
    static let designThumbnailPixelWidth: CGFloat = 512

    // New design
    /// Between the page's parts, and under the headline.
    static let newDesignGap: CGFloat = 26
    static let newDesignSubtitleSpacing: CGFloat = NW.Space.l
    static let newDesignSubtitleWidth: CGFloat = 560
    static let newDesignComposerWidth: CGFloat = 720
    static let newDesignFieldMinHeight: CGFloat = 72
    /// The column sits a little above center: this much more room below it than above.
    static let newDesignBottomExtra: CGFloat = 60
    /// The starting points: 10pt under their label, 10pt apart, three to a row.
    static let newDesignCardsLabelGap: CGFloat = 10
    static let newDesignCardsGap: CGFloat = 10
    static let newDesignCardsPerRow: CGFloat = 3
    /// A starting point's card: its three lines with their padding.
    static let newDesignCardHeight: CGFloat = 84

    // A design system's page (DZSystem); the section list and the swatches are `NWDesignMetrics`
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
