import SwiftUI
import ShepherdUI

/// Settings › Apps and its Add app sheet (AppsSettings, AppsAdd boards).
extension AppLayout {
    /// An app row: at least 68pt, its glyph in a 32pt tile.
    static let appsRowHeight: CGFloat = 68
    static let appsIconTile: CGFloat = 32
    static let appsIconSize: CGFloat = 13
    /// The row's name and its Quick action tag.
    static let appsNameSize: CGFloat = 14
    static let appsTagSize: CGFloat = 11
    static let appsTagHeight: CGFloat = 18
    /// The dashed row of package.json scripts to add.
    static let appsSuggestionHeight: CGFloat = 46
    /// The Add app sheet: 620pt wide, 760pt tall.
    static let appsSheetWidth: CGFloat = 620
    static let appsSheetHeight: CGFloat = 760
}
