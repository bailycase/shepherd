import SwiftUI
import ShepherdUI

/// The designs track's own measures (MobileDesigns, MobileDesignBoard). Shepherd Design's phone
/// parts carry their own (`SHPhoneDesignMetrics`).
enum MobileDesignLayout {
    /// The Designs screen's sides (the board's 16pt) and its sections 20pt apart.
    static let gutter: CGFloat = SH.Space.xl
    static let sectionSpacing: CGFloat = 20
    /// The Designs list's own title (28 bold).
    static let titleSize: CGFloat = 28
    /// A board on its screen sits this far under the navigation, and keeps as much above the toolbar.
    static let boardTop: CGFloat = 18
    /// The room a board keeps at the bottom for the floating toolbar (60pt and its margins).
    static let boardBottom: CGFloat = 80
    /// The comment card's sides and the room it keeps above the toolbar.
    static let cardInset: CGFloat = SH.Space.l
    /// The Boards sheet's tiles: a board's label and size under its image.
    static let boardsTileHeight: CGFloat = 140
    /// A drag this far sideways on an unzoomed board moves to the next board.
    static let swipeDistance: CGFloat = 60
    /// Tweak's sheet rests at this part of the screen, the board still showing (and taking taps) above it.
    static let tweakSheetFraction: CGFloat = 0.45
    /// A notice over the board (Copied a reference, Sent) goes after this, as the Mac's toast does.
    static let noticeLifetime: Duration = .seconds(6)
    /// The @ picker over a host thread's composer stops growing here; its rows scroll inside.
    static let mentionPickerMaxHeight: CGFloat = 360
}
