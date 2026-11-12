import SwiftUI
import ShepherdUI

/// Home's own screens (home track). On iPhone, Automations and More are tab roots
/// (`MobileRoute.isTabRoot`): opening one selects the Automations or Settings tab.
enum HomeRoute: Hashable, Codable {
    /// Everything waiting on you, across hosts.
    case needsYou
    /// Automations on every host (read-only in this release).
    case automations
    /// Fleet (what Hosts was): the Macs this device is paired with; on iPhone, the Settings tab.
    case more
    /// Every recent thread, past Home's first few.
    case recents
    /// Every thread in Working or Done, past Home's first few of each.
    case working
    case done
}

struct HomeDestination: View {
    let route: HomeRoute
    var body: some View {
        switch route {
        case .needsYou: NeedsYouScreen()
        case .automations: AutomationsScreen()
        // Hosts became Fleet: the Macs this device is paired with, as one fleet.
        case .more: FleetScreen()
        case .recents: RecentsScreen(group: .recents)
        case .working: RecentsScreen(group: .working)
        case .done: RecentsScreen(group: .done)
        }
    }
}
