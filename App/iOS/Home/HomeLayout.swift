import SwiftUI
import ShepherdUI

/// Home's own measures (home track).
extension MobileLayout {
    /// Between a section's header and its card.
    static let headerSpacing: CGFloat = SH.Space.s
    /// Between Home's sections.
    static let sectionSpacing: CGFloat = SH.Space.xxl
    /// The iPad inbox's list beside the chosen item.
    static let inboxListWidth: CGFloat = 360
    /// Host cards on a wide screen, each at least this wide.
    static let hostCardMinWidth: CGFloat = 320
    /// A readable measure for Home's lists on iPad.
    static let homeMaxWidth: CGFloat = 640
}

/// How much of each list Home shows before "See all".
enum HomeLimits {
    static let needsYou = 2
    static let recents = 6
    /// Working and Done rows on Home before "Show all": a card draws every row it holds, so a
    /// large group lists past these on its own screen.
    static let group = 8
}
