import Foundation
@testable import ShepherdApp
import ShepherdCore
import ShepherdSessions

/// The view model has no server, Missions or Project runtime of its own (always-host 7b). Until the
/// tests that still read them move to the harness, these read the harness's server and its host's runtime.
@MainActor
extension ShepherdViewModel {
    private var harness: AppHarness {
        guard let harness = AppHarness.started[ObjectIdentifier(self)]?.harness else { fatalError("a view model no AppHarness started") }
        return harness
    }
    var server: SessionServer { harness.server }
    var missions: MissionController { harness.host!.runtime!.missions }
    var projectCoordinator: ProjectCoordinatorController { harness.host!.runtime!.coordinator }
}

extension AppHarness {
    struct Weak { weak var harness: AppHarness? }
}

@MainActor
extension ShepherdViewModel {
    /// The session the host bound to a pane, as its state says.
    func hostTerminalSession(_ pane: PaneID) -> SessionID? {
        state.tabs.lazy.compactMap { $0.layout.leaf(withID: pane)?.sessionID }.first
    }
}
