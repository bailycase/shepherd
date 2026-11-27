import SwiftUI
import ShepherdUI
import ShepherdRemote

struct HomeDestination: View {
    let route: HomeRoute
    var body: some View {
        switch route {
        case .needsYou: NeedsYouScreen()
        case .automations: AutomationsScreen()
        // Hosts became Fleet: the Macs this device is paired with, as one fleet.
        case .more: FleetScreen()
        }
    }
}
