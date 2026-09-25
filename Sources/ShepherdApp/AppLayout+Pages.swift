import SwiftUI
import ShepherdUI

/// The sidebar destinations' pages in the main column (NavAutomations, NavHosts). Their shared
/// frame (header, table, cards) is `NWPageMetrics`.
extension AppLayout {
    // Automations
    /// The table's columns: Automation · Starts · Host · Last run (the board's `2fr 76px 76px
    /// 1.15fr`, without When and Next: automations have no schedule).
    static let automationColumns: [NWTableColumns.Column] = [.flex(2), .fixed(76), .fixed(76), .flex(1.15)]
    /// Above the table's column labels (the board's tabs sit there; there are none).
    static let automationTableTop: CGFloat = NW.Space.xl
    /// The detail pane beside the table.
    static let automationDetailWidth: CGFloat = 360
    /// The detail's sections: 14 above and below, 18 at the sides; its header 16 above and below.
    static let automationDetailSide: CGFloat = 18
    static let automationDetailSectionVertical: CGFloat = 14
    static let automationDetailHeaderVertical: CGFloat = NW.Space.xl
    /// The facts' label column, and the space between facts.
    static let automationFactLabelWidth: CGFloat = 90
    static let automationFactSpacing: CGFloat = NW.Space.s
    /// The footer's padding: 12 above and below, 14 at the sides.
    static let automationFooterVertical: CGFloat = NW.Space.l
    static let automationFooterSide: CGFloat = 14
    /// An empty table's message.
    static let automationEmptyMaxWidth: CGFloat = 420

    // Hosts
    /// Cards per row.
    static let hostColumns = 3
    /// The explainer's measure, and the space under it.
    static let hostExplainerMaxWidth: CGFloat = 720
    static let hostExplainerSpacing: CGFloat = 14
}
