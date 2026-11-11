import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Peer threads (`SessionServer.serveAgentPeers`), served in process through the view model so
/// spawned threads, deletion and moves follow the app's normal paths.
@MainActor
extension ShepherdViewModel {
    func installAgentPeerControl() {
        server.serveAgentPeers(AgentPeerHosting(
            defaults: { [unowned self] in (settings.defaultModel(piHome: pi.home), settings.defaultThinking) },
            startAgent: { [unowned self] config in try await startAgent(config, selectAfter: false) },
            deleteAgent: { [unowned self] id, done in deleteAgent(id, completion: done) },
            moveThread: { [unowned self] id, spaceID in try await moveThread(id, to: spaceID) }))
    }
}
