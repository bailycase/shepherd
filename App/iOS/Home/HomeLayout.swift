import SwiftUI
import ShepherdUI

/// Home's own measures (home track).
extension MobileLayout {
    /// Between a section's header and its card.
    static let headerSpacing: CGFloat = NW.Space.s
    /// Between Home's sections.
    static let sectionSpacing: CGFloat = NW.Space.xxl
    /// An iPad overview column at its narrowest; narrower windows stack the columns.
    static let overviewColumnMinWidth: CGFloat = 256
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
}
