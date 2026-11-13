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

    /// Sends the host this client is linked to one part of the manifest of a dispatch's snapshot, or asks where it stands
    /// (`FleetSnapshotPart.index` -1).
    public func fleetSnapshotPart(_ dispatchID: UUID, _ part: FleetSnapshotPart) async throws -> FleetSnapshotAck {
        try Self.snapshotAck(from: try await request { .fleetSnapshotPart(id: $0, dispatchID: dispatchID, part: part) })
    }

    /// Pushes a piece of a content the snapshot lacks there.
    public func fleetBlobPush(_ dispatchID: UUID, _ chunk: FleetBlobChunk) async throws -> FleetSnapshotAck {
        try Self.snapshotAck(from: try await request { .fleetBlobPush(id: $0, dispatchID: dispatchID, chunk: chunk) })
    }

    private static func snapshotAck(from reply: RemoteReply) throws -> FleetSnapshotAck {
        switch reply {
        case .fleetSnapshotAck(_, let ack): return ack
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }
}
