import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

/// The stores Settings ▸ MCP, Subagents and Sign-in read and change, served to remote clients
/// (`RemoteRequest.hostInventory` and `.hostConfig`) by the app or by the headless host.
@MainActor
struct HostStores {
    let mcp: MCPStore
    /// Made on first use; the app's view model makes it lazily.
    let subagents: @MainActor () -> SubagentDefinitionsModel
    let piAuth: PiAuthStore
    let yourPi: YourPiModel
    let remoteSignIns: RemoteSignIns

    var subagentDefinitions: SubagentDefinitionsModel { subagents() }

    /// Installs both handlers on `server`. Secrets a client sends go to the Keychain or pi's
    /// auth.json and are never in a reply or a log.
    func serve(on server: SessionServer) {
        server.onRemoteHostInventory = { request, completion in
            Task { @MainActor in
                do { completion(.success(try await hostInventory(request))) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        server.onRemoteHostConfig = { request, completion in
            Task { @MainActor in
                do { completion(.success(try await hostConfig(request))) }
                catch let error as RemoteCreateAgentError { completion(.failure(error)) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
    }

    /// The host with no app: what the app's view model does with a turn's error in process. A
    /// limit on a provider with rotation on switches accounts and continues the turn
    /// (`LimitRotation`), and a failed refresh reads Expired in Sign-in.
    func serveTurnErrors(on server: SessionServer) {
        let piAuth = piAuth
        let rotation = LimitRotation(server: server, piAuth: piAuth) { [weak server] agentID, line in
            server?.noticeToLocalApps(agentID: agentID, message: line)
        }
        server.onAgentProviderError = { agentID, provider, message in
            MainActor.assumeIsolated { rotation.providerError(agentID, provider: provider, message: message) }
        }
        let status = server.onAgentStatus
        server.onAgentStatus = { [weak server] id, agentStatus, failure in
            status?(id, agentStatus, failure)
            guard let message = failure?.message else { return }
            let model = server?.state.agents.first { $0.id == id }?.model
            let provider = model.flatMap { m in m.firstIndex(of: "/").flatMap { $0 == m.startIndex ? nil : String(m[..<$0]) } }
            MainActor.assumeIsolated { piAuth.noteTurnError(message, provider: provider) }
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
        await piAuth.landing?.value
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
        // Host-neutral: the client may be another Mac, and may sign in from there.
        case .signIn: "Not signed in"
        case .expired: "Expired"
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
        let several = (accounts?.accounts.count ?? 0) > 1
        return HostProviderStatus(id: row.id, name: row.name, badge: row.badge, auth: auth, detail: detail, problem: row.problem,
                                  accounts: accounts?.accounts.count ?? 0,
                                  activeAccount: accounts.flatMap { list in list.accounts.count > 1 ? list.accounts.first { $0.id == list.active }?.title : nil },
                                  accountList: several ? accounts?.accounts.map { account in
                                      HostProviderAccount(id: account.id, name: account.title, active: account.id == accounts?.active,
                                                          limitedUntil: account.limitedUntil?.timeIntervalSince1970)
                                  } : nil,
                                  rotate: several ? accounts?.rotate : nil)
    }
}
