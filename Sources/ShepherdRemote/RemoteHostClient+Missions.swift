import Foundation
import ShepherdCore
import ShepherdProtocol

extension RemoteHostClient {
    /// Why a host without `missionsCapability` shows no missions.
    public static let missionsRefusal = "Turn on Settings ▸ Experiments ▸ Missions on the host, or update Shepherd there, to use its missions."

    /// Reads or drives the host's missions (`missionsCapability`). A host without it throws
    /// `update_required` before anything is sent: an older Shepherd, or its experiment off.
    public func mission(_ request: RemoteMissionRequest) async throws -> RemoteMissionResult {
        guard capabilities.contains(RemoteProtocol.missionsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.missionsRefusal)
        }
        if Self.overFrame(.mission(id: 0, request: request)) {
            throw RemoteHostClientError.rejected(code: "too_large", message: "The change exceeds the remote payload limit.")
        }
        let read: Bool = switch request {
        case .list, .get, .reviewFile: true
        default: false
        }
        let reply = try await self.request(timeout: request.timeout, cancellable: read) { .mission(id: $0, request: request) }
        switch reply {
        case .mission(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected mission reply.")
        }
    }
}
