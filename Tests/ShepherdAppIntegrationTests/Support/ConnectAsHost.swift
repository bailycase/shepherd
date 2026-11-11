import Foundation
@testable import ShepherdApp
import ShepherdCore
import ShepherdTestSupport
import ShepherdSessions

/// A view model a test made itself, taking `scratch`'s server as its host as `ShepherdApp` does.
@MainActor
func connectAsHost(_ vm: ShepherdViewModel, to scratch: ScratchServer) async throws {
    let socket = scratch.dir.appendingPathComponent("h.sock").path, tokenURL = scratch.dir.appendingPathComponent("remote-token")
    try scratch.server.startLocalListener(path: socket, tokenURL: tokenURL)
    let connection = vm.connectLocalHost(socket: socket, token: try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    try await eventuallyOnMain("the host's workspace", timeout: .seconds(30)) { connection.phase == .connected && vm.state == scratch.server.state }
}
