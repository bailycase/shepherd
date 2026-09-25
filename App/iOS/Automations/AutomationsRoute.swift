import SwiftUI
import ShepherdCore
import ShepherdRemote

/// The automations track's screens, pushed from the list (`.home(.automations)`) or presented.
enum AutomationsRoute: Hashable, Codable {
    /// One automation: its details, its runs, Run now and Stop (iPhone; the iPad shows it beside
    /// the list).
    case detail(host: UUID, automation: AutomationID)
    /// The form: a new automation (`automation` nil, on `host` or the first host that takes
    /// one), or an existing one's name, prompt, folder and switch. Presented.
    case edit(host: UUID?, automation: AutomationID?)

    var host: UUID? {
        switch self {
        case .detail(let host, _): host
        case .edit(let host, _): host
        }
    }
}

struct AutomationsDestination: View {
    let route: AutomationsRoute

    var body: some View {
        switch route {
        case .detail(let host, let automation):
            AutomationDetailScreen(key: AutomationKey(host: host, automation: automation))
        case .edit(let host, let automation):
            AutomationEditorScreen(host: host, automation: automation)
        }
    }
}

/// How the other screens reach automations.
@MainActor
enum AutomationsHooks {
    /// Opens one automation: pushed on iPhone; on iPad the list opens with it selected.
    static func open(_ key: AutomationKey, navigator: MobileNavigator) {
        switch navigator.layout {
        case .phone:
            navigator.open(.automations(.detail(host: key.host, automation: key.automation)))
        case .pad:
            AutomationsStore.choose(key)
            navigator.open(.home(.automations))
        }
    }

    /// The form for a new automation.
    static func create(host: UUID? = nil, navigator: MobileNavigator) {
        navigator.present(.automations(.edit(host: host, automation: nil)))
    }
}

extension MobileNavigator {
    /// Closes `route` when it is the screen on top of the current stack, leaving the ones under it.
    func close(_ route: MobileRoute) {
        switch layout {
        case .phone:
            if tab == .home, homePath.last == route { homePath.removeLast() }
        case .pad:
            if padPath.last == route { padPath.removeLast() }
        }
    }
}
