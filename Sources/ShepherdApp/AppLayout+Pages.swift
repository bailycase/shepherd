import SwiftUI
import ShepherdUI

/// The sidebar destinations' pages in the main column (NavAutomations, NavHosts). Their shared
/// frame (header, table, cards) is `SHPageMetrics`.
extension AppLayout {
    // Automations
    /// Between the table and the detail card.
    static let automationPageGap: CGFloat = 20
    /// An empty table's message.
    static let automationEmptyMaxWidth: CGFloat = 420
    /// The editor's fields scroll past this, so the sheet fits a laptop screen with its footer.
    static let automationSheetBodyMaxHeight: CGFloat = 560
}
