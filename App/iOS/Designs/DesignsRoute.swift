import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The designs track's screens: a host's designs on the phone (MobileDesigns, MobileDesignBoard),
/// shown only for hosts that serve designs (`designs.v1`).
enum DesignsRoute: Hashable, Codable {
    /// Every host's designs and design systems (MobileDesigns), from Home's Designs row.
    case list
    /// One design's boards (not drawn: a grid of its boards), from a tile, Recents or search.
    case design(HostDesignRef)
    /// One board full screen (MobileDesignBoard).
    case board(HostDesignRef, path: String)
    /// Every board of a design to jump to (the board's Boards), presented.
    case boards(HostDesignRef, current: String)
    /// A new design from a brief (not drawn), presented: Search's New design, the Designs screen's +.
    case newDesign(brief: String, host: UUID?)
    /// The hosts' design systems (More ▸ Design systems).
    case systems
    /// One design system (not drawn): its colors, type and steps as the host read them.
    case system(host: UUID, namespace: String)

    /// The host it belongs to, so forgetting a host closes its screens.
    var host: UUID? {
        switch self {
        case .design(let ref), .board(let ref, _), .boards(let ref, _): ref.host
        case .newDesign(_, let host): host
        case .system(let host, _): host
        case .list, .systems: nil
        }
    }
}

/// Where other screens open designs (Home's row, Recents, search, More).
@MainActor
enum DesignsHooks {
    static func open(_ ref: HostDesignRef, navigator: MobileNavigator) {
        navigator.open(.designs(.design(ref)))
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
