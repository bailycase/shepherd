import Foundation
import ShepherdProtocol

/// Fleet's sync requests (`RemoteProtocol.fleetSyncCapability`, `FleetSyncWire.swift`), sent over
/// the link a host holds to a peer Mac.
extension RemoteHostClient {
    /// Sends one sync request and returns the peer's reply.
    public func fleetSync(_ request: FleetSyncRequest) async throws -> FleetSyncReply {
        let reply = try await self.request { .fleetSync(id: $0, request: request) }
        switch reply {
        case .fleetSyncReply(_, let answer): return answer
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    /// The peer's vector after `request` (hello, ops and op all answer with it).
    public func fleetSyncState(_ request: FleetSyncRequest) async throws -> FleetVersionVector {
        guard case .state(let vector) = try await fleetSync(request) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
        return vector
    }

    /// A whole blob from the peer, fetched in chunks and checked against its hash.
    public func fleetBlob(hash: String, size: Int) async throws -> Data {
        var data = Data()
        while true {
            guard case .blob(let named, let offset, let total, let chunk) = try await fleetSync(.blob(hash: hash, offset: data.count)),
                  named == hash, offset == data.count, total == size, total <= FleetSyncProtocol.maxBlobBytes else {
                throw RemoteHostClientError.rejected(code: FleetSyncProtocol.Code.invalid, message: "The peer sent a blob that doesn't match.")
            }
            data.append(chunk)
            if data.count >= total { break }
            if chunk.isEmpty { throw RemoteHostClientError.rejected(code: FleetSyncProtocol.Code.invalid, message: "The peer's blob ended early.") }
        }
        guard FleetSyncProtocol.hash(data) == hash else {
            throw RemoteHostClientError.rejected(code: FleetSyncProtocol.Code.invalid, message: "The blob doesn't match its hash.")
        }
        return data
    }
}
