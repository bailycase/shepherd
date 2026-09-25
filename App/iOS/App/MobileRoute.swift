import SwiftUI

/// Every screen the app can show, iPhone and iPad alike. The shell knows only the top level: a
/// thread, and one case per track that wraps the track's own route enum (defined in its
/// folder, with its own destination view). A track adds screens by adding cases to its own
/// enum; it never edits this file or the shell.
///
/// Codable so the screenshot fixtures can name a screen in JSON.
enum MobileRoute: Hashable, Codable {
    case thread(AgentRef)
    case home(HomeRoute)
    case newThread(NewThreadRoute)
    case subagents(SubagentsRoute)
    case review(ReviewRoute)
    case search(SearchRoute)
    case settings(SettingsRoute)
    case terminal(TerminalRoute)
    case automations(AutomationsRoute)

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .thread(let ref): ThreadScreen(ref: ref)
        case .home(let route): HomeDestination(route: route)
        case .newThread(let route): NewThreadDestination(route: route)
        case .subagents(let route): SubagentsDestination(route: route)
        case .review(let route): ReviewDestination(route: route)
        case .search(let route): SearchDestination(route: route)
        case .settings(let route): SettingsDestination(route: route)
        case .terminal(let route): TerminalDestination(route: route)
        case .automations(let route): AutomationsDestination(route: route)
        }
    }

    /// The host a route belongs to, so forgetting a host closes its screens.
    var host: UUID? {
        switch self {
        case .thread(let ref): ref.host
        case .subagents(let route): route.thread.host
        case .review(let route): route.thread.host
        case .terminal(let route): route.thread.host
        case .automations(let route): route.host
        case .home, .newThread, .search, .settings: nil
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
        navigationDestination(for: MobileRoute.self) { $0.destination }
    }
}
