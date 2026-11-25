import SwiftUI
import ShepherdUI

/// The built-in design system's page (DesignSystemPage, DesignSystemColors, DesignSystemType,
/// DesignSystemSpacing, DesignSystemSizes, DesignSystemComponents), as the boards draw it.
extension AppLayout {
    /// The column: at most this wide, centered, 24pt between its parts.
    static let referenceColumnWidth: CGFloat = SHDesignChrome.systemColumn
    static let referencePartSpacing: CGFloat = SH.Space.xxl
    /// Above the first part, clear of the contents button; below the last.
    static let referenceTopPadding: CGFloat = SH.Space.xl
    static let referenceBottomPadding: CGFloat = 64

    /// The hero (DesignSystemPage): 28pt in, the name at 28 bold with its tagline under it, 38pt tiles 6pt apart.
    static let referenceHeroNameSize: CGFloat = 28
    static let referenceHeroPadding: CGFloat = 28
    static let referenceHeroTile: CGFloat = 38
    static let referenceHeroGap: CGFloat = SH.Space.s

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
    static let referenceMenuWidth: CGFloat = 230
    static let referenceMenuInset: CGFloat = 48
    /// The measure of Principles and Voice copy.
    static let referenceProseLineSpacing: CGFloat = 4
}
