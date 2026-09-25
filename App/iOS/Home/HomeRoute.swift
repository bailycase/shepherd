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
}

struct HomeDestination: View {
    let route: HomeRoute

    var body: some View {
        let (title, message): (String, String) = switch route {
        case .needsYou: ("Needs you", "Questions and blocked threads from every host.")
        case .automations: ("Automations", "Each host's automations and their last runs.")
        case .more: ("More", "Hosts, and everything else.")
        }
        NWEmptyState(Text(title), message: message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.nw.bgWindow)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
