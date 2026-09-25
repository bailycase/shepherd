import SwiftUI
import ShepherdUI

/// Search's screens (search track): threads and snippets across every host.
enum SearchRoute: Hashable, Codable {
    /// iPhone (and an iPad window as narrow as one): the search screen, pushed.
    case search(query: String)
}

/// Where other screens open search (Home's search button, the iPad sidebar).
@MainActor
enum SearchHooks {
    static func open(query: String = "", navigator: MobileNavigator) {
        navigator.open(.search(.search(query: query)))
    }
}

struct SearchDestination: View {
    let route: SearchRoute

    var body: some View {
        switch route {
        case .search(let query): MobileSearchScreen(initialQuery: query)
        }
    }
}
