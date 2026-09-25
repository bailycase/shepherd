import SwiftUI
import ShepherdUI

/// New thread's screens (newthread track). Presented modally: `NewThreadHooks.open`.
enum NewThreadRoute: Hashable, Codable {
    /// The prompt with its repo, host, model and thinking chips; `host` preselects one.
    case compose(host: UUID?)
}

/// Where other screens start a new thread (Home's New thread, the iPad sidebar).
@MainActor
enum NewThreadHooks {
    static func open(host: UUID? = nil, navigator: MobileNavigator) {
        navigator.present(.newThread(.compose(host: host)))
    }
}

struct NewThreadDestination: View {
    let route: NewThreadRoute
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        switch route {
        case .compose:
            NWEmptyState(Text("New thread"), message: "Start an agent on any host from here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle("New thread")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { navigator.dismissPresented() }
                    }
                }
        }
    }
}
