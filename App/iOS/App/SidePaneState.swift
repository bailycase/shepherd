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

/// Thread screens the phone pushes that the pane shows as tabs on regular width, until the
/// Files and Browser lanes bring their own screens.
enum SidePaneRoute: Hashable, Codable {
    case files(AgentRef)
    case browser(AgentRef)

    var thread: AgentRef {
        switch self {
        case .files(let ref), .browser(let ref): ref
        }
    }

    var tab: PadSidePaneTab {
        switch self {
        case .files: .files
        case .browser: .browser
        }
    }
}

struct SidePaneDestination: View {
    let route: SidePaneRoute

    var body: some View {
        SidePaneComingSoon(tab: route.tab)
            .toolbar(.hidden, for: .tabBar)
            .navigationTitle(route.tab.title)
            .navigationBarTitleDisplayMode(.inline)
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
        case .browser: .sidePane(.browser(thread))
        // The phone shows an artifact in a sheet (`ArtifactHooks`); its list is the changes'.
        case .artifacts: .review(.changes(thread, file: nil))
        }
    }
}
