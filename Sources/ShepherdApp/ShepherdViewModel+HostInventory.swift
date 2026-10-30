import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

extension ShepherdViewModel {
    /// Serves this Mac's MCP servers, subagent profiles and provider sign-ins to remote clients
    /// (Settings on the iPhone and the iPad), read-only: what Settings ▸ MCP, Subagents and
    /// Sign-in show, projected without any secret. Installed once at startup.
    func installHostInventory() {
        server.onRemoteHostInventory = { [weak self] request, completion in
            MainActor.assumeIsolated {
                guard let self else {
                    completion(.failure(RemoteCreateAgentError("Host is shutting down")))
                    return
                }
                Task { @MainActor in
                    do { completion(.success(try await self.hostInventory(request))) }
                    catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
                }
            }
        }
    }

    private func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult {
        switch request {
        case .mcp:
            // As the Mac's page does on appearing: the file, then pi's listing when it is stale.
            mcp.reload()
            mcp.refreshIfStale()
            await mcp.settle()
            return .mcp(HostInventoryMapping.mcp(mcp))
        case .subagents:
            let store = subagentDefinitions.store
            let definitions = try await Task.detached(priority: .userInitiated) { try store.snapshot() }.value
            return .subagents(definitions.map(HostInventoryMapping.profile))
        case .subagent(let file):
            guard SubagentDefinitionsStore.acceptsFilename(file) else { throw RemoteCreateAgentError("Not a subagent file.") }
            let store = subagentDefinitions.store
            let opened = try await Task.detached(priority: .userInitiated) { try store.open(file) }.value
            return .subagent(HostSubagentProfileText(file: opened.file, text: opened.text, fingerprint: opened.fingerprint))
        case .providers:
            return .providers(await hostProviders())
        }
    }

    /// Settings ▸ Sign-in's rows, read afresh, as a client sees them.
    func hostProviders() async -> [HostProviderStatus] {
        await yourPi.refresh()
        await piAuth.refreshAccounts()
        let signingIn = piAuth.session.flatMap { $0.phase.isLive ? $0.provider : nil }
        let page = PiSignInPage.make(survey: yourPi.survey ?? YourPiSurvey(), signingIn: signingIn, expired: piAuth.expired,
                                     needed: piAuth.needed, problems: piAuth.problems, accounts: piAuth.accounts)
        return (page.subscriptions + page.apiKeys + page.customProviders).map(HostInventoryMapping.provider)
    }
}

/// The Mac's rows as a remote client sees them.
@MainActor
enum HostInventoryMapping {
    static func mcp(_ store: MCPStore) -> HostMCPInventory {
        let checkedAt: Double? = if case .done(let date) = store.listing { date.timeIntervalSince1970 } else { nil }
        return HostMCPInventory(servers: store.rows.map { server($0, entry: store.entry($0.name), store: store) }, configPath: store.configPath,
                                problem: store.invalidMessage ?? store.problem, checkedAt: checkedAt)
    }

    static func server(_ row: MCPServerRowModel, entry: MCPServerEntry? = nil, store: MCPStore? = nil) -> HostMCPServer {
        let note: String? = switch row.note {
        case .starting(let text)?: text
        case .error(let text)?: text
        case nil: nil
        }
        return HostMCPServer(name: row.name, kind: row.kind == .remote ? .remote : .local, endpoint: row.endpoint,
                             status: HostMCPServer.Status(rawValue: row.status.rawValue) ?? .idle, note: note,
                             signIn: signIn(row.signIn), tools: row.tools, enabled: row.enabled,
                             exposure: entry.map { $0.settings.exposure == .direct ? .direct : .proxy },
                             toolNames: entry.flatMap { store?.toolNames(of: $0) }, allowedTools: entry?.settings.tools,
                             oauth: entry.flatMap { store?.usesOAuth($0) },
                             signedIn: { if case .account = row.signIn { true } else { false } }())
    }

    /// The Sign-in column in words, never a value.
    static func signIn(_ cell: MCPServerRowModel.SignIn) -> String? {
        switch cell {
        case .account(let name): name
        case .signIn: "Sign in on the Mac"
        case .expired: "Expired · sign in on the Mac"
        case .moreAccess(let scopes): "Needs more access" + (scopes.isEmpty ? "" : ": " + scopes.joined(separator: ", "))
        case .variable(let name): name
        case .secret(let name): name + " in Keychain"
        case .variables(let count): "\(count) variables"
        case .missingSecret(let name): name + " missing from Keychain"
        case .unverified: "Not checked yet"
        case .none: nil
        }
    }

    static func profile(_ definition: SubagentDefinitionsStore.Definition) -> HostSubagentProfile {
        HostSubagentProfile(file: definition.file, name: definition.name, description: definition.description, tools: definition.tools,
                            context: definition.context, error: definition.error, disabled: definition.disabled ?? false,
                            isDefault: definition.isDefault, fingerprint: definition.fingerprint)
    }

    static func provider(_ row: ProviderRowModel) -> HostProviderStatus {
        let auth: HostProviderStatus.Auth
        var detail: String?
        switch row.auth {
        case .signedIn(let plan): auth = .signedIn; detail = plan
        case .expired(let plan): auth = .expired; detail = plan
        case .notSignedIn(let plan): auth = .notSignedIn; detail = plan
        case .signingIn(let plan): auth = .signingIn; detail = plan
        case .key(let display, _):
            // The variable it reads, never the key's mask.
            auth = .apiKey
            detail = display.runsCommand ? "command not supported" : display.variables.first.map { "$" + $0 }
        case .environment(let variable): auth = .environment; detail = "$" + variable
        case .noKey(let baseURL): auth = .noKey; detail = baseURL
        }
        let accounts = row.accounts
        return HostProviderStatus(id: row.id, name: row.name, badge: row.badge, auth: auth, detail: detail, problem: row.problem,
                                  accounts: accounts?.accounts.count ?? 0,
                                  activeAccount: accounts.flatMap { list in list.accounts.count > 1 ? list.accounts.first { $0.id == list.active }?.name : nil })
    }
}
