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

    var body: some View {
        switch route {
        case .needsYou: NeedsYouScreen()
        case .automations: AutomationsScreen()
        case .more: MoreScreen()
        case .recents: RecentsScreen()
        }
    }
}
