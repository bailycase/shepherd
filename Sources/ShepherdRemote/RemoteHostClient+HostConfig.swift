import Foundation
import ShepherdProtocol

extension RemoteHostClient {
    /// Changes the host's MCP servers, subagent profiles, sign-ins or extensions (Settings on a client). A
    /// host without `hostConfigCapability` takes none: this throws `update_required` before
    /// sending anything, so a secret never reaches a host that can't use it.
    public func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
        guard supports(.hostConfig) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to change its MCP servers, subagents and sign-ins from here."
            )
        }
        switch request {
        case .extensionSetEnabled, .extensionRemove, .extensionAddGit:
            // An older host can't decode these and would answer with a decoding error.
            guard supports(.hostExtensions) else {
                throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to change its extensions from here.")
            }
        default: break
        }
        // Saving or refreshing a server connects it on the host; a key is checked with the provider.
        let timeout: TimeInterval = switch request {
        // Adding from Git clones the repository on the host.
        case .mcpSave, .mcpImport, .mcpRefresh, .mcpSetEnabled, .providerKey, .extensionAddGit: 120
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
