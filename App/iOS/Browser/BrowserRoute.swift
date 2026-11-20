import SwiftUI
import ShepherdRemote

struct BrowserDestination: View {
    let route: BrowserRoute

    var body: some View {
        switch route {
        case .page(let ref): ThreadBrowserScreen(thread: ref)
        }
    }
}
