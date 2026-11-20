import SwiftUI
import ShepherdCore
import ShepherdRemote

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
