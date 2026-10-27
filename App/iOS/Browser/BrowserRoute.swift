import SwiftUI

/// The Browser's screens: a thread's page, pushed full screen at compact width (the side pane shows
/// `ThreadBrowserPane` in place).
enum BrowserRoute: Hashable, Codable {
    case page(AgentRef)

    var thread: AgentRef {
        switch self {
        case .page(let ref): ref
        }
    }
}

struct BrowserDestination: View {
    let route: BrowserRoute

    var body: some View {
        switch route {
        case .page(let ref): ThreadBrowserScreen(thread: ref)
        }
    }
}
