import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Where other screens start a new thread (Home's New thread, the iPad sidebar).
@MainActor
enum NewThreadHooks {
    static func open(host: UUID? = nil, navigator: MobileNavigator) {
        navigator.present(.newThread(.compose(host: host)))
    }
}

struct NewThreadDestination: View {
    let route: NewThreadRoute

    var body: some View {
        switch route {
        case .compose(let host): NewThreadScreen(preferredHost: host)
        }
    }
}
