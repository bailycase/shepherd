import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

struct TerminalDestination: View {
    let route: TerminalRoute

    var body: some View {
        switch route {
        case .panes(let ref): TerminalScreen(ref: ref)
        }
    }
}
