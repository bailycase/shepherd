import SwiftUI
import ShepherdUI

/// The iOS client's own dimensions, beside Night Watch's scales (the Mac's AppLayout). A track
/// adds its screen's measures in its own folder, as an extension of this enum, so no two
/// tracks edit one file.
enum MobileLayout {
    /// The side gutter of every screen (the boards' 16pt).
    static let gutter: CGFloat = NW.Space.xl
    /// Space between the blocks of a screen: sections, cards, turns.
    static let blockSpacing: CGFloat = NW.Space.l
    /// A thread's turns.
    static let turnSpacing: CGFloat = NW.Space.xxl
    /// The parts inside one agent turn.
    static let turnItemSpacing: CGFloat = NW.Space.l
    /// Lines inside a work group.
    static let activitySpacing: CGFloat = NW.Space.xxs
    /// A thread's readable measure on iPad (iPadThread's 780pt column); the phone uses its full width.
    static let threadMaxWidth: CGFloat = 780
    /// A question's card on iPad, wider than the thread's column (iPadQuestion).
    static let questionMaxWidth: CGFloat = 900
    /// The iPad thread's and composer's side gutters (iPadThread's 24pt; the phone keeps `gutter`).
    static let padThreadGutter: CGFloat = NW.Space.xxl
    /// A note's indent from its rule.
    static let noteIndent: CGFloat = NW.Space.m
    /// The iPad sidebar's width beside the thread, in landscape (iPadThread).
    static let sidebarWidth: CGFloat = 300
    /// The iPad sidebar's width as it slides over the thread, in portrait (iPadSidebar).
    static let sidebarOverlayWidth: CGFloat = 340
    /// How much further in More's sub-rows start their content in the iPad sidebar (iPadHosts: 24pt).
    static let sidebarSubrowIndent: CGFloat = NW.Space.l
    /// A list row: the boards' 48pt, never under the touch minimum.
    static let rowHeight: CGFloat = 48
    /// A two-line row (a title over a status line).
    static let twoLineRowHeight: CGFloat = 56
    /// The status dot in rows and headers.
    static let statusDot: CGFloat = 8
    /// A card's corner (the boards' 12pt).
    static let cardRadius: CGFloat = NW.Radius.l
}
