import SwiftUI
import ShepherdUI

/// Home's own screens (home track), pushed from Home's destinations list or the iPad sidebar.
enum HomeRoute: Hashable, Codable {
    /// Everything waiting on you, across hosts.
    case needsYou
    /// Automations on every host (read-only in this release).
    case automations
    /// Hosts and everything else (MobileMore board).
    case more
    /// Every recent thread, past Home's first few.
    case recents
}

struct HomeDestination: View {
    let route: HomeRoute
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        switch route {
        case .needsYou: NeedsYouScreen()
        case .automations: AutomationsScreen()
        // On iPad More expands in the sidebar, and its Hosts row opens the Hosts destination.
        case .more: if navigator.layout == .pad { PadHostsScreen() } else { MoreScreen() }
        case .recents: RecentsScreen()
        }
    }
}
