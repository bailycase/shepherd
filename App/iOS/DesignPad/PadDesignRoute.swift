import SwiftUI
import ShepherdCore

/// A design on one host.
struct PadDesignRef: Hashable, Codable, Sendable {
    var host: UUID
    var design: DesignID
}

/// The Design tool's screens on iPad (iPadDesign, iPadSplitView, iPadSidebar boards): the
/// Designs list the sidebar's row opens, and one design's canvas beside its chat. Only hosts
/// that offer `designs.v1` (their Design tool experiment on) have any.
enum PadDesignRoute: Hashable, Codable {
    /// Every connected host's designs.
    case list
    /// One design's canvas and chat.
    case design(PadDesignRef)

    var host: UUID? {
        switch self {
        case .list: nil
        case .design(let ref): ref.host
        }
    }
}

struct PadDesignDestination: View {
    let route: PadDesignRoute

    var body: some View {
        switch route {
        case .list: PadDesignsScreen()
        case .design(let ref): PadDesignScreen(ref: ref).id(ref)
        }
    }
}

@MainActor
enum PadDesignHooks {
    /// Opens a design's canvas. The canvas's "Designs" goes back to the list, so the list is
    /// always under it.
    static func open(_ ref: PadDesignRef, navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad:
            navigator.padPath = [.padDesign(.list), .padDesign(.design(ref))]
            if navigator.padSidebarOverlays { navigator.padColumns = .detailOnly }
        case .phone:
            navigator.open(.padDesign(.design(ref)))
        }
    }

    /// The Designs list, as the sidebar's row opens it.
    static func openList(navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad:
            navigator.padPath = [.padDesign(.list)]
            if navigator.padSidebarOverlays { navigator.padColumns = .detailOnly }
        case .phone:
            navigator.open(.padDesign(.list))
        }
    }
}
