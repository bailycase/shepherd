import Foundation

// A host's configuration as a client changes it (Settings on the iPhone, the iPad and another
// Mac): its MCP servers, its subagent profiles, and its providers' sign-ins. The host's GUI does
// the work as its own Settings would (`SessionServer.onRemoteHostConfig`); a headless host has
// none. Secrets a client sends (an MCP secret, an API key, a pasted sign-in code) go one way:
// a reply never carries one, only the state the host's Settings row shows.

/// What a client changes on a host (`RemoteRequest.hostConfig`, `RemoteProtocol.hostConfigCapability`).
public enum RemoteHostConfigRequest: Codable, Hashable, Sendable {
    /// One server's entry as `{"mcpServers": {name: …}}` JSON for editing: Keychain secrets stay
    /// `${keychain:…}` references. Answers `.mcpEntry`.
    case mcpEntry(name: String)
    /// Adds a server, or replaces `replacing`, from `{"mcpServers": {name: …}}` JSON holding one.
    /// `secrets` are values for its env or header keys: the host keeps them in its Keychain and
    /// writes references. Answers `.mcp`.
    case mcpSave(json: String, secrets: [String: String], replacing: String?)
    case mcpSetEnabled(name: String, on: Bool)
    case mcpSetExposure(name: String, exposure: HostMCPExposure)
    /// nil offers every tool.
    case mcpSetTools(name: String, tools: [String]?)
    case mcpRemove(name: String)
    /// Adds every server of pasted JSON; `replace` overwrites those with the same name.
    case mcpImport(json: String, replace: Bool)
    /// Asks the host's pi for every server's state again.
    case mcpRefresh
    /// Starts an OAuth sign-in to a remote server on the host. Answers `.signIn`.
    case mcpSignIn(name: String)
    case mcpSignOut(name: String)

    /// Writes a profile; `fingerprint` is the text's the client read (`HostSubagentProfileText`),
    /// nil for a new file. A file changed since is refused. Answers `.subagent`.
    case subagentSave(file: String, text: String, fingerprint: String?)
    /// Answers `.subagents`.
    case subagentDelete(file: String, fingerprint: String)
    /// Puts the shipped profiles back, fenced by each default file's fingerprint as listed
    /// (`HostSubagentProfile.fingerprint`). Answers `.subagents`.
    case subagentRestoreDefaults(expected: [String: String])

    /// Saves an API key for a provider: the key itself, or `$NAME` for a variable the host's login
    /// shell sets. Answers `.providers`.
    case providerKey(provider: String, key: String)
    /// Signs the provider out of the host's pi. Answers `.providers`.
    case providerSignOut(provider: String)
    /// Starts an account sign-in on the host: its page opens on the client, which sends back the
    /// code the page shows (`signIn(.complete)`). Answers `.signIn`.
    case providerSignIn(provider: String)

    /// A sign-in under way (`mcpSignIn`, `providerSignIn`). Answers `.signIn`.
    case signIn(id: UUID, action: HostSignInAction)
}

public enum HostMCPExposure: String, Codable, Hashable, Sendable, CaseIterable {
    /// Searched with `tool_search` when an agent needs one.
    case proxy
    /// Every tool in every prompt.
    case direct
}

public enum HostSignInAction: Codable, Hashable, Sendable {
    case poll
    /// The code a provider's page showed, or for an MCP server the address the browser was sent
    /// back to (`http://127.0.0.1:…/callback?code=…`).
    case complete(String)
    case cancel
}

/// One sign-in under way on a host, as a client draws it. Never a token.
public struct HostSignInProgress: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case starting
        /// Waiting for the person: open `authorizationURL` (or the device page) and come back.
        case waiting
        case done
        case failed
    }

    public var id: UUID
    public var phase: Phase
    /// The provider or MCP server.
    public var name: String
    public var authorizationURL: String?
    /// A device sign-in: the code to enter at `authorizationURL`.
    public var deviceCode: String?
    /// The host waits for `complete`: a code from the page, or the address it ended on.
    public var wantsCode: Bool
    /// Why it failed, or what to do now.
    public var message: String?

    public init(id: UUID, phase: Phase, name: String, authorizationURL: String? = nil, deviceCode: String? = nil,
                wantsCode: Bool = false, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.name = name
        self.authorizationURL = authorizationURL
        self.deviceCode = deviceCode
        self.wantsCode = wantsCode
        self.message = message
    }
}

/// A host's answer: the shape the request names, as it is afterwards.
public enum RemoteHostConfigResult: Codable, Hashable, Sendable {
    case mcp(HostMCPInventory)
    case mcpEntry(json: String)
    case subagents([HostSubagentProfile])
    case subagent(HostSubagentProfileText)
    case providers([HostProviderStatus])
    case signIn(HostSignInProgress)
}
