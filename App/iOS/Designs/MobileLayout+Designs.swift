import SwiftUI
import ShepherdUI

/// The designs track's own measures (MobileDesigns, MobileDesignBoard). Night Watch's phone
/// parts carry their own (`NWPhoneDesignMetrics`).
enum MobileDesignLayout {
    /// The Designs screen's sides (the board's 14pt) and its sections 20pt apart.
    static let gutter: CGFloat = 14
    static let sectionSpacing: CGFloat = 20
    /// A board on its screen sits this far under the navigation, and keeps as much above the toolbar.
    static let boardTop: CGFloat = 18
    /// The comment card's sides and the room it keeps above the toolbar.
    static let cardInset: CGFloat = NW.Space.l
    /// Files of remote designs this phone keeps in memory (the rest stay in its caches folder).
    static let cacheMemoryBudget = 32 * 1024 * 1024
    /// The Boards sheet's tiles: a board's label and size under its image.
    static let boardsTileHeight: CGFloat = 140
    /// A drag this far sideways on an unzoomed board moves to the next board.
    static let swipeDistance: CGFloat = 60
}
