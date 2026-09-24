import SwiftUI
import Observation

/// The selected theme and the user's text scale and density. Views read colors, fonts, and sizes
/// through `Color.nw`, `Font.nw`, and `NW`, which read this store, so a change here re-renders
/// exactly the views that used it. Light and dark are not stored: every color is dynamic and
/// resolves against the appearance of the view drawing it.
///
/// Each theme is resolved once into an immutable `NWPalette` (every `Color` built when the theme
/// changes), and each text scale into an `NWTypeRamp`; a token read is a stored-property load.
@MainActor @Observable
public final class ThemeStore {
    public static let shared = ThemeStore()

    public private(set) var theme: ThemeDefinition
    /// Every color of `theme`, resolved.
    public private(set) var palette: NWPalette
    /// Every text style at `textScale`, resolved.
    public private(set) var typeRamp: NWTypeRamp

    /// Settings ▸ Appearance ▸ Text size; multiplies every font size.
    public var textScale: CGFloat = 1 {
        didSet {
            guard textScale != oldValue else { return }
            typeRamp = NWTypeRamp(scale: textScale)
        }
    }

    /// Settings ▸ Appearance ▸ Density; multiplies row heights (`NW.Height.row…`).
    public var density: CGFloat = 1

    public init(theme: ThemeDefinition = .nightWatch) {
        NWFonts.register()
        self.theme = theme
        palette = NWPalette(theme)
        typeRamp = NWTypeRamp(scale: 1)
    }

    public func select(_ theme: ThemeDefinition) {
        guard theme != self.theme else { return }
        self.theme = theme
        palette = NWPalette(theme)
    }
}
