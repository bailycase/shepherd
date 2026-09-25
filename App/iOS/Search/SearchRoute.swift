import SwiftUI
import ShepherdUI

/// Search's screens (search track): threads and snippets across every host.
enum SearchRoute: Hashable, Codable {
    case search(query: String)
}

/// Where other screens open search (Home's search button, ⌘K on iPad).
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
        case .search:
            NWEmptyState(Text("Search"), message: "Find a thread or a line in one, on every host.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
