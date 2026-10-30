import Foundation
import ShepherdProtocol

/// Settings ▸ MCP, Subagents, Sign-in and Spaces on the iPhone and the iPad: each row's words and
/// tone from a host's inventory, as the Mac's pages say them. Pure, so it has a unit test.
public enum HostInventoryPresentation {
    /// A row's tone, named as an `AgentState` raw value so this module needs no ShepherdUI:
    /// "done" for connected and signed in, "attention" for needs-you and expired, "failed", "idle".
    public enum Tone: String, Sendable, Hashable {
        case running, attention, done, failed, idle
    }

    // MARK: MCP

    /// "Connected", "Starting", "Not checked yet", "Needs you", "Failed", "Off".
    public static func statusWord(_ status: HostMCPServer.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .starting: "Starting"
        case .idle: "Not checked yet"
        case .needsYou: "Needs you"
        case .error: "Failed"
        case .off: "Off"
        }
    }

    public static func tone(_ status: HostMCPServer.Status) -> Tone {
        switch status {
        case .connected: .done
        case .starting: .running
        case .needsYou: .attention
        case .error: .failed
        case .idle, .off: .idle
        }
    }

    /// The row's status line: the error while there is one, else the endpoint; "12 tools" when known.
    public static func serverLine(_ server: HostMCPServer) -> String {
        var parts: [String] = []
        if let note = server.note { parts.append(note) } else { parts.append(server.endpoint) }
        if let tools = server.tools { parts.append(tools == 1 ? "1 tool" : "\(tools) tools") }
        return parts.joined(separator: " · ")
    }

    /// MCP's value on the Settings list: "3 · 1 failed", "Off", or nil before a host says.
    public static func mcpValue(_ inventory: HostMCPInventory) -> String {
        let on = inventory.servers.filter(\.enabled)
        guard !on.isEmpty else { return inventory.servers.isEmpty ? "None" : "Off" }
        let trouble = on.filter { $0.status == .error || $0.status == .needsYou }.count
        return trouble == 0 ? String(on.count) : "\(on.count) · \(trouble) need\(trouble == 1 ? "s" : "") you"
    }

    /// What the page says under the servers: configure on the Mac, and where the file is.
    public static func mcpGuidance(host: String, configPath: String) -> String {
        "Add, edit, reconnect or sign in to a server in Settings ▸ MCP on \(host). The servers are read from \(configPath)."
    }

    // MARK: Subagents

    /// "read-only · fork", "can edit", as the Mac's list says.
    public static func capability(_ profile: HostSubagentProfile) -> String {
        let readOnly = profile.tools.map { $0.allSatisfy { ["read", "grep", "find", "ls", "shepherd_parent_message"].contains($0) } } ?? false
        return (readOnly ? "read-only" : "can edit") + (profile.context == "fork" ? " · fork" : "")
    }

    /// The row's status line: the error, "disabled", else its description.
    public static func profileLine(_ profile: HostSubagentProfile) -> String? {
        if let error = profile.error { return error }
        if profile.disabled { return "Disabled" }
        return profile.description
    }

    public static func tone(_ profile: HostSubagentProfile) -> Tone {
        profile.error != nil ? .failed : profile.disabled ? .idle : .done
    }

    /// A server's sign-in column as a client shows it. An older host wrote it for its own Mac
    /// ("Sign in on the Mac"): those words read as the state alone.
    public static func signInWord(_ column: String?) -> String? {
        switch column {
        case "Sign in on the Mac": "Not signed in"
        case "Expired · sign in on the Mac": "Expired"
        default: column
        }
    }

    // MARK: Providers

    /// The row's word: "Signed in", "Expired · sign in again", "Not signed in", "Signing in…",
    /// "API key", "From the host’s environment", "No key needed". Host-neutral: a client may be
    /// another Mac, and the host may take a sign-in from it (`hostConfig.v1`).
    public static func authWord(_ auth: HostProviderStatus.Auth) -> String {
        switch auth {
        case .signedIn: "Signed in"
        case .expired: "Expired · sign in again"
        case .notSignedIn: "Not signed in"
        case .signingIn: "Signing in…"
        case .apiKey: "API key"
        case .environment: "From the host’s environment"
        case .noKey: "No key needed"
        }
    }

    public static func tone(_ auth: HostProviderStatus.Auth) -> Tone {
        switch auth {
        case .signedIn, .apiKey, .environment: .done
        case .expired: .attention
        case .signingIn: .running
        case .notSignedIn, .noKey: .idle
        }
    }

    /// The row's status line: the word, its detail, and the accounts when there are several.
    public static func providerLine(_ provider: HostProviderStatus) -> String {
        var parts = [authWord(provider.auth)]
        if let detail = provider.detail, !detail.isEmpty { parts.append(detail) }
        if provider.accounts > 1 {
            parts.append(provider.activeAccount.map { "\(provider.accounts) accounts · \($0)" } ?? "\(provider.accounts) accounts")
        }
        return parts.joined(separator: " · ")
    }

    /// A saved account's line: "In use", "Saved", or "Limited until 3:40 PM".
    public static func accountLine(_ account: HostProviderAccount, now: Date = Date()) -> String {
        if let until = account.limitedUntil.map(Date.init(timeIntervalSince1970:)), until > now {
            return "Limited until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return account.active ? "In use" : "Saved"
    }

    /// Sign-in's value on the Settings list: "1 needs you" when a sign-in expired or a provider is
    /// not signed in, else how many are signed in.
    public static func providersValue(_ providers: [HostProviderStatus]) -> String {
        let attention = providers.filter { $0.auth == .expired }.count
        if attention > 0 { return "\(attention) expired" }
        let signedIn = providers.filter(\.isSignedIn).count
        return signedIn == 0 ? "None" : String(signedIn)
    }

    public static func providersGuidance(host: String) -> String {
        "Sign in, sign out, add an API key or switch accounts in Settings ▸ Sign-in on \(host). Keys and tokens stay there."
    }

    // MARK: Spaces

    /// A space's status line: its summary, or why it can't be read.
    public static func spaceLine(_ project: ProjectSummary) -> String {
        project.error ?? project.summary
    }

    public static func tone(_ project: ProjectSummary) -> Tone {
        project.error != nil ? .failed : project.minimal ? .idle : .done
    }

    /// "Trusted" or "Not yet approved": a space's executable resources (skills, extensions, MCP)
    /// load only once approved on the Mac; nil when the host did not say.
    public static func trustWord(_ trusted: Bool?) -> String? {
        trusted.map { $0 ? "Approved on the host" : "Not yet approved" }
    }

    public static func spacesGuidance(host: String) -> String {
        "Edit a space's instructions, pi settings and MCP file, or approve its resources, in Settings ▸ Spaces on \(host)."
    }
}
