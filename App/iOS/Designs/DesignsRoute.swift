import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Where other screens open designs (Recents, search, Settings).
@MainActor
enum DesignsHooks {
    /// A design's boards on the phone; in the iPad's split view, its canvas (DesignPad/).
    static func open(_ ref: HostDesignRef, navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad: PadDesignHooks.open(PadDesignRef(host: ref.host, design: ref.design), navigator: navigator)
        case .phone: navigator.open(.designs(.design(ref)))
        }
    }

    static func create(brief: String = "", host: UUID? = nil, navigator: MobileNavigator) {
        navigator.present(.designs(.newDesign(brief: brief, host: host)))
    }
}

struct DesignsDestination: View {
    let route: DesignsRoute

    var body: some View {
        switch route {
        case .list: DesignsScreen()
        case .design(let ref): DesignBoardsScreen(ref: ref)
        case .board(let ref, let path): DesignBoardScreen(ref: ref, path: DesignPath(path))
        case .boards(let ref, let current): DesignBoardsSheet(ref: ref, current: DesignPath(current))
        case .newDesign(let brief, let host): NewDesignScreen(brief: brief, host: host)
        case .systems: DesignSystemsScreen()
        case .system(let host, let namespace): DesignSystemScreen(host: host, namespace: namespace)
        }
    }
}
