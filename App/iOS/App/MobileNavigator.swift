import SwiftUI
import ShepherdRemote

/// Where the app is: one model for iPhone (five tabs, each a stack) and iPad (a sidebar, the
/// selected thread as the detail, and a stack pushed over it). Screens never touch paths
/// directly; they call `open` or `present`, and the navigator puts the route where the current
/// layout shows it.
@MainActor
@Observable
final class MobileNavigator {
    /// The phone's tabs (DuoClosedHome board). Codable as their case names, so a window saved
    /// with only Home and Settings restores as it was.
    enum Tab: Hashable, Codable, CaseIterable {
        case home, designs, projects, automations, settings
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
    var designsPath: [MobileRoute] = []
    var projectsPath: [MobileRoute] = []
    var automationsPath: [MobileRoute] = []
    var settingsPath: [MobileRoute] = []

    /// A tab's stack.
    subscript(path tab: Tab) -> [MobileRoute] {
        get {
            switch tab {
            case .home: homePath
            case .designs: designsPath
            case .projects: projectsPath
            case .automations: automationsPath
            case .settings: settingsPath
            }
        }
        set {
            switch tab {
            case .home: homePath = newValue
            case .designs: designsPath = newValue
            case .projects: projectsPath = newValue
            case .automations: automationsPath = newValue
            case .settings: settingsPath = newValue
            }
        }
    }

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

    private var currentPhonePath: [MobileRoute] { self[path: tab] }

    /// Shows `route` the way the current layout does. On iPhone it selects the route's tab
    /// first (`Tab.landing`), then pushes it on that tab's stack, or empties the stack for the
    /// tab's own root; on iPad a thread becomes the detail and anything else is pushed over it,
    /// a thread's runs or review over that thread.
    func open(_ route: MobileRoute) {
        switch layout {
        case .phone:
            let target = Tab.landing(of: route, from: tab)
            tab = target
            if route.isTabRoot {
                if !self[path: target].isEmpty { self[path: target] = [] }
            } else if self[path: target].last != route {
                self[path: target].append(route)
            }
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

    /// Shows `route` from outside the screen on show (a notification, a window's first route):
    /// a thread lands in Home whatever tab was chosen, rather than on top of another tab's stack.
    func reveal(_ route: MobileRoute) {
        if layout == .phone, Tab.owner(of: route) == nil { tab = .home }
        open(route)
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
            self[path: tab] = []
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
        for tab in Tab.allCases { self[path: tab].removeAll { $0.host == host } }
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
            if let root = tab.padRoot {
                padPath = [root] + path
            } else if case .thread(let ref)? = path.first {
                padSelection = ref
                padPath = Array(path.dropFirst())
            } else {
                padPath = path
            }
            takePaneScreens()
        case .phone:
            // The last screen with a tab of its own picks the tab, and the stack from it on
            // goes there (without the tab's root, which the tab shows itself); a thread and its
            // screens with none go to Home.
            let stack = (padSelection.map { [MobileRoute.thread($0)] } ?? []) + padPath
            if let start = stack.lastIndex(where: { Tab.owner(of: $0) != nil }), let owner = Tab.owner(of: stack[start]) {
                tab = owner
                // Home keeps what lies under its screen (a thread chosen before Needs you).
                self[path: owner] = owner == .home ? stack : Array(stack[start...].drop(while: \.isTabRoot))
            } else {
                tab = .home
                homePath = stack
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

extension MobileNavigator.Tab {
    /// The tab a route belongs to on iPhone; nil for a screen that opens over whatever tab
    /// opened it (a thread and its screens, search, design systems).
    static func owner(of route: MobileRoute) -> Self? {
        switch route {
        case .settings, .home(.more): .settings
        case .home(.automations), .automations: .automations
        case .home(.needsYou), .home(.recents): .home
        case .designs(.systems), .designs(.system): nil
        case .designs, .padDesign: .designs
        case .projects: .projects
        case .thread, .subagents, .review, .terminal, .search, .newThread: nil
        }
    }

    /// Where `route` opens on iPhone when `current` is the selected tab: its own tab, else the
    /// current one. Settings keeps only its own screens and design systems (More's, now
    /// Settings'); a thread or search opened there goes to Home.
    static func landing(of route: MobileRoute, from current: Self) -> Self {
        if let owner = owner(of: route) { return owner }
        if current == .settings, !route.isDesignSystems { return .home }
        return current
    }

    /// What iPad pushes for this tab's root when a compact window widens; nil for Home, whose
    /// root is the overview.
    var padRoot: MobileRoute? {
        switch self {
        case .home: nil
        case .designs: .padDesign(.list)
        case .projects: .projects(.list)
        case .automations: .home(.automations)
        case .settings: .settings(.root)
        }
    }
}

extension MobileRoute {
    /// A screen the phone shows as a tab's root rather than pushing it: opening it selects the
    /// tab and returns to its root.
    var isTabRoot: Bool {
        switch self {
        case .settings(.root), .home(.more), .home(.automations), .designs(.list), .padDesign(.list), .projects(.list): true
        default: false
        }
    }

    fileprivate var isDesignSystems: Bool {
        switch self {
        case .designs(.systems), .designs(.system): true
        default: false
        }
    }
}
