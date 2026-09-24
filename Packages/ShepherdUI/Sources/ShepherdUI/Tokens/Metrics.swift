import SwiftUI

/// Night Watch's space, radius, and size scales (Foundations board), on a 4pt grid. Padding and
/// gaps use only `Space` steps. Hairlines are 1px: `NW.hairline(displayScale)`.
public enum NW {
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    public enum Radius {
        /// Pills, keycaps, chips.
        public static let xs: CGFloat = 4
        /// Buttons, fields, rows.
        public static let s: CGFloat = 6
        /// Cards, composer, tool groups.
        public static let m: CGFloat = 8
        /// Popovers, palette, sheets.
        public static let l: CGFloat = 12
    }

    /// Row heights scale with Settings ▸ Appearance ▸ Density (rounded to whole points); control
    /// heights are fixed.
    public enum Height {
        /// Diff lines, dense lists.
        @MainActor public static var rowCompact: CGFloat { scaled(22) }
        /// Sidebar, tool rows, menus.
        @MainActor public static var row: CGFloat { scaled(28) }
        /// Inbox items, ledgers.
        @MainActor public static var rowComfortable: CGFloat { scaled(36) }
        /// Inline buttons.
        public static let controlS: CGFloat = 24
        /// Default controls.
        public static let controlM: CGFloat = 28
        /// Primary actions, composer send.
        public static let controlL: CGFloat = 32
        /// The minimum touch target (iOS).
        public static let touch: CGFloat = 44

        /// A density-scaled row height for a size the scale does not name.
        @MainActor public static func scaled(_ height: CGFloat) -> CGFloat {
            (height * ThemeStore.shared.density).rounded()
        }
    }

    /// Settings ▸ Appearance ▸ Density.
    @MainActor public static var density: CGFloat { ThemeStore.shared.density }

    /// One device pixel: hairlines are always 1px, never 1pt.
    public static func hairline(_ displayScale: CGFloat) -> CGFloat { 1 / max(1, displayScale) }
}
