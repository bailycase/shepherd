import SwiftUI
import ShepherdUI

// Seam for the Hosts page (NavHosts, More ▸ Hosts), built on feat/mac-pages: the sidebar's
// Hosts destination shows `HostsDestination`, which derives the page's plain Equatable model
// (This Mac and each host's card: status, address, threads, Retry, Remove, Add host) from the
// view model and hands it the actions. This placeholder draws only the page's header until that
// branch lands.

/// The Hosts destination in the main column.
struct HostsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        HostsPage(chrome: chrome)
    }
}

/// The Hosts page (NavHosts).
struct HostsPage: View {
    let chrome: PageHeaderChrome

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Hosts", chrome: chrome)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}
