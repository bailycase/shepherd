import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// Settings ▸ MCP servers' one store. The extension inside each pi owns the connections; the app
/// owns the config file, the Keychain, OAuth and refresh, the tools cache, and what each row
/// says. A row's status comes from, in order: the entry's switch, the app's own OAuth state, any
/// live agent reporting it connected, a recent probe or report that failed, one starting, else
/// idle.
@MainActor
@Observable
final class MCPStore {
    struct Dependencies {
        var file: MCPConfigFile
        var cacheURL: URL
        var secrets: MCPSecretStore
        var http: MCPHTTP
        var probe: MCPProbe
        var openURL: @MainActor (URL) -> Void
        var copy: @MainActor (String) -> Void
        var now: @MainActor () -> Date

        /// The app's: the real file and Keychain, node for probes, the browser and pasteboard.
        static func app(clientPath: @escaping @Sendable () -> URL?, openURL: @escaping @MainActor (URL) -> Void,
                        copy: @escaping @MainActor (String) -> Void) -> Dependencies {
            Dependencies(file: MCPConfigFile(url: ShepherdPaths.mcpConfigURL()), cacheURL: ShepherdPaths.mcpToolsCacheURL(),
                         secrets: MCPSecrets.forApp(), http: URLSessionHTTP(),
                         probe: MCPProbe(runner: NodeProbeRunner(clientPath: clientPath)),
                         openURL: openURL, copy: copy, now: { Date() })
        }
    }

    /// The app's own OAuth state for a server, which wins over what agents report.
    enum OAuthFlag: Equatable {
        case needsSignIn
        case expired
        case needsScopes([String])
    }

    enum Filter: Hashable { case all, connected, needsYou }

    struct Budget: Equatable {
        var tokens: String
        var fraction: Double
        var note: String
    }

    /// A tools cache entry: `{entry, listedAtMs, tools}`.
    struct CachedTools: Codable, Equatable {
        var entry: [String: JSONValue]
        var listedAtMs: Int64
        var tools: [MCPToolInfo]
    }

    private struct Seen {
        var status: MCPServerStatus
        var at: Date
        var transport: MCPTransportKind?
        var serverName: String?
    }

    // MARK: Observed

    private(set) var document = MCPConfigDocument()
    /// The file doesn't parse: editing is off until it does.
    private(set) var invalidLine: Int?
    private(set) var rows: [MCPServerRowModel] = []
    private(set) var details: [String: MCPServerDetailModel] = [:]
    private(set) var budget = Budget(tokens: "~0 tokens", fraction: 0, note: "")
    private(set) var connectedCount = 0
    var problem: String?
    /// The sign-in sheet, while one runs.
    var signIn: MCPSignInFlow?

    // MARK: Bookkeeping

    @ObservationIgnored let dependencies: Dependencies
    @ObservationIgnored private var reports: [AgentID: [String: Seen]] = [:]
    @ObservationIgnored private var probes: [String: Seen] = [:]
    @ObservationIgnored private var probing: Set<String> = []
    @ObservationIgnored private(set) var cache: [String: CachedTools] = [:]
    @ObservationIgnored private var flags: [String: OAuthFlag] = [:]
    @ObservationIgnored private var usesOAuth: Set<String> = []
    @ObservationIgnored private var challenges: [String: String] = [:]
    @ObservationIgnored private var tokens: [String: MCPOAuthToken?] = [:]
    @ObservationIgnored private var refreshes: [String: Task<MCPOAuthToken, Error>] = [:]
    @ObservationIgnored private var fileStamp: Data?
    /// A needs-sign-in answer opens the sheet by itself ("Open sign-in pages by itself").
    @ObservationIgnored var onNeedsSignIn: ((String) -> Void)?

