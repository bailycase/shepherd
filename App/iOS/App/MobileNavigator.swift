import SwiftUI
import ShepherdRemote

/// Where the app is: one model for iPhone (two tabs, each a stack) and iPad (a sidebar, the
/// selected thread as the detail, and a stack pushed over it). Screens never touch paths
/// directly; they call `open` or `present`, and the navigator puts the route where the current
/// layout shows it.
@MainActor
@Observable
final class MobileNavigator {
    enum Tab: Hashable, Codable {
        case home, settings
    }

    enum Layout: Equatable {
        /// Compact width: iPhone, or an iPad window as narrow as one.
        case phone
        /// Regular width: the split view.
        case pad
    }

    /// Set by the root from the horizontal size class.
    var layout: Layout = .phone

    // iPhone
    var tab: Tab = .home
    var homePath: [MobileRoute] = []
    var settingsPath: [MobileRoute] = []

    // iPad
    /// The thread the detail column shows; nil shows the overview.
    var padSelection: AgentRef?
    /// Screens pushed over the detail's root.
    var padPath: [MobileRoute] = []
    var padColumns: NavigationSplitViewVisibility = .automatic
    /// Portrait: the sidebar slides over the thread, so choosing a row hides it again; with no
    /// thread chosen it stays out.
    var padSidebarOverlays = false
    /// The side pane beside the thread on regular width, and the laptop arrangement.
    let sidePane = SidePaneState()
    /// iPhone Duo's hinge: true folded shut (the outer display), false open or half open (the
    /// inner one), nil on a device without a hinge (`onHingeClosedChange`).
    var hingeClosed: Bool?
    /// The thread whose composer has the focus in this window (`ThreadComposer`).
    @ObservationIgnored var focusedComposer: AgentRef?
    /// The composer to focus again as it mounts: the split view's change of style (a turn
    /// between portrait and landscape) builds its columns anew, and the keyboard would go down
    /// mid-draft (`PadShell`).
    @ObservationIgnored var refocusComposer: AgentRef?

    /// Window-local presentation. Operation/data stores remain shared across windows.
    let settingsSelection = SettingsSelection()
    let composerPresentation = ComposerPresentations()
    var commitPopover: AgentRef?

    /// A route shown modally over everything.
    var presented: PresentedRoute?

    /// The thread on screen, for highlighting its row.
    var selectedThread: AgentRef? {
        switch layout {
        case .pad:
            if case .thread(let ref)? = padPath.last { return ref }
            if let route = padPath.last { return route.thread }
            return padSelection
        case .phone:
            if case .thread(let ref)? = currentPhonePath.last { return ref }
            return currentPhonePath.last?.thread
        }
    }

    private var currentPhonePath: [MobileRoute] { tab == .home ? homePath : settingsPath }

    /// Shows `route` the way the current layout does: pushed on the current tab's stack on
    /// iPhone; on iPad a thread becomes the detail and anything else is pushed over it, a
    /// thread's runs or review over that thread. Settings screens open in the Settings tab on
    /// iPhone.
    func open(_ route: MobileRoute) {
        switch layout {
        case .phone:
            if case .settings(let settings) = route {
                tab = .settings
                // The tab's root is Settings itself.
                if settings == .root { settingsPath = [] } else if settingsPath.last != route { settingsPath.append(route) }
                return
            }
            if homePath.last != route { homePath.append(route) }
            tab = .home
        case .pad:
            // A thread's Changes, Terminal, Subagents, Files or Browser opens as the pane's tab
            // beside the thread, never as a screen over it.
            if let tab = route.sidePaneTab, let thread = route.thread {
                // Beside the thread on screen: the selection, or one pushed over the stack.
                if padPath.last != .thread(thread) {
                    if padSelection != thread { padSelection = thread }
                    if !padPath.isEmpty { padPath = [] }
                }
                showInPane(route, tab: tab)
                if padSidebarOverlays { padColumns = .detailOnly }
            } else if case .thread(let ref) = route {
                padSelection = ref
                if !padPath.isEmpty { padPath = [] }
                if padSidebarOverlays { padColumns = .detailOnly }
            } else if let thread = route.thread, thread != padSelection {
                // A thread's own screen (its runs, its review) opened from elsewhere, such as Needs
                // you or the palette: its thread becomes the selection under it, so the sidebar
                // marks it and closing the screen returns to it.
                padSelection = thread
                padPath = [route]
                if padSidebarOverlays { padColumns = .detailOnly }
            } else if padPath.last != route {
                padPath.append(route)
                if padSidebarOverlays { padColumns = .detailOnly }
            }
        }
    }

