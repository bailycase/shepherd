import Foundation
import ShepherdCore
import ShepherdProtocol

extension RemoteHostClient {
    /// Pushes one step of what this Mac holds of a repository to the host this client authenticated to as a peer
    /// (`RemoteProtocol.fleetSnapshotCapability`). The answer says where the host's copy stands, and whether it
    /// needs everything again.
    public func fleetRepoManifest(_ update: FleetRepoManifestUpdate) async throws -> FleetRepoManifestAck {
        switch try await request({ .fleetRepoManifest(id: $0, update: update) }) {
        case .fleetRepoManifestAck(_, let ack): return ack
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }
}
