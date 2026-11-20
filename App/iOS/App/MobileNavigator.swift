import SwiftUI
import ShepherdRemote

/// Where the app is: one model for iPhone (five tabs, each a stack) and iPad (a sidebar, the
/// selected thread as the detail, and a stack pushed over it). Screens never touch paths
/// directly; they call `open` or `present`, and the navigator puts the route where the current
/// layout shows it.
@MainActor
@Observable
final class MobileNavigator {
    typealias Tab = MobileTab

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
    @ObservationIgnored private(set) var recentPadThreads: [AgentRef] = []
    var padSelection: AgentRef? {
        didSet {
            guard let padSelection, padSelection != oldValue else { return }
            recentPadThreads.removeAll { $0 == padSelection }
            recentPadThreads.append(padSelection)
        }
    }
    /// Screens pushed over the detail's root.
    var padPath: [MobileRoute] = []
    var padColumns: NavigationSplitViewVisibility = .automatic
    /// Portrait: the sidebar slides over the thread, so choosing a row hides it again; with no
    /// thread chosen it stays out.
    var padSidebarOverlays = false
    /// iPhone Duo half open (`PadShell`): Issues & PRs then splits the window at the fold, its
    /// list on one side and the item on the other, with the sidebar out (DuoBookPR).
    var padFolded = false
    /// Issues & PRs shows a pull request beside its diff (iPadPRChanges): the sidebar steps aside.
    var padForgeDiff = false
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
        MobileDiagnostics.record(.open, route: route)
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
        MobileDiagnostics.record(.present, route: route)
        presented = PresentedRoute(route: route)
    }

    func dismissPresented() {
        if let presented { MobileDiagnostics.record(.dismiss, route: presented.route) }
        presented = nil
    }

    /// Back to the current stack's root.
    func popToRoot() {
        MobileDiagnostics.record(.popToRoot)
        switch layout {
        case .phone:
            self[path: tab] = []
        case .pad:
            padPath = []
        }
    }

    /// Closes every screen of a forgotten host.
    func forget(host: UUID) {
        recentPadThreads.removeAll { $0.host == host }
        composerPresentation.forget(host: host)
        if commitPopover?.host == host { commitPopover = nil }
        for tab in Tab.allCases {
            self[path: tab] = NavigationCarry.removing(host: host, from: self[path: tab])
        }
        padPath = NavigationCarry.removing(host: host, from: padPath)
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
        guard let pane = NavigationCarry.takePaneScreens(selection: padSelection, path: padPath) else { return }
        padPath = pane.path
        showInPane(pane.route, tab: pane.tab)
    }

    /// Carry the active stack across size classes, not an old selection from the other layout.
    func adopt(_ layout: Layout) {
        guard layout != self.layout else { return }
        switch layout {
        case .pad:
            let carry = NavigationCarry.widen(tab: tab, path: currentPhonePath)
            padSelection = nil
            if let selection = carry.selection { padSelection = selection }
            padPath = carry.path
            takePaneScreens()
            self.layout = layout
        case .phone:
            let carry = NavigationCarry.narrow(selection: padSelection, path: padPath, presented: presented?.route)
            tab = carry.tab
            self[path: carry.tab] = carry.path
            self.layout = layout
            if let search = carry.search {
                dismissPresented()
                open(search)
            }
        }
    }
}
