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

/// Files pushed on a phone: the pane's Files tab on regular width. (Browser has its own route,
/// `MobileRoute.browser`.)
enum SidePaneRoute: Hashable, Codable {
    case files(AgentRef)

    var thread: AgentRef {
        switch self {
        case .files(let ref): ref
        }
    }

    var tab: PadSidePaneTab { .files }
}

struct SidePaneDestination: View {
    let route: SidePaneRoute

    var body: some View {
        switch route {
        case .files(let ref): ThreadFilesScreen(thread: ref).toolbar(.hidden, for: .tabBar)
        }
    }
}

extension MobileRoute {
    /// The pane tab that shows this screen of a thread on regular width; nil for a screen that
    /// isn't one (a thread, Settings, a sheet's route).
    var sidePaneTab: PadSidePaneTab? {
        switch self {
        case .review(.changes), .review(.diff): .changes
        case .terminal: .terminal
        case .subagents: .subagents
        case .sidePane(let route): route.tab
        case .browser: .browser
        default: nil
        }
    }

    /// The screen the phone pushes for a pane tab of `thread`.
    static func paneScreen(_ tab: PadSidePaneTab, thread: AgentRef) -> MobileRoute {
        switch tab {
        case .changes: .review(.changes(thread, file: nil))
        case .files: .sidePane(.files(thread))
        case .terminal: .terminal(.panes(thread))
        case .subagents: .subagents(.list(thread))
        case .browser: .browser(.page(thread))
        }
    }
}