    /// Shows `route` modally (New thread, a host form).
    func present(_ route: MobileRoute) {
        presented = PresentedRoute(route: route)
    }

    func dismissPresented() {
        presented = nil
    }

    /// Back to the current stack's root.
    func popToRoot() {
        switch layout {
        case .phone:
            if tab == .home { homePath = [] } else { settingsPath = [] }
        case .pad:
            padPath = []
        }
    }

    /// Closes every screen of a forgotten host.
    func forget(host: UUID) {
        if settingsSelection.chosenHost == host { settingsSelection.chosenHost = nil }
        if settingsSelection.instructionsHost == host { settingsSelection.instructionsHost = nil }
        composerPresentation.forget(host: host)
        if commitPopover?.host == host { commitPopover = nil }
        homePath.removeAll { $0.host == host }
        settingsPath.removeAll { $0.host == host }
        padPath.removeAll { $0.host == host }
        if padSelection?.host == host {
            padSelection = nil
            padColumns = .all
        }
        if sidePane.arranged?.host == host { sidePane.arranged = nil }
        if presented?.route.host == host { presented = nil }
    }

    /// The pane shows `route` on `tab`: the file a review was opened at, the run a subagent link named.
    private func showInPane(_ route: MobileRoute, tab: PadSidePaneTab) {
        switch route {
        case .review(.changes(let ref, let file)): ReviewStores.shared.store(for: ref).focus(file)
        case .review(.diff(let ref, let path)): ReviewStores.shared.store(for: ref).focus(path)
        case .subagents(.list(let ref)): SubagentInspection.of(self).show(ref, runID: nil)
        case .subagents(.run(let ref, let runID)): SubagentInspection.of(self).show(ref, runID: runID)
        default: break
        }
        sidePane.show(tab)
    }

    /// Unfolded (or restored wide) with the selected thread's Changes, Terminal, Subagents, Files
    /// or Browser pushed over it: those screens become the open pane's tab (DuoClosedThreadMenu).
    func takePaneScreens() {
        // The thread under them: the last one pushed, else the selection.
        let pushed = padPath.lastIndex { if case .thread = $0 { true } else { false } }
        let thread: AgentRef? = if let pushed, case .thread(let ref) = padPath[pushed] { ref } else { padSelection }
        guard let thread else { return }
        let tabs = padPath.indices.map { index in
            index > (pushed ?? -1) && padPath[index].thread == thread ? padPath[index].sidePaneTab : nil
        }
        guard let (keep, tab) = PadSplitLayout.unfold(tabs), let top = padPath.last else { return }
        padPath = Array(padPath.prefix(keep))
        showInPane(top, tab: tab)
    }

    /// Carry the active stack across size classes, not an old selection from the other layout.
    func adopt(_ layout: Layout) {
        guard layout != self.layout else { return }
        switch layout {
        case .pad:
            let path = currentPhonePath
            padSelection = nil
            if tab == .settings {
                padPath = [.settings(.root)] + path
            } else if case .thread(let ref)? = path.first {
                padSelection = ref
                padPath = Array(path.dropFirst())
            } else {
                padPath = path
            }
            takePaneScreens()
        case .phone:
            let path = padSelection.map { [MobileRoute.thread($0)] } ?? []
            if case .settings? = padPath.last {
                tab = .settings
                settingsPath = path + padPath
                if settingsPath.first == .settings(.root) { settingsPath.removeFirst() }
            } else {
                tab = .home
                homePath = path + padPath
            }
        }
        self.layout = layout
        if layout == .phone {
            // The palette is the iPad's; a compact window gets search, pushed like the phone's.
            if case .search(.palette(let query))? = presented?.route {
                dismissPresented()
                open(.search(.search(query: query)))
            }
        }
    }
}
