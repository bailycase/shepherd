import Foundation
@testable import ShepherdApp
import ShepherdCore

extension ShepherdState {
    /// The session a host bound to `pane`, as its state says.
    func session(boundTo pane: PaneID) -> SessionID? {
        tabs.lazy.compactMap { $0.layout.leaf(withID: pane)?.sessionID }.first
    }
}

@MainActor
extension AppHarness {
    /// The host's Missions and Project runtime.
    var missions: MissionController { host!.runtime!.missions }
    var coordinator: ProjectCoordinatorController { host!.runtime!.coordinator }
}
