import Foundation
import ShepherdProtocol

extension RemoteHostClient {
    /// Reads the host's MCP servers, subagent profiles or providers (Settings on the iPhone and
    /// the iPad), read-only. A host without `hostInventoryCapability` has none to share: this
    /// throws `update_required` before sending anything.
    public func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult {
        guard capabilities.contains(RemoteProtocol.hostInventoryCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to see its MCP servers, subagents and sign-ins from here."
            )
        }
        // Listing MCP servers connects every one of them on the host.
        let timeout: TimeInterval = request == .mcp ? 120 : RemoteHostClient.requestTimeout
        let reply = try await self.request(timeout: timeout) { .hostInventory(id: $0, request: request) }
        switch reply {
        case .hostInventory(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected inventory reply")
        }
    }
}
