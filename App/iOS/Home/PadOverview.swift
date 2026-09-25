import SwiftUI
import ShepherdUI

/// The iPad detail with no thread selected (iPadOverview board; home track).
struct PadOverview: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NWEmptyState(Text("Choose a thread"), message: "Pick one from the sidebar, or start a new one.") {
            Button("New thread") { NewThreadHooks.open(navigator: navigator) }.buttonStyle(.nw(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}
