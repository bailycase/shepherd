import Foundation
import ShepherdCore

// MCP servers (stage 1): what the MCP extension inside each pi and the app say to each other.
// The extension owns the connections; the app owns config writes, the Keychain, OAuth and the
// Settings status. Times on the wire are epoch milliseconds, never `Date`.

/// Why the extension asks for a server's credentials.
public enum MCPCredentialReason: String, Codable, Hashable, Sendable {
    /// Before connecting: the entry has `${keychain:…}` references, or the server uses OAuth.
    case connect
    /// The server answered 401.
    case unauthorized
    /// The server answered 403 `insufficient_scope`.
    case forbidden
}

/// What the app hands the extension for one server: an OAuth bearer, resolved
/// `${keychain:…}` values for headers and env, and when the bearer expires.
public struct MCPCredentials: Codable, Hashable, Sendable {
    public var bearer: String?
    public var headers: [String: String]
    public var env: [String: String]
    public var expiresAtMs: Int64?

    public init(bearer: String? = nil, headers: [String: String] = [:], env: [String: String] = [:], expiresAtMs: Int64? = nil) {
        self.bearer = bearer
        self.headers = headers
        self.env = env
        self.expiresAtMs = expiresAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bearer = try c.decodeIfPresent(String.self, forKey: .bearer)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        expiresAtMs = try c.decodeIfPresent(Int64.self, forKey: .expiresAtMs)
    }
}

/// One tool a server lists (`tools/list`).
public struct MCPToolInfo: Codable, Hashable, Sendable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, title: String? = nil, description: String = "", inputSchema: JSONValue = .object([:])) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema) ?? .object([:])
    }
}

/// A server's state as one pi (or the app's probe) sees it.
public struct MCPServerStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case starting, connected, idle, needsSignIn, expired, needsScopes, error, off
    }

    public var state: State
    /// The missing scopes, for `needsScopes` only.
    public var scopes: [String]
    /// The error's text, for `error`.
    public var message: String?

    public init(state: State, scopes: [String] = [], message: String? = nil) {
        self.state = state
        self.scopes = scopes
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

public enum MCPTransportKind: String, Codable, Hashable, Sendable {
    case stdio, streamableHTTP, sse
}

/// Sent on every state change of a server, and after every `tools/list`.
public struct MCPServerReport: Codable, Hashable, Sendable {
    public var server: String
    public var status: MCPServerStatus
    public var transport: MCPTransportKind?
    /// `initialize`'s `serverInfo.title ?? name`.
    public var serverName: String?
    /// Only after a list.
    public var tools: [MCPToolInfo]?

    public init(server: String, status: MCPServerStatus, transport: MCPTransportKind? = nil, serverName: String? = nil,
                tools: [MCPToolInfo]? = nil) {
        self.server = server
        self.status = status
        self.transport = transport
        self.serverName = serverName
        self.tools = tools
    }
}

/// An MCP credentials request as the server hands it to the app (`SessionServer.onMCPRequest`).
public struct MCPRequest: Hashable, Sendable {
    public var agentID: AgentID
    public var server: String
    public var reason: MCPCredentialReason
    /// The raw `WWW-Authenticate` value from a 401, or from a 403 `insufficient_scope`.
    public var challenge: String?

    public init(agentID: AgentID, server: String, reason: MCPCredentialReason, challenge: String? = nil) {
        self.agentID = agentID
        self.server = server
        self.reason = reason
        self.challenge = challenge
    }
}

/// The app's answer to an `MCPRequest`.
public enum MCPOutcome: Hashable, Sendable {
    case credentials(MCPCredentials)
    /// `code` is one of `MCPFailureCode`; `message` is written for the agent to read.
    case failure(code: String, message: String)

    public func withID(_ id: Int) -> ExtensionReply {
        switch self {
        case .credentials(let credentials): .mcpCredentials(id: id, credentials: credentials)
        case .failure(let code, let message): .error(id: id, code: code, message: message)
        }
    }
}

/// The error codes an MCP credentials request fails with.
public enum MCPFailureCode {
    public static let needsSignIn = "needs_sign_in"
    public static let expired = "expired"
    public static let needsScopes = "needs_scopes"
    public static let missingSecret = "missing_secret"
    public static let noSuchServer = "no_such_server"
    public static let unavailable = "mcp_unavailable"
}
