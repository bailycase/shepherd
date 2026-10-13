import SwiftUI
import ShepherdUI

/// The built-in design system's page (DesignSystemPage, DesignSystemColors, DesignSystemType,
/// DesignSystemSpacing, DesignSystemSizes, DesignSystemComponents), as the boards draw it.
extension AppLayout {
    /// The column: at most this wide, centered, 24pt between its parts.
    static let referenceColumnWidth: CGFloat = 960
    static let referencePartSpacing: CGFloat = NW.Space.xxl
    /// Above the first part, clear of the contents button; below the last.
    static let referenceTopPadding: CGFloat = 64
    static let referenceBottomPadding: CGFloat = 64

    /// The hero: 256pt, 32pt in, the name at 64 bold with its tagline 8pt under it. The art is
    /// four columns of 64pt tiles, 8pt apart, in three rows.
    static let referenceHeroHeight: CGFloat = 256
    static let referenceHeroNameSize: CGFloat = 64
    static let referenceHeroTileWidth: CGFloat = 64
    static let referenceHeroRows: CGFloat = 3

    /// A card's title (24 semibold) and its sub line.
    static let referenceCardTitleSize: CGFloat = 24
    /// A table's columns: the name, a shape, a note.
    static let referenceNameColumn: CGFloat = 160
    /// The Components table's name column: wide enough for the longest component name on one line.
    static let referenceComponentNameColumn: CGFloat = 224
    static let referenceShapeColumn: CGFloat = 128
    static let referenceNoteColumn: CGFloat = 224
    /// A radius's sample, and a spacing step's bar (three times the step).
    static let referenceRadiusSample = CGSize(width: 64, height: 28)
    static let referenceBarScale: CGFloat = 3
    /// A spacing or size value's chip is this wide.
    static let referenceValueChipWidth: CGFloat = 160
    /// The contents menu: 224pt, its button 16pt from the corner.
    static let referenceMenuWidth: CGFloat = 224
    static let referenceMenuInset: CGFloat = NW.Space.xl
    /// The measure of Principles and Voice copy.
    static let referenceProseLineSpacing: CGFloat = 4
}
