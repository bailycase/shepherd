import Foundation
@testable import ShepherdApp
import ShepherdCore
import ShepherdTestSupport
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

/// A view model a test made itself, taking `scratch`'s server as its host as `ShepherdApp` does.
@MainActor
func connectAsHost(_ vm: ShepherdViewModel, to scratch: ScratchServer) async throws {
    let socket = scratch.dir.appendingPathComponent("h.sock").path, tokenURL = scratch.dir.appendingPathComponent("remote-token")
    try scratch.server.startLocalListener(path: socket, tokenURL: tokenURL)
    let connection = vm.connectLocalHost(socket: socket, token: try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    try await eventuallyOnMain("the host's workspace", timeout: .seconds(30)) { connection.phase == .connected && vm.state == scratch.server.state }
}
