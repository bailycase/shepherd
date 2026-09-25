import SwiftUI
import ShepherdUI

/// Settings' screens (home track). `open` shows them in the Settings tab on iPhone and over
/// the detail on iPad.
enum SettingsRoute: Hashable, Codable {
    case root
    case hosts
    /// A host's form; nil adds one.
    case host(UUID?)
    case appearance
}

struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .root: SettingsScreen()
        case .hosts: HostsScreen()
        case .host(let id): HostEditorScreen(hostID: id)
        case .appearance: AppearanceScreen()
        }
    }
}