    /// Reports and probes older than this no longer count as an error.
    static let errorWindow: TimeInterval = 10 * 60

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        cache = Self.readCache(dependencies.cacheURL)
        reload()
    }

    var configPath: String {
        let path = dependencies.file.url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var isEditable: Bool { invalidLine == nil }

    var invalidMessage: String? { invalidLine.map { MCPConfigError.invalid(line: $0).description } }

    // MARK: Reading

    /// Reads the file again (the page appearing, a request after someone else edited it).
    func reload() {
        let data = try? Data(contentsOf: dependencies.file.url)
        guard data != fileStamp || rows.isEmpty && document.root.isEmpty else { return }
        fileStamp = data
        switch MCPConfigFile.parse(data ?? Data()) {
        case .document(let parsed):
            invalidLine = nil
            if document != parsed { document = parsed }
        case .invalid(let line):
            if invalidLine != line { invalidLine = line }
        }
        rebuild()
    }

    func entry(_ name: String) -> MCPServerEntry? { document.server(name) }

    /// Tools as the app last saw them, only while the entry is unchanged.
    func tools(of entry: MCPServerEntry) -> [MCPToolInfo]? {
        guard let cached = cache[entry.name], cached.entry == entry.withoutShepherd else { return nil }
        return cached.tools
    }

    func count(_ filter: Filter) -> Int {
        rows.filter { matches($0, filter) }.count
    }

    func rows(filter: Filter, query: String) -> [MCPServerRowModel] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            matches(row, filter) && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query)
                || row.endpoint.localizedCaseInsensitiveContains(query))
        }
    }

    private func matches(_ row: MCPServerRowModel, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .connected: row.status == .connected
        case .needsYou: row.status == .needsYou || row.status == .error
        }
    }

    // MARK: Status

    /// A server's state, in the contract's order.
    func status(of entry: MCPServerEntry) -> MCPServerStatus {
        if !entry.settings.enabled { return MCPServerStatus(state: .off) }
        switch flags[entry.name] {
        case .needsSignIn: return MCPServerStatus(state: .needsSignIn)
        case .expired: return MCPServerStatus(state: .expired)
        case .needsScopes(let scopes): return MCPServerStatus(state: .needsScopes, scopes: scopes)
        case nil: break
        }
        if usesOAuth(entry), token(for: entry) == nil { return MCPServerStatus(state: .needsSignIn) }
        let seen = reports.values.compactMap { $0[entry.name] }
        if seen.contains(where: { $0.status.state == .connected }) { return MCPServerStatus(state: .connected) }
        let now = dependencies.now()
        let recent = (seen + [probes[entry.name]].compactMap { $0 })
            .filter { now.timeIntervalSince($0.at) < Self.errorWindow }
            .sorted { $0.at > $1.at }
        if let latest = recent.first, [.error, .needsSignIn, .expired, .needsScopes].contains(latest.status.state) {
            return latest.status
        }
        if probing.contains(entry.name) || seen.contains(where: { $0.status.state == .starting }) {
            return MCPServerStatus(state: .starting)
        }
        return MCPServerStatus(state: .idle)
    }

    /// The `${keychain:…}` values that aren't in Keychain, by variable name.
    func missingSecrets(_ entry: MCPServerEntry) -> [String] {
        Self.secretReferences(entry)
            .filter { dependencies.secrets.value(for: MCPSecretReference.account(server: $0.server, name: $0.name)) == nil }
            .map(\.name)
    }

    /// Every `${keychain:…}` an entry holds, wherever the extension expands it, once each.
    static func secretReferences(_ entry: MCPServerEntry) -> [(server: String, name: String)] {
        let values = [entry.command ?? ""] + entry.args + entry.env.keys.sorted().compactMap { entry.env[$0] } + [entry.url ?? ""]
            + entry.headers.keys.sorted().compactMap { entry.headers[$0] }
        var seen: Set<String> = []
        return values.flatMap(MCPSecretReference.references(in:)).filter { seen.insert("\($0.server)/\($0.name)").inserted }
    }

    private func hasAuthHeader(_ entry: MCPServerEntry) -> Bool {
        entry.headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    /// Whether the app signs this server in: a remote server with no Authorization header that
    /// has a token, asked for one, or has OAuth settings.
    func usesOAuth(_ entry: MCPServerEntry) -> Bool {
        guard entry.kind == .remote, !hasAuthHeader(entry) else { return false }
        return usesOAuth.contains(entry.name) || token(entry.name) != nil || !entry.settings.oauth.isEmpty
    }

    func token(_ server: String) -> MCPOAuthToken? {
        if let cached = tokens[server] { return cached }
        let token = dependencies.secrets.value(for: MCPSecretReference.oauthAccount(server: server))
            .flatMap { try? JSONDecoder().decode(MCPOAuthToken.self, from: Data($0.utf8)) }
        tokens[server] = token
        return token
    }

    /// The saved token, only while it belongs to the entry's server: an entry whose URL moved to
    /// another origin must sign in again rather than hand the old server's token to the new one.
    func token(for entry: MCPServerEntry) -> MCPOAuthToken? {
        guard let token = token(entry.name), let url = entry.url.flatMap(URL.init(string:)),
              let resource = URL(string: token.resource),
              MCPOAuthService.origin(of: url) == MCPOAuthService.origin(of: resource) else { return nil }
        return token
    }

    private func saveToken(_ token: MCPOAuthToken?, for server: String) throws {
        let account = MCPSecretReference.oauthAccount(server: server)
        if let token {
            let data = try JSONEncoder().encode(token)
            try dependencies.secrets.set(String(decoding: data, as: UTF8.self), for: account)
        } else {
            dependencies.secrets.remove(account)
        }
        tokens[server] = token
    }

    // MARK: Rows

    /// Derives every row, detail and the budget once per change.
    func rebuild() {
        let entries = document.servers
        var rows: [MCPServerRowModel] = []
        var details: [String: MCPServerDetailModel] = [:]
        var budgetInput: [(exposure: MCPExposure, tools: [MCPToolInfo], chosen: [String]?)] = []
        var proxyTools = 0
        var directNames: [String] = []
        for entry in entries {
            let status = status(of: entry)
            let missing = missingSecrets(entry)
            let tools = tools(of: entry)
            let settings = entry.settings
            rows.append(row(entry, status: status, missing: missing, tools: tools))
            details[entry.name] = detail(entry, status: status, missing: missing, tools: tools)
            if settings.enabled {
                budgetInput.append((settings.exposure, tools ?? [], settings.tools))
                let visible = MCPBudgetEstimate.visible(tools ?? [], chosen: settings.tools).count
                if settings.exposure == .proxy { proxyTools += visible } else { directNames.append(entry.name) }
            }
        }
        let total = MCPBudgetEstimate.total(budgetInput)
        let note: String
        if budgetInput.isEmpty {
            note = "No servers yet. Each one you add costs nothing until the agent needs it."
        } else if directNames.isEmpty {
            note = "One mcp tool finds and calls any of the \(proxyTools) tools. Servers set to “Each tool” add their tools here."
        } else {
            note = "One mcp tool finds and calls any of the \(proxyTools) tools; \(directNames.formatted(.list(type: .and))) "
                + (directNames.count == 1 ? "adds its" : "add their") + " tools here."
        }
        let budget = Budget(tokens: MCPBudgetEstimate.longLabel(total), fraction: Double(total) / 8000, note: note)
        let connected = rows.filter { $0.status == .connected }.count
        if self.rows != rows { self.rows = rows }
        if self.details != details { self.details = details }
        if self.budget != budget { self.budget = budget }
        if connectedCount != connected { connectedCount = connected }
    }

    private static func dot(_ status: MCPServerStatus, missing: Bool) -> MCPDotState {
        switch status.state {
        case .off: return .off
        case .needsSignIn, .expired, .needsScopes: return .needsYou
        case .error: return .error
        case _ where missing: return .needsYou
        case .connected: return .connected
        case .starting: return .starting
        case .idle: return .idle
        }
    }

    private func row(_ entry: MCPServerEntry, status: MCPServerStatus, missing: [String], tools: [MCPToolInfo]?) -> MCPServerRowModel {
        let note: MCPServerRowModel.Note? = switch status.state {
        case .starting: .starting("Starting on This Mac…")
        case .error: .error(status.message ?? "Couldn’t start.")
        default: nil
        }
        return MCPServerRowModel(
            name: entry.name, kind: entry.kind == .remote ? .remote : .local, endpoint: entry.endpoint,
            status: Self.dot(status, missing: !missing.isEmpty), note: note, signIn: signInCell(entry, status: status, missing: missing),
            tools: tools.map { MCPBudgetEstimate.visible($0, chosen: entry.settings.tools).count }, enabled: entry.settings.enabled)
    }

    private func signInCell(_ entry: MCPServerEntry, status: MCPServerStatus, missing: [String]) -> MCPServerRowModel.SignIn {
        if let first = missing.first { return .missingSecret(first) }
        if entry.kind == .remote {
            if let auth = entry.headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })
                ?? entry.headers.first {
                if let variable = MCPSecretReference.variable(in: auth.value) { return .variable("$" + variable) }
                if let reference = MCPSecretReference.references(in: auth.value).first { return .secret(reference.name) }
                return .secret(auth.key)
            }
            guard usesOAuth(entry) else { return .none }
            switch status.state {
            case .needsScopes: return .moreAccess(status.scopes)
            case .expired: return .expired
            case .needsSignIn: return .signIn
            default: return token(for: entry).map { .account($0.account ?? "Signed in") } ?? .signIn
            }
        }
        let keys = entry.env.keys.sorted()
        switch keys.count {
        case 0: return .none
        case 1: return .secret(keys[0])
        default: return .variables(keys.count)
        }
    }

    private func detail(_ entry: MCPServerEntry, status: MCPServerStatus, missing: [String], tools: [MCPToolInfo]?) -> MCPServerDetailModel {
        let settings = entry.settings
        let signIn: MCPServerDetailModel.SignIn
        if entry.kind == .remote, let auth = entry.headers.sorted(by: { $0.key < $1.key }).first(where: {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) ?? entry.headers.sorted(by: { $0.key < $1.key }).first {
            let variable = MCPSecretReference.variable(in: auth.value).map { "$" + $0 }
                ?? MCPSecretReference.references(in: auth.value).first.map { "\($0.name) (Keychain)" } ?? "a value in mcp.json"
            signIn = .header(name: auth.key, variable: variable)
        } else if usesOAuth(entry) {
            let token = token(for: entry)
            switch status.state {
            case .needsScopes:
                signIn = .needsSignIn(title: "Needs " + status.scopes.joined(separator: ", "),
                                      note: "The server asked for more access. Sign in again to grant it.", again: true)
            case .expired:
                signIn = .needsSignIn(title: "Expired", note: "The sign-in couldn’t be refreshed.", again: true)
            case _ where token == nil:
                signIn = .needsSignIn(title: "Not signed in", note: "It uses OAuth: sign in once and Shepherd keeps the token fresh.",
                                      again: false)
            default:
                let refreshed = token.map { Self.ago(Date(timeIntervalSince1970: TimeInterval($0.refreshedAtMs) / 1000), now: dependencies.now()) } ?? ""
                signIn = .signedIn(account: token?.account, scopes: token?.scopes ?? [], note: "OAuth · refreshed \(refreshed)")
            }
        } else if entry.kind == .local, !entry.env.isEmpty {
            signIn = .secrets(names: entry.env.keys.sorted(), missing: missing)
        } else {
            signIn = .none
        }
        let all = tools ?? []
        let visible = MCPBudgetEstimate.visible(all, chosen: settings.tools)
        let transport = (reports.values.compactMap { $0[entry.name]?.transport }.first ?? probes[entry.name]?.transport) ?? entry.transport
        let hostDetail: (String, MCPServerDetailModel.Host.Mark) = switch status.state {
        case .connected: ("connected", .done)
        case .starting: ("starting", .working)
        case .error: ("failed", .failed)
        case .off: ("off", .none)
        case .needsSignIn, .expired, .needsScopes: ("needs you", .none)
        case .idle: (settings.start == .whenUsed ? "connects when used" : "idle", .offline)
        }
        return MCPServerDetailModel(
            signIn: signIn,
            toolNames: all.map(\.name),
            toolCount: tools.map { _ in all.count },
            direct: settings.exposure == .direct,
            proxyCost: MCPBudgetEstimate.shortLabel(MCPBudgetEstimate.proxyTokens),
            directCost: tools == nil ? "—" : MCPBudgetEstimate.shortLabel(MCPBudgetEstimate.directTokens(all, chosen: settings.tools)),
            chosenNote: settings.tools == nil ? nil : "\(visible.count) of \(all.count) chosen",
            transport: Self.transportName(transport),
            startOptions: MCPStartMode.allCases.map(\.title),
            start: MCPStartMode.allCases.firstIndex(of: settings.start) ?? 0,
            hosts: [.init(name: "This Mac", detail: hostDetail.0, mark: hostDetail.1)],
            message: status.state == .error ? status.message : nil)
    }

    static func transportName(_ transport: MCPTransportKind) -> String {
        switch transport {
        case .stdio: "stdio"
        case .streamableHTTP: "Streamable HTTP"
        case .sse: "HTTP+SSE"
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    // MARK: Editing

    /// Edits the file in one step and reads the result back.
    private func edit(_ change: (inout MCPConfigDocument) throws -> Void) throws {
        let written = try dependencies.file.update(change)
        fileStamp = try? Data(contentsOf: dependencies.file.url)
        invalidLine = nil
        if document != written { document = written }
        rebuild()
    }

    /// Runs an edit and puts its failure on the page.
    @discardableResult
    func perform(_ change: (inout MCPConfigDocument) throws -> Void) -> Bool {
        do {
            try edit(change)
            if problem != nil { problem = nil }
            return true
        } catch let error as MCPConfigError {
            if case .invalid(let line) = error { invalidLine = line }
            problem = error.description
        } catch {
            problem = "\(error)"
        }
        return false
    }

    /// Adds (or with `replacing`, replaces) a server. `secrets` are values the user typed for its
    /// env or header keys: they go to Keychain and the file gets references.
    func save(_ entry: MCPServerEntry, secrets: [String: String] = [:], replacing: String? = nil) throws {
        var entry = entry
        for (key, value) in secrets {
            try dependencies.secrets.set(value, for: MCPSecretReference.account(server: entry.name, name: key))
        }
        try MCPImport.moveSecrets(&entry, to: dependencies.secrets)
        try edit { document in
            if let replacing, replacing != entry.name { document.remove(replacing) }
            document.upsert(entry)
        }
        flags[entry.name] = nil
        rebuild()
        probe(entry.name)
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        update(name) { $0.enabled = enabled }
    }

    func setExposure(_ name: String, _ exposure: MCPExposure) {
        update(name) { $0.exposure = exposure }
    }

    func setTools(_ name: String, _ tools: [String]?) {
        update(name) { $0.tools = tools }
    }

    func setStart(_ name: String, _ start: MCPStartMode) {
        update(name) { $0.start = start }
    }

    private func update(_ name: String, _ change: (inout MCPShepherdSettings) -> Void) {
        perform { document in
            guard var entry = document.server(name) else { return }
            var settings = entry.settings
            change(&settings)
            entry.settings = settings
            document.upsert(entry)
        }
    }

    /// Deletes the entry and its Keychain items.
    func remove(_ name: String) {
        guard perform({ $0.remove(name) }) else { return }
        dependencies.secrets.removeAll(forServer: name)
        tokens[name] = nil
        flags[name] = nil
        usesOAuth.remove(name)
        probes[name] = nil
        cache[name] = nil
        writeCache()
        rebuild()
    }

    /// The entry as `mcpServers` JSON, without Shepherd's fields; secrets stay references.
    func json(for name: String) -> String? {
        guard let entry = document.server(name) else { return nil }
        return MCPJSON.write(.object([MCPConfigDocument.serversKey: .object([name: .object(entry.withoutShepherd)])]))
    }

    func copyJSON(_ name: String) {
        guard let json = json(for: name) else { return }
        dependencies.copy(json)
    }

    // MARK: Import

    func clashes(_ entries: [MCPServerEntry]) -> [String] {
        let names = Set(document.servers.map(\.name))
        return entries.map(\.name).filter(names.contains)
    }

    /// Adds `entries`, replacing the clashing ones only when `replace` is true. Returns how many
    /// were added.
    @discardableResult
    func importEntries(_ entries: [MCPServerEntry], replace: Bool) throws -> Int {
        let existing = Set(document.servers.map(\.name))
        var added: [MCPServerEntry] = []
        for var entry in entries where replace || !existing.contains(entry.name) {
            try MCPImport.moveSecrets(&entry, to: dependencies.secrets)
            added.append(entry)
        }
        guard !added.isEmpty else { return 0 }
        try edit { document in
            for entry in added { document.upsert(entry) }
        }
        for entry in added { probe(entry.name) }
        return added.count
    }

    // MARK: Reports and probes

    func receive(_ report: MCPServerReport, from agentID: AgentID) {
        reports[agentID, default: [:]][report.server] = Seen(status: report.status, at: dependencies.now(),
                                                             transport: report.transport, serverName: report.serverName)
        if let tools = report.tools, let entry = document.server(report.server) { remember(tools, for: entry) }
        rebuild()
    }

    /// Reports of agents that are gone no longer count.
    func retainReports(of live: Set<AgentID>) {
        let gone = reports.keys.filter { !live.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { reports[id] = nil }
        rebuild()
    }

    private func remember(_ tools: [MCPToolInfo], for entry: MCPServerEntry) {
        let cached = CachedTools(entry: entry.withoutShepherd, listedAtMs: Self.ms(dependencies.now()), tools: tools)
        guard cache[entry.name]?.entry != cached.entry || cache[entry.name]?.tools != cached.tools else { return }
        cache[entry.name] = cached
        writeCache()
    }

    /// Probes every enabled server the cache doesn't know (the page appearing).
    func probeUnknown() {
        for entry in document.servers where entry.settings.enabled && tools(of: entry) == nil && probes[entry.name] == nil {
            probe(entry.name)
        }
    }

    /// At launch: the always-on servers.
    func probeAlwaysOn() {
        for entry in document.servers where entry.settings.enabled && entry.settings.start == .alwaysOn {
            probe(entry.name)
        }
    }

    func probe(_ name: String) {
        guard let entry = document.server(name), entry.settings.enabled, !probing.contains(name) else { return }
        guard missingSecrets(entry).isEmpty else { rebuild(); return }
        if usesOAuth(entry), token(for: entry) == nil { rebuild(); return }
        probing.insert(name)
        rebuild()
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolvedForProbe(entry)
            let result = await self.dependencies.probe.probe(name: name, entry: resolved,
                                                             timeoutSeconds: entry.settings.timeoutSeconds)
            self.finishProbe(name, entry: entry, result: result)
        }
    }

    @discardableResult
    func finishProbe(_ name: String, entry: MCPServerEntry, result: MCPProbeResult) -> MCPProbeResult {
        probing.remove(name)
        let now = dependencies.now()
        switch result {
        case .connected(let transport, let serverName, let tools):
            probes[name] = Seen(status: MCPServerStatus(state: .connected), at: now, transport: transport, serverName: serverName)
            remember(tools, for: entry)
        case .failed(let status, let challenge):
            probes[name] = Seen(status: status, at: now)
            if status.state == .needsSignIn, entry.kind == .remote {
                usesOAuth.insert(name)
                if let challenge { challenges[name] = challenge }
            }
        }
        rebuild()
        return result
    }

    /// The entry the probe runs: `${keychain:…}` values filled in, and the bearer as a header.
    private func resolvedForProbe(_ entry: MCPServerEntry) async -> [String: JSONValue] {
        var resolved = entry
        resolved.command = entry.command.map(resolveKeychain)
        resolved.args = entry.args.map(resolveKeychain)
        resolved.env = entry.env.mapValues(resolveKeychain)
        resolved.url = entry.url.map(resolveKeychain)
        resolved.headers = entry.headers.mapValues(resolveKeychain)
        if usesOAuth(entry), token(for: entry) != nil, let token = try? await currentToken(entry.name) {
            var headers = resolved.headers
            headers["Authorization"] = "Bearer \(token.accessToken)"
            resolved.headers = headers
        }
        return resolved.withoutShepherd
    }

    private func resolveKeychain(_ value: String) -> String {
        var out = value
        for reference in MCPSecretReference.references(in: value) {
            let secret = dependencies.secrets.value(for: MCPSecretReference.account(server: reference.server, name: reference.name)) ?? ""
            out = out.replacingOccurrences(of: MCPSecretReference.reference(server: reference.server, name: reference.name), with: secret)
        }
        return out
    }

    // MARK: Credentials for agents

    /// Answers the extension's `mcpCredentials` request.
    func credentials(for request: MCPRequest) async -> MCPOutcome {
        reload()
        let name = request.server
        guard let entry = document.server(name) else {
            return .failure(code: MCPFailureCode.noSuchServer, message: "\(name) isn’t in Settings ▸ MCP servers.")
        }
        guard entry.settings.enabled else {
            return .failure(code: MCPFailureCode.noSuchServer, message: "\(name) is off in Settings ▸ MCP servers.")
        }
        // Secrets go by the reference's NAME (and by "<server>/<NAME>" for another server's
        // item), and the extension puts each wherever its reference appears (CONTRACT §9).
        var credentials = MCPCredentials()
        for reference in Self.secretReferences(entry) {
            guard let secret = dependencies.secrets.value(for: MCPSecretReference.account(server: reference.server, name: reference.name))
            else { continue }
            credentials.env[reference.server == name ? reference.name : "\(reference.server)/\(reference.name)"] = secret
        }
        if let missing = missingSecrets(entry).first {
            rebuild()
            return .failure(code: MCPFailureCode.missingSecret,
                            message: "\(name)’s \(missing) isn’t set: add it in Settings ▸ MCP servers.")
        }
        guard entry.kind == .remote, !hasAuthHeader(entry) else {
            if request.reason != .connect, hasAuthHeader(entry) {
                return .failure(code: MCPFailureCode.expired,
                                message: "\(name) turned down its Authorization header: check it in Settings ▸ MCP servers.")
            }
            return .credentials(credentials)
        }
        if request.reason != .connect {
            usesOAuth.insert(name)
            if let challenge = request.challenge { challenges[name] = challenge }
        }
        guard usesOAuth(entry) else { return .credentials(credentials) }
        let nowMs = Self.ms(dependencies.now())
        if request.reason == .forbidden {
            let challenge = MCPAuthChallenge.bearer(in: request.challenge)
            let have = Set(token(name)?.scopes ?? [])
            let missing = (challenge?.scopes ?? []).filter { !have.contains($0) }
            flags[name] = .needsScopes(missing)
            rebuild()
            let what = missing.isEmpty ? "" : " (\(missing.joined(separator: ", ")))"
            return .failure(code: MCPFailureCode.needsScopes,
                            message: "\(name) needs more access\(what): sign in again in Settings ▸ MCP servers.")
        }
        guard var token = token(for: entry) else {
            return needsSignIn(name)
        }
        let stale = request.reason == .unauthorized || token.needsRefresh(nowMs: nowMs)
        if stale {
            // A 401 right after a refresh means the token itself is refused.
            if request.reason == .unauthorized, nowMs - token.refreshedAtMs < 10_000 {
                return expired(name)
            }
            do {
                token = try await refreshed(name)
            } catch MCPOAuthError.expired {
                return expired(name)
            } catch {
                return .failure(code: MCPFailureCode.unavailable, message: "Couldn’t refresh \(name)’s sign-in: \(error)")
            }
        }
        credentials.bearer = token.accessToken
        credentials.expiresAtMs = token.expiresAtMs
        return .credentials(credentials)
    }

    private func needsSignIn(_ name: String) -> MCPOutcome {
        flags[name] = .needsSignIn
        rebuild()
        onNeedsSignIn?(name)
        return .failure(code: MCPFailureCode.needsSignIn, message: "\(name) needs you to sign in: Settings ▸ MCP servers.")
    }

    private func expired(_ name: String) -> MCPOutcome {
        flags[name] = .expired
        rebuild()
        onNeedsSignIn?(name)
        return .failure(code: MCPFailureCode.expired, message: "\(name)’s sign-in expired: sign in again in Settings ▸ MCP servers.")
    }

    /// The token, refreshed first when it's about to expire.
    func currentToken(_ name: String) async throws -> MCPOAuthToken? {
        guard let token = token(name) else { return nil }
        guard token.needsRefresh(nowMs: Self.ms(dependencies.now())) else { return token }
        return try await refreshed(name)
    }

    /// One refresh per server; other requests wait for it.
    func refreshed(_ name: String) async throws -> MCPOAuthToken {
        if let running = refreshes[name] { return try await running.value }
        guard let token = token(name) else { throw MCPOAuthError.expired }
        let service = MCPOAuthService(http: dependencies.http)
        let nowMs = Self.ms(dependencies.now())
        let task = Task { try await service.refresh(token, nowMs: nowMs) }
        refreshes[name] = task
        defer { refreshes[name] = nil }
        let next = try await task.value
        try saveToken(next, for: name)
        rebuild()
        return next
    }

    // MARK: Sign-in

    /// Opens the sign-in sheet for a server and starts it.
    func beginSignIn(_ name: String) {
        guard let entry = document.server(name), let url = entry.url.flatMap(URL.init(string:)) else { return }
        signIn?.cancel()
        let missing: [String] = if case .needsScopes(let scopes) = flags[name] { scopes } else { [] }
        var oauth = entry.settings.oauth
        oauth.clientSecret = oauth.clientSecret.map(resolveKeychain)
        let flow = MCPSignInFlow(
            server: name, url: url, oauth: oauth, challenge: challenges[name], previous: token(name),
            missingScopes: missing, service: MCPOAuthService(http: dependencies.http), dependencies: dependencies,
            complete: { [weak self] token in
                guard let self else { return nil }
                try self.saveToken(token, for: name)
                self.flags[name] = nil
                self.usesOAuth.insert(name)
                self.rebuild()
                guard let entry = self.document.server(name) else { return nil }
                self.probing.insert(name)
                let resolved = await self.resolvedForProbe(entry)
                let result = await self.dependencies.probe.probe(name: name, entry: resolved, timeoutSeconds: entry.settings.timeoutSeconds)
                return self.finishProbe(name, entry: entry, result: result)
            })
        signIn = flow
        flow.start()
    }

    func signOut(_ name: String) {
        try? saveToken(nil, for: name)
        flags[name] = nil
        rebuild()
    }

    func closeSignIn() {
        signIn?.cancel()
        signIn = nil
    }

    // MARK: Cache

    static func readCache(_ url: URL) -> [String: CachedTools] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedTools].self, from: data)) ?? [:]
    }

    private func writeCache() {
        let url = dependencies.cacheURL
        let snapshot = cache
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
