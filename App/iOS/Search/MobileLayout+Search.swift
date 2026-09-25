import SwiftUI
import ShepherdUI

/// Search's and the palette's own measures (MobileSearch, iPadPalette boards).
extension MobileLayout {
    /// The search screen's side gutter (the board's 14pt).
    static let searchGutter: CGFloat = NW.Space.l + NW.Space.xxs
    /// The iPad palette's card.
    static let paletteWidth: CGFloat = 820
    static let paletteHeight: CGFloat = 560
    /// The palette's results column; the preview takes the rest.
    static let paletteListWidth: CGFloat = 420
    /// The preview's excerpt of the thread.
    static let palettePreviewHeight: CGFloat = 300
    /// A sheet's corner on iPad (the board's 16pt).
    static let paletteRadius: CGFloat = NW.Radius.l + NW.Space.xs
}
