import SwiftUI
import ShepherdUI

/// Dimensions of the Projects surfaces (ProjectLead boards), each measured from the unchanged
/// boards (3200x1800 window boards = 1600x900pt; 2880x1800 Settings boards = 1440x900pt).
extension AppLayout {
    // Project settings (ProjectLead-Settings*), measured in points from the 2880x1800 boards: the card is
    // 759pt wide, centered in the main column; the first line (the project's name) sits 24pt down; a row
    // is its text (content at least 32) between 10pt of padding, 12pt in from the card's sides; the tab
    // label has 9pt either side of it and a 2pt lantern rule over a 1pt hairline.
    static let projectSettingsWidth: CGFloat = 759
    static let projectSettingsTop: CGFloat = NW.Space.xxl
    static let projectSettingsTabSpacing: CGFloat = NW.Space.s
    static let projectSettingsTabPadding: CGFloat = 9
    static let projectSettingsTabRule: CGFloat = 2
    static let projectSettingsRowContent: CGFloat = NW.Height.controlL + NW.Space.xs
    static let projectSettingsRowSide: CGFloat = NW.Space.l
    /// The Goal field is 320pt wide on the board (the Settings fields are 240).
    static let projectGoalFieldWidth: CGFloat = 320
    /// The instructions card: 148pt tall (ProjectLead-SettingsMemory).
    static let projectSettingsInstructionsMinHeight: CGFloat = 148

    // Overview (ProjectLead-EmptyV2): the column is 850pt wide, 12pt under the toolbar, rows 34pt and
    // suggestions 28pt (the nearest tokens to the board's 33.5 and 29).
    static let projectOverviewWidth: CGFloat = 850
    static let projectOverviewTop: CGFloat = NW.Space.l
    @MainActor static var projectOverviewRow: CGFloat { NW.Height.row + NW.Space.s }
    @MainActor static var projectOverviewSuggestion: CGFloat { NW.Height.row }
}
