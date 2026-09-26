import SwiftUI
import ShepherdUI

/// A destination page's header (Destination pages; NavNewThread, NavAutomations, NavHosts):
/// `NWPageHeader` with the page's chrome, and the Show sidebar button's chord from the keybindings.
struct DestinationPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let chrome: PageHeaderChrome
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        NWPageHeader(title, subtitle: subtitle, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                     sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar), trailing: trailing)
    }
}

extension DestinationPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, chrome: PageHeaderChrome) {
        self.init(title: title, subtitle: subtitle, chrome: chrome) { EmptyView() }
    }
}
