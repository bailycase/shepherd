import SwiftUI
import ShepherdUI

/// Settings ▸ Fleet and its sheets (FleetPair, FleetStates' Join a fleet).
extension AppLayout {
    /// Add a Mac: 520pt wide (FleetPair).
    static let fleetPairWidth: CGFloat = 520
    /// A digit of the code: 40 by 48pt, the display size in mono.
    static let fleetDigitWidth: CGFloat = 40
    static let fleetDigitHeight: CGFloat = 48
    /// The gap between the code's two groups of three.
    static let fleetDigitGroupGap: CGFloat = SH.Space.l
    /// The sheet's rows of Macs found: a 16pt monitor glyph, then the name over its address.
    static let fleetFoundGlyphSize: CGFloat = 16
    /// What the new Mac gets: a 16pt column holding a 14pt tick or cross.
    static let fleetGetsColumn: CGFloat = 16
    static let fleetGetsGlyphSize: CGFloat = 14
    /// Join a fleet (FleetStates): the code in mono at 40pt, its two groups of three a space apart.
    static let fleetJoinWidth: CGFloat = 460
    static let fleetJoinCodeSize: CGFloat = 40
    /// A Macs row's status dot.
    static let fleetDotSize: CGFloat = 6
}
