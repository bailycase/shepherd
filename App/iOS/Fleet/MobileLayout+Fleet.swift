import SwiftUI
import ShepherdUI

// The Fleet screens' measures (FleetA-phone, iPadFleet, DuoOpenFleet, DuoClosedFleet, DuoBookFleet).
extension MobileLayout {
    /// A detail this wide or wider draws the Macs as cards with their readings and the Send work here menu (iPadFleet);
    /// narrower, as one card of rows (FleetA-phone, and iPhone Duo open or half open).
    static let fleetCardsMinWidth: CGFloat = 700
    /// The least width of a Mac's card before the grid drops a column.
    static let fleetCardMinWidth: CGFloat = 220
    /// Room's gauge is 6pt tall, a CPU gauge 4pt.
    static let fleetRoomBarHeight: CGFloat = SH.Space.s
    static let fleetMetricBarHeight: CGFloat = SH.Space.xs
    /// A Mac that isn't answering fades (the boards' 0.6).
    static let fleetAsleepOpacity: Double = 0.6
    /// A card's fact label column (iPadFleet's 64pt) and a dispatch's time column.
    static let fleetFactLabelWidth: CGFloat = 64
    static let fleetTimeWidth: CGFloat = 56
    /// The iPad's header sits 48pt under the top and in from the sides.
    static let fleetPadInset: CGFloat = SH.Space.xxxl + SH.Space.xl
    /// The iPad sidebar's Fleet row: a glyph and "Fleet · 1 asleep".
    static let fleetFooterGlyph: CGFloat = 16
}

extension MobileLayout {
    /// How often the page reads the fleet while it is on screen, and the sidebar's Fleet row while it shows, in seconds.
    static let fleetPoll: Double = 5
    static let fleetFooterPoll: Double = 30
}
