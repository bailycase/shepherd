import SwiftUI
import ShepherdUI

/// Home's own measures (home track).
extension MobileLayout {
    /// Between a section's header and its card.
    static let headerSpacing: CGFloat = SH.Space.m
    /// Between Home's sections.
    static let sectionSpacing: CGFloat = SH.Space.xxl
    /// An iPad overview column at its narrowest; narrower windows stack the columns.
    static let overviewColumnMinWidth: CGFloat = 256
    /// The iPad inbox's list beside the chosen item.
    static let inboxListWidth: CGFloat = 340
    /// The iPad bar's head and the line under it (iPadOverview, iPadInbox: 18/600 over 12), and a detail's title (22/600).
    static let barTitleSize: CGFloat = 18
    static let barSubtitleSize: CGFloat = 12
    static let detailTitleSize: CGFloat = 22
    /// A readable measure for Home's lists on iPad.
    static let homeMaxWidth: CGFloat = 640
}
