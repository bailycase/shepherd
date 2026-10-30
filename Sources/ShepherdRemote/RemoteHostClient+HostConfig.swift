import Foundation
import ShepherdProtocol

extension RemoteHostClient {
    /// Changes the host's MCP servers, subagent profiles or sign-ins (Settings on a client). A
    /// host without `hostConfigCapability` takes none: this throws `update_required` before
    /// sending anything, so a secret never reaches a host that can't use it.
    public func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
        guard capabilities.contains(RemoteProtocol.hostConfigCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to change its MCP servers, subagents and sign-ins from here."
            )
        }
        // Saving or refreshing a server connects it on the host; a key is checked with the provider.
        let timeout: TimeInterval = switch request {
        case .mcpSave, .mcpImport, .mcpRefresh, .mcpSetEnabled, .providerKey: 120
        default: RemoteHostClient.requestTimeout
        }
        let reply = try await self.request(timeout: timeout) { .hostConfig(id: $0, request: request) }
        switch reply {
        case .hostConfig(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected configuration reply")
        }
    }
}
