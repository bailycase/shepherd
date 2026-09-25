import SwiftUI

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

    /// A route shown modally over everything.
    var presented: PresentedRoute?

    /// The thread on screen, for highlighting its row.
    var selectedThread: AgentRef? {
        switch layout {
        case .pad: return padSelection
        case .phone:
            if case .thread(let ref)? = currentPhonePath.last { return ref }
            return nil
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
            if case .thread(let ref) = route {
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
        homePath.removeAll { $0.host == host }
        settingsPath.removeAll { $0.host == host }
        padPath.removeAll { $0.host == host }
        if padSelection?.host == host {
            padSelection = nil
            padColumns = .all
        }
        if presented?.route.host == host { presented = nil }
    }

    /// The layout changed (a window resized across the size classes): carry the thread on
    /// screen across, so rotating or resizing never loses the place.
    func adopt(_ layout: Layout) {
        guard layout != self.layout else { return }
        let thread = selectedThread
        self.layout = layout
        switch layout {
        case .pad:
            padSelection = thread ?? padSelection
            padPath = []
        case .phone:
            if let thread = padSelection, homePath.last != .thread(thread) {
                tab = .home
                homePath = [.thread(thread)]
            }
            // The palette is the iPad's; a compact window gets search, pushed like the phone's.
            if case .search(.palette(let query))? = presented?.route {
                dismissPresented()
                open(.search(.search(query: query)))
            }
        }
    }
}
