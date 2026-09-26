import Foundation

// The MCP extension (`Extensions/shepherd-mcp.ts`) and the app: credentials asked for and handed
// over (`ExtensionMessage.mcpCredentials`, `ExtensionReply.mcpCredentials`), and each server's
// state and tools reported for Settings ▸ MCP servers (`ExtensionMessage.mcpReport`). Times are
// epoch milliseconds, never `Date`. Decoding is lenient where the extension omits empty values.

/// Why the extension asks for a server's credentials.
public enum MCPCredentialReason: String, Codable, Hashable, Sendable {
    /// Before connecting: the entry references Keychain items, or the server signs in with OAuth.
    case connect
    /// The server answered 401.
    case unauthorized
    /// The server answered 403 (`insufficient_scope`).
    case forbidden
}

/// What the app hands the extension for one server.
public struct MCPCredentials: Codable, Hashable, Sendable {
    /// An OAuth access token, sent as `Authorization: Bearer …`.
    public var bearer: String?
    /// Headers added to every HTTP request, over the entry's own.
    public var headers: [String: String]
    /// The values of the server's `${keychain:<server>/<NAME>}` references, keyed by `NAME`. The
    /// extension substitutes them wherever the reference appears (env, args, url, headers).
    public var env: [String: String]
    /// When `bearer` expires; the extension asks again 60 s before.
    public var expiresAtMs: Int64?

    public init(bearer: String? = nil, headers: [String: String] = [:], env: [String: String] = [:], expiresAtMs: Int64? = nil) {
        self.bearer = bearer
        self.headers = headers
        self.env = env
        self.expiresAtMs = expiresAtMs
    }

    private enum CodingKeys: String, CodingKey { case bearer, headers, env, expiresAtMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bearer = try c.decodeIfPresent(String.self, forKey: .bearer)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        expiresAtMs = try c.decodeIfPresent(Int64.self, forKey: .expiresAtMs)
    }
}

/// One tool a server lists (`tools/list`), as reported and cached.
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

    private enum CodingKeys: String, CodingKey { case name, title, description, inputSchema }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema) ?? .object([:])
    }
}

/// A server's state in one agent's pi.
public struct MCPServerStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case starting, connected, idle, needsSignIn, expired, needsScopes, error, off
    }

    public var state: State
    /// The scopes a 403 asked for; `needsScopes` only.
    public var scopes: [String]
    /// What went wrong, for `error` (and the agent-facing text for the sign-in states).
    public var message: String?

    public init(state: State, scopes: [String] = [], message: String? = nil) {
        self.state = state
        self.scopes = scopes
        self.message = message
    }

    private enum CodingKeys: String, CodingKey { case state, scopes, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

/// How a connection reached its server.
public enum MCPTransportKind: String, Codable, Hashable, Sendable {
    case stdio, streamableHTTP, sse
}

/// One server's state change, or its tool list, from one agent's pi.
public struct MCPServerReport: Codable, Hashable, Sendable {
    public var server: String
    public var status: MCPServerStatus
    public var transport: MCPTransportKind?
    /// `initialize`'s `serverInfo.title`, else its `name`.
    public var serverName: String?
    /// Present only after a `tools/list`.
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
