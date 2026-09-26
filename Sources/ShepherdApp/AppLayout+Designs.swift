import SwiftUI
import ShepherdUI

/// The Design tool's screens (NavDesigns, DZStart, DZCanvas). The canvas's, the cards' and the
/// header's own measures are `NWDesignMetrics`.
extension AppLayout {
    // The Designs page
    /// Between the page's sections.
    static let designsSectionSpacing: CGFloat = 26
    /// System cards per row.
    static let designSystemColumns = 3
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

    // A design
    /// The chat pane beside the canvas.
    static let designChatWidth: CGFloat = 420
    /// A data-props text field in the Tweak tab (not drawn: the board's slider width).
    static let designTweakFieldWidth: CGFloat = 190
}
