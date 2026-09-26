import Foundation
import ShepherdCore
import ShepherdProtocol

/// An agent's MCP extension asks for one server's credentials (`ExtensionMessage.mcpCredentials`).
/// The app owns the Keychain and OAuth, so the server hands the request to `onMCPRequest`.
public struct MCPRequest: Hashable, Sendable {
    public var agentID: AgentID
    public var server: String
    public var reason: MCPCredentialReason
    /// A 401's or 403's raw `WWW-Authenticate`.
    public var challenge: String?

    public init(agentID: AgentID, server: String, reason: MCPCredentialReason, challenge: String? = nil) {
        self.agentID = agentID
        self.server = server
        self.reason = reason
        self.challenge = challenge
    }
}

/// The app's answer, before the server stamps it with the request id. A failure's `code` is one
/// of `needs_sign_in`, `expired`, `needs_scopes`, `missing_secret`, `no_such_server` or
/// `mcp_unavailable`, and its `message` is written for the agent to read.
public enum MCPOutcome: Hashable, Sendable {
    case credentials(MCPCredentials)
    case failure(code: String, message: String)

    public func withID(_ id: Int) -> ExtensionReply {
        switch self {
        case .credentials(let credentials):
            return .mcpCredentials(id: id, credentials: credentials)
        case .failure(let code, let message):
            return .error(id: id, code: code, message: message)
        }
    }
}
