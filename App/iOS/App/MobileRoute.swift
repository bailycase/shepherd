import SwiftUI
import ShepherdRemote

extension MobileRoute {
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .thread(let ref): ThreadDestination(ref: ref)
        case .home(let route): HomeDestination(route: route)
        case .newThread(let route): NewThreadDestination(route: route)
        case .subagents(let route): SubagentsDestination(route: route)
        case .review(let route): ReviewDestination(route: route)
        case .search(let route): SearchDestination(route: route)
        case .settings(let route): SettingsDestination(route: route)
        case .terminal(let route): TerminalDestination(route: route)
        case .automations(let route): AutomationsDestination(route: route)
        case .designs(let route): DesignsDestination(route: route)
        case .padDesign(let route): PadDesignDestination(route: route)
        case .projects(let route): ProjectsDestination(route: route)
        case .sidePane(let route): SidePaneDestination(route: route)
        case .browser(let route): BrowserDestination(route: route)
        case .forge(let route): ForgeDestination(route: route)
        }
    }
}

/// A route shown modally (a sheet on iPhone, a form sheet on iPad).
struct PresentedRoute: Identifiable, Hashable {
    let id = UUID()
    let route: MobileRoute
}

extension View {
    /// Resolves pushed routes in a navigation stack. Every stack in the app applies it once.
    func mobileDestinations() -> some View {
        navigationDestination(for: MobileRoute.self) { $0.destination.modifier(DuoTopEdge()) }
    }
}
