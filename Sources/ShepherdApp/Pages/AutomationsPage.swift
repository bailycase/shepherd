import SwiftUI
import ShepherdUI

// Seam for the Automations page (NavAutomations), built on feat/mac-pages: the sidebar's
// Automations destination shows `AutomationsDestination`, which derives the page's plain
// Equatable model from the view model and hands it the actions. This placeholder draws only the
// page's header until that branch lands.

/// Where a page's header starts: clear of the window controls, with the sidebar button while the
/// sidebar is not docked (as the thread toolbar).
struct PageHeaderChrome {
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
}

/// The Automations destination in the main column.
struct AutomationsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        AutomationsPage(chrome: chrome)
    }
}

/// The Automations page (NavAutomations).
struct AutomationsPage: View {
    let chrome: PageHeaderChrome

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Automations", chrome: chrome)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}
