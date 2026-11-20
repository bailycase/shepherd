import SwiftUI
import ShepherdRemote

/// A window's side pane beside the thread on regular width (DuoOpenSidePane, DuoSidePaneTabs):
/// whether it is open and on which tab, and the laptop pose's arrangement (DuoLaptop). It lives
/// in the navigator, never in a view's `@State`: the split view builds its columns anew as the
/// hinge moves, and the pane must come back as it was.
@MainActor
@Observable
final class SidePaneState {
    var isOpen = false
    var tab: PadSidePaneTab = .changes
    /// The thread in the laptop arrangement (DuoLaptop, DuoLaptopOpen): it takes the window, the
    /// transcript above the composer, until Back. Nil otherwise.
    var arranged: AgentRef?
    /// The arrangement shows the thread's terminal above the composer instead of its transcript.
    var arrangedTerminal = false

    func show(_ tab: PadSidePaneTab) {
        if self.tab != tab { self.tab = tab }
        if !isOpen { isOpen = true }
    }
}

struct SidePaneDestination: View {
    let route: SidePaneRoute

    var body: some View {
        switch route {
        case .files(let ref): ThreadFilesScreen(thread: ref).toolbar(.hidden, for: .tabBar)
        }
    }
}
