import Foundation
import ShepherdCore

// A host's inventory as a client reads it (Settings on the iPhone and the iPad): its MCP servers
// and their status, its subagent profiles, and its providers' sign-in state. Read-only: what the
// Mac's Settings ▸ MCP, Subagents and Sign-in show, never a secret. Changes go through
// `RemoteRequest.hostConfig` (HostConfig.swift).
// The host's GUI answers (`SessionServer.onRemoteHostInventory`); a headless host has none.

/// What a client asks of a host's inventory (`RemoteRequest.hostInventory`,
/// `RemoteProtocol.hostInventoryCapability`).
public enum RemoteHostInventoryRequest: Codable, Hashable, Sendable {
    /// The host's MCP servers, as Settings ▸ MCP lists them, each with its last known status.
    case mcp
    /// The host's subagent profiles (Settings ▸ Subagents).
    case subagents
    /// One profile's Markdown, by its file name as `subagents` gave it.
    case subagent(file: String)
    /// The host's providers and whether each is signed in (Settings ▸ Sign-in).
    case providers
}

/// A host's answer: the shape named by the request.
public enum RemoteHostInventoryResult: Codable, Hashable, Sendable {
    case mcp(HostMCPInventory)
    case subagents([HostSubagentProfile])
    case subagent(HostSubagentProfileText)
    case providers([HostProviderStatus])
}

/// One of a host's MCP servers, as its Settings row shows it.
public struct HostMCPServer: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case remote, local
    }

    /// The row's dot, in the Mac's words.
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case connected, starting, idle, needsYou, error, off
    }

    public var name: String
    public var kind: Kind
    /// The URL of a remote server, or the command line of a local one, as the Mac's row shows it.
    public var endpoint: String
    public var status: Status
    /// What replaces the endpoint line while it stands: "Starting…", or the last error.
    public var note: String?
    /// The Sign-in column in words ("Signed in", "Sign in", "Expired", "$GITHUB_TOKEN", "1 secret
    /// in Keychain"); never a token, key or header value.
    public var signIn: String?
    /// How many tools it offers; nil until known.
    public var tools: Int?
    public var enabled: Bool
    /// The fields below are sent by hosts with `hostConfigCapability`; nil from an older one.
    public var exposure: HostMCPExposure?
    /// The tools it offers, by name, once known.
    public var toolNames: [String]?
    /// The tools agents may use; nil for every one.
    public var allowedTools: [String]?
    /// A remote server that signs in with OAuth (`RemoteHostConfigRequest.mcpSignIn`).
    public var oauth: Bool?
    public var signedIn: Bool?

    public var id: String { name }

    public init(name: String, kind: Kind, endpoint: String, status: Status, note: String? = nil, signIn: String? = nil,
                tools: Int? = nil, enabled: Bool = true, exposure: HostMCPExposure? = nil, toolNames: [String]? = nil,
                allowedTools: [String]? = nil, oauth: Bool? = nil, signedIn: Bool? = nil) {
        self.exposure = exposure
        self.toolNames = toolNames
        self.allowedTools = allowedTools
        self.oauth = oauth
        self.signedIn = signedIn
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.status = status
        self.note = note
        self.signIn = signIn
        self.tools = tools
        self.enabled = enabled
    }
}

/// A host's MCP servers and how they were last read.
public struct HostMCPInventory: Codable, Hashable, Sendable {
    public var servers: [HostMCPServer]
    /// The host's `mcp.json`, abbreviated ("~/Library/…/mcp.json").
    public var configPath: String
    /// The file can't be read ("mcp.json line 12 isn't valid JSON"), or pi could not list.
    public var problem: String?
    /// When the host last asked its pi for every server's state; nil when it never has.
    public var checkedAt: Double?

    public init(servers: [HostMCPServer], configPath: String, problem: String? = nil, checkedAt: Double? = nil) {
        self.servers = servers
        self.configPath = configPath
        self.problem = problem
        self.checkedAt = checkedAt
    }
}

/// One subagent profile of a host: the Markdown file's front matter, as Settings ▸ Subagents lists it.
public struct HostSubagentProfile: Codable, Hashable, Sendable, Identifiable {
    /// Its file, relative to the host's profile folder ("reviewer.md", "team/scout.md").
    public var file: String
    public var name: String
    public var description: String?
    /// The tools it may use; nil for every tool.
    public var tools: [String]?
    /// "fork" when it starts from the parent's context.
    public var context: String?
    /// Why it did not load, when it didn't.
    public var error: String?
    public var disabled: Bool
    /// One Shepherd ships (scout, reviewer, planner, worker).
    public var isDefault: Bool
    /// The host's fingerprint of the file, for Restore defaults to check against; nil from an
    /// older host.
    public var fingerprint: String?

    public var id: String { file }

    public init(file: String, name: String, description: String? = nil, tools: [String]? = nil, context: String? = nil,
                error: String? = nil, disabled: Bool = false, isDefault: Bool = false, fingerprint: String? = nil) {
        self.fingerprint = fingerprint
        self.file = file
        self.name = name
        self.description = description
        self.tools = tools
        self.context = context
        self.error = error
        self.disabled = disabled
        self.isDefault = isDefault
    }
}

/// One profile's Markdown (`RemoteHostInventoryRequest.subagent`).
public struct HostSubagentProfileText: Codable, Hashable, Sendable {
    public var file: String
    public var text: String
    /// The host's fingerprint of the text, for a later edit to check against.
    public var fingerprint: String

    public init(file: String, text: String, fingerprint: String) {
        self.file = file
        self.text = text
        self.fingerprint = fingerprint
    }
}

/// One provider of a host's pi and how its sign-in stands, as Settings ▸ Sign-in's row says it.
/// Never a key, token or account identifier: a client shows the state and says to sign in on the host.
public struct HostProviderStatus: Codable, Hashable, Sendable, Identifiable {
    public enum Auth: String, Codable, Hashable, Sendable, CaseIterable {
        case signedIn
        /// pi said its refresh failed: sign in again on the host.
        case expired
        case notSignedIn
        case signingIn
        /// A key saved in the host's pi.
        case apiKey
        /// No stored key; the host's login shell sets the provider's variable.
        case environment
        /// A custom provider that needs no key.
        case noKey
    }

    /// pi's provider id ("anthropic", "openai-codex").
    public var id: String
    /// The row's title ("Anthropic", "OpenAI Codex").
    public var name: String
    /// "Subscription", "API key" or "Custom".
    public var badge: String
    public var auth: Auth
    /// The plan ("Claude Pro or Max"), the variable ("$OPENAI_API_KEY") or the base URL; never a value.
    public var detail: String?
    /// A failed sign-out, or another problem the Mac's row shows.
    public var problem: String?
    /// How many accounts the host saved for it, and the active one's name when there are several.
    public var accounts: Int
    public var activeAccount: String?

    public init(id: String, name: String, badge: String, auth: Auth, detail: String? = nil, problem: String? = nil,
                accounts: Int = 0, activeAccount: String? = nil) {
        self.id = id
        self.name = name
        self.badge = badge
        self.auth = auth
        self.detail = detail
        self.problem = problem
        self.accounts = accounts
        self.activeAccount = activeAccount
    }

    public var isSignedIn: Bool {
        switch auth {
        case .signedIn, .apiKey, .environment, .noKey: true
        case .expired, .notSignedIn, .signingIn: false
        }
    }
}
