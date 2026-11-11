import Foundation
@testable import ShepherdApp
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

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

@MainActor
extension AppHarness {
    /// Waits for this Mac's app to tell its host it reaches `executor`, with `spaces` visible there
    /// (`ProjectExecutorsUpdate`): only then does the host's Project runtime accept or place on it.
    func hostReaches(_ executor: ProjectHostReference, spaces: [SpaceID] = []) async throws {
        let server = server
        try await eventuallyAsync("the host reaches the executor through the app") {
            await server.appProjectExecutors().contains { option in
                option.reference == executor && spaces.allSatisfy { id in option.spaces?.contains { $0.id == id } == true }
            }
        }
    }
}
