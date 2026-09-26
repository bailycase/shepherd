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
    /// A thread's readable measure on iPad; the phone uses its full width.
    static let threadMaxWidth: CGFloat = 760
    /// A note's indent from its rule.
    static let noteIndent: CGFloat = NW.Space.m
    /// The iPad sidebar's width beside the thread, in landscape (iPadThread).
    static let sidebarWidth: CGFloat = 300
    /// The iPad sidebar's width as it slides over the thread, in portrait (iPadSidebar).
    static let sidebarOverlayWidth: CGFloat = 340
    /// More's sub-rows in the iPad sidebar sit this far in (iPadHosts).
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
