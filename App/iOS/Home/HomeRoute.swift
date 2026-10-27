import SwiftUI
import ShepherdUI

/// Home's own screens (home track). On iPhone, Automations and More are tab roots
/// (`MobileRoute.isTabRoot`): opening one selects the Automations or Settings tab.
enum HomeRoute: Hashable, Codable {
    /// Everything waiting on you, across hosts.
    case needsYou
    /// Automations on every host (read-only in this release).
    case automations
    /// Hosts: the iPad sidebar's (iPadHosts board); on iPhone, the Settings tab.
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
        // iPad's Hosts; the phone opens its Settings tab instead (`MobileNavigator.open`).
        case .more: if navigator.layout == .pad { PadHostsScreen() } else { HostsScreen() }
        case .recents: RecentsScreen()
        }
    }
}
