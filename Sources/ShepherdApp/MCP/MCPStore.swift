import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// Settings ▸ MCP servers' one store (docs/mcp.md). pi's own MCP runs the servers; the app owns
/// the file the user edits, the Keychain, pi's derived `mcp.json` (`MCPPiConfig`) and what each row
/// says. A row's state comes from `pi mcp list --json`, run in pi's home with the environment an
/// agent's pi would have, once when the page opens and after an edit, a sign-in or Reconnect;
/// the page shows what is known, never guesses a server is connected.
@MainActor
@Observable
final class MCPStore {
    struct Dependencies {
        var file: MCPConfigFile
        var secrets: MCPSecretStore
        var http: MCPHTTP
        /// pi's `mcp` subcommands.
        var cli: MCPCLI
        /// Readies pi's home (`PiSetup.prepare`, off the main thread): why not, or nil. Nothing of
        /// Shepherd's is written into a home that fails its guards.
        var preparePi: () async -> String?
        /// `<home>/mcp-auth.json`, which holds pi's sign-ins.
        var authData: () -> Data?
        var openURL: @MainActor (URL) -> Void
        var copy: @MainActor (String) -> Void
        var now: @MainActor () -> Date
        /// The user's home folder: what a `~/` in a server's command means to the shell that starts it.
        var userHome: String = NSHomeDirectory()
        /// Writes pi's `mcp.json` (`MCPPiConfig`), in pi's home.
        var writePiConfig: (Data) throws -> Void = { _ in }
        /// What Shepherd's own MCP left behind and nothing reads now: removed once at start.
        var removeLeftovers: () -> Void = {}

        /// The app's: the real file and Keychain, pi's home and its `mcp` subcommands, the browser
        /// and the pasteboard.
        static func app(pi: PiSetup, openURL: @escaping @MainActor (URL) -> Void,
                        copy: @escaping @MainActor (String) -> Void) -> Dependencies {
            let home = pi.files
            let authFile = home.directory.appendingPathComponent("mcp-auth.json")
            return Dependencies(file: MCPConfigFile(url: ShepherdPaths.mcpConfigURL()), secrets: MCPSecrets.forApp(),
                                http: URLSessionHTTP(), cli: PiMCPCLI(home: home),
                                preparePi: { await Task.detached(priority: .userInitiated) { pi.prepare()?.message }.value },
                                authData: { try? Data(contentsOf: authFile) },
                                openURL: openURL, copy: copy, now: { Date() }, userHome: home.userHome,
                                writePiConfig: { try home.installMCPConfig($0) },
                                removeLeftovers: {
                                    // The tools cache of the extension Shepherd no longer runs, and the sign-ins its own OAuth kept:
                                    // pi's are in its home now, and a Keychain token nothing reads is only a credential left lying.
                                    try? FileManager.default.removeItem(at: ShepherdPaths.supportDirectory().appendingPathComponent("mcp/tools.json"))
                                    let secrets = MCPSecrets.forApp()
                                    for account in secrets.accounts(withPrefix: "oauth/") { secrets.remove(account) }
                                })
        }
    }

    enum Filter: Hashable { case all, connected, needsYou }

    struct Budget: Equatable {
        var tokens: String
        var fraction: Double
        var note: String
    }

    /// Where the last `pi mcp list` stands.
    enum Listing: Equatable {
        case never
        case running
        case done(Date)
    }

    /// What one server is, for its row.
    private enum State: Equatable {
        case off
        /// pi's MCP can't run it, and why.
        case cannotRun(String)
        case checking
        case notChecked
        case connected
        case needsSignIn
        case failed(String)
        case idle
    }

    // MARK: Observed

    private(set) var document = MCPConfigDocument()
    /// The file doesn't parse: editing is off until it does.
    private(set) var invalidLine: Int?
    private(set) var rows: [MCPServerRowModel] = []
    private(set) var details: [String: MCPServerDetailModel] = [:]
    private(set) var budget = Budget(tokens: "~0 tokens", fraction: 0, note: "")
    private(set) var connectedCount = 0
    private(set) var listing = Listing.never
    var problem: String?
    /// The sign-in sheet, while one runs.
    var signIn: MCPSignInFlow?

    // MARK: Bookkeeping

    @ObservationIgnored let dependencies: Dependencies
    @ObservationIgnored private var report: MCPPiReport?
    @ObservationIgnored private var reportedFor: Data?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var authData: Data?
    @ObservationIgnored private var fileStamp: Data?
    @ObservationIgnored private var derivedConfig: (document: MCPConfigDocument, derived: MCPPiConfig.Derived)?
    @ObservationIgnored private var secretCache: [String: String] = [:]

    /// A list older than this is asked for again when the page opens.
    static let staleAfter: TimeInterval = 5 * 60
    /// How long `pi mcp list` may take: it connects every enabled server, and pi waits on each one's own timeout.
    static let listTimeout: TimeInterval = 45

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        dependencies.removeLeftovers()
        reload()
    }

    var configPath: String {
        let path = dependencies.file.url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var isEditable: Bool { invalidLine == nil }

    var invalidMessage: String? { invalidLine.map { MCPConfigError.invalid(line: $0).description } }

    // MARK: pi's MCP

    /// What pi's MCP is told, derived from `document` (docs/mcp.md).
    var piConfig: MCPPiConfig.Derived {
        if let cached = derivedConfig, cached.document == document { return cached.derived }
        let derived = MCPPiConfig.derive(document, home: dependencies.userHome)
        derivedConfig = (document, derived)
        return derived
    }

    /// Writes pi's `mcp.json` into its home when it differs. The home must be ready
    /// (`PiSetup.prepare` passed): nothing of Shepherd's goes into a home that fails its guards.
    func syncPiConfig() throws {
        try dependencies.writePiConfig(piConfig.json)
    }

    /// The environment pi starts with for its MCP servers: each Keychain value the derived file
    /// refers to, under its `SHEPHERD_MCP_SECRET_*` name, and the list of those names
    /// (`restore-env.sh` unsets them for the model's shell commands). Reads the file again first,
    /// so what starts after an edit made elsewhere has it, and writes pi's `mcp.json`.
    func launchEnvironment() -> [String: String] {
        reload()
        do {
            try syncPiConfig()
            if problem?.hasPrefix(Self.writeProblem) == true { problem = nil }
        } catch {
            problem = "\(Self.writeProblem) \(error)"
        }
        var environment: [String: String] = [:]
        let secrets = piConfig.secrets
        for secret in secrets {
            if let value = secretValue(secret.account) { environment[secret.variable] = value }
        }
        if !secrets.isEmpty { environment[PiHome.mcpSecretNamesKey] = secrets.map(\.variable).joined(separator: " ") }
        return environment
    }

    private static let writeProblem = "Couldn’t write pi’s MCP config:"

    private func secretValue(_ account: String) -> String? {
        if let cached = secretCache[account] { return cached }
        let value = dependencies.secrets.value(for: account)
        if let value { secretCache[account] = value }
        return value
    }

    // MARK: Reading

    /// Reads the file again (the page appearing, a request after someone else edited it).
    func reload() {
        let data = try? Data(contentsOf: dependencies.file.url)
        guard data != fileStamp || rows.isEmpty && document.root.isEmpty else { return }
        fileStamp = data
        secretCache.removeAll()
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

    /// A server's tool names as pi last listed them.
    func toolNames(of entry: MCPServerEntry) -> [String]? {
        report?.server(entry.name).flatMap { $0.state == "connected" ? $0.tools : nil }
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

    /// The Keychain items an entry refers to that aren't there, by name.
    func missingSecrets(_ entry: MCPServerEntry) -> [String] {
        Self.secretReferences(entry)
            .filter { dependencies.secrets.value(for: MCPSecretReference.account(server: $0.server, name: $0.name)) == nil }
            .map(\.name)
    }

    /// Every `${keychain:…}` an entry holds, wherever pi's MCP expands it, once each.
    static func secretReferences(_ entry: MCPServerEntry) -> [(server: String, name: String)] {
        let values = [entry.command ?? ""] + entry.args + entry.env.keys.sorted().compactMap { entry.env[$0] } + [entry.url ?? ""]
            + entry.headers.keys.sorted().compactMap { entry.headers[$0] } + [entry.settings.oauth.clientSecret ?? ""]
        var seen: Set<String> = []
        return values.flatMap(MCPSecretReference.references(in:)).filter { seen.insert("\($0.server)/\($0.name)").inserted }
    }

    private func hasAuthHeader(_ entry: MCPServerEntry) -> Bool {
        entry.headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    /// Whether pi signs this server in: a remote server with no Authorization header.
    func signsInWithOAuth(_ entry: MCPServerEntry) -> Bool {
        entry.kind == .remote && !hasAuthHeader(entry)
    }

    /// Whether the entry signs in with OAuth: pi says it needs a sign-in or holds one, or Add's
    /// Advanced gave it a client.
    func usesOAuth(_ entry: MCPServerEntry) -> Bool {
        guard signsInWithOAuth(entry) else { return false }
        return state(of: entry) == .needsSignIn || isSignedIn(entry) || !entry.settings.oauth.isEmpty
    }

    /// Whether pi holds a sign-in for the entry's URL.
    private func isSignedIn(_ entry: MCPServerEntry) -> Bool {
        entry.url.map { MCPPiAuth.hasCredentials(server: entry.name, url: $0, in: authData) } ?? false
    }

    private func state(of entry: MCPServerEntry) -> State {
        if !entry.settings.enabled { return .off }
        if let reason = piConfig.problems[entry.name] ?? report?.configProblems[entry.name] { return .cannotRun(reason) }
        guard let live = report?.server(entry.name) else { return listing == .running ? .checking : .notChecked }
        switch live.state {
        case "connected": return .connected
        case "needs-auth": return .needsSignIn
        case "failed": return .failed(live.error ?? "Couldn’t connect.")
        case "disabled": return .off
        default: return .idle
        }
    }

    // MARK: Rows

    /// Derives every row, detail and the budget once per change.
    func rebuild() {
        let entries = document.servers
        var rows: [MCPServerRowModel] = []
        var details: [String: MCPServerDetailModel] = [:]
        var budgetInput: [MCPBudgetEstimate.Server] = []
        for entry in entries {
            let state = state(of: entry)
            let missing = missingSecrets(entry)
            let names = toolNames(of: entry)
            let settings = entry.settings
            rows.append(row(entry, state: state, missing: missing, tools: names))
            details[entry.name] = detail(entry, state: state, missing: missing, tools: names)
            if settings.enabled, !isCannotRun(state) {
                budgetInput.append(MCPBudgetEstimate.Server(name: entry.name, direct: settings.exposure == .direct,
                                                           toolCount: MCPBudgetEstimate.visible(names ?? [], chosen: settings.tools).count))
            }
        }
        let estimate = MCPBudgetEstimate.estimate(budgetInput)
        let budget = Budget(tokens: MCPBudgetEstimate.longLabel(estimate.tokens), fraction: Double(estimate.tokens) / 8000, note: estimate.note)
        let connected = rows.filter { $0.status == .connected }.count
        if self.rows != rows { self.rows = rows }
        if self.details != details { self.details = details }
        if self.budget != budget { self.budget = budget }
        if connectedCount != connected { connectedCount = connected }
    }

    private func isCannotRun(_ state: State) -> Bool {
        if case .cannotRun = state { return true }
        return false
    }

    private static func dot(_ state: State, missing: Bool) -> MCPDotState {
        switch state {
        case .off: return .off
        case .needsSignIn: return .needsYou
        case .cannotRun, .failed: return .error
        case _ where missing: return .needsYou
        case .connected: return .connected
        case .checking: return .starting
        case .notChecked, .idle: return .idle
        }
    }

    private func row(_ entry: MCPServerEntry, state: State, missing: [String], tools: [String]?) -> MCPServerRowModel {
        let note: MCPServerRowModel.Note? = switch state {
        case .checking: .starting("Checking on This Mac…")
        case .cannotRun(let reason): .error(reason)
        case .failed(let message): .error(Self.firstLine(message))
        default: nil
        }
        return MCPServerRowModel(
            name: entry.name, kind: entry.kind == .remote ? .remote : .local, endpoint: entry.endpoint,
            status: Self.dot(state, missing: !missing.isEmpty), note: note, signIn: signInCell(entry, state: state, missing: missing),
            tools: tools.map { MCPBudgetEstimate.visible($0, chosen: entry.settings.tools).count }, enabled: entry.settings.enabled)
    }

    private func signInCell(_ entry: MCPServerEntry, state: State, missing: [String]) -> MCPServerRowModel.SignIn {
        if let first = missing.first { return .missingSecret(first) }
        if entry.kind == .remote {
            if let auth = entry.headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })
                ?? entry.headers.first {
                if let variable = MCPSecretReference.variable(in: auth.value) { return .variable("$" + variable) }
                if let reference = MCPSecretReference.references(in: auth.value).first { return .secret(reference.name) }
                return .secret(auth.key)
            }
            if state == .needsSignIn { return .signIn }
            return isSignedIn(entry) ? .account("Signed in") : .none
        }
        let keys = entry.env.keys.sorted()
        switch keys.count {
        case 0: return .none
        case 1: return .secret(keys[0])
        default: return .variables(keys.count)
        }
    }

    private func detail(_ entry: MCPServerEntry, state: State, missing: [String], tools: [String]?) -> MCPServerDetailModel {
        let settings = entry.settings
        let signIn: MCPServerDetailModel.SignIn
        if entry.kind == .remote, let auth = entry.headers.sorted(by: { $0.key < $1.key }).first(where: {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }) ?? entry.headers.sorted(by: { $0.key < $1.key }).first {
            let variable = MCPSecretReference.variable(in: auth.value).map { "$" + $0 }
                ?? MCPSecretReference.references(in: auth.value).first.map { "\($0.name) (Keychain)" } ?? "a value in mcp.json"
            signIn = .header(name: auth.key, variable: variable)
        } else if signsInWithOAuth(entry) {
            if state == .needsSignIn {
                signIn = .needsSignIn(title: "Not signed in", note: "It uses OAuth: sign in once and pi keeps the token fresh.", again: false)
            } else if isSignedIn(entry) {
                signIn = .signedIn(account: nil, scopes: [], note: "OAuth · kept fresh by pi")
            } else {
                signIn = .none
            }
        } else if entry.kind == .local, !entry.env.isEmpty {
            signIn = .secrets(names: entry.env.keys.sorted(), missing: missing)
        } else {
            signIn = .none
        }
        let all = tools ?? []
        let visible = MCPBudgetEstimate.visible(all, chosen: settings.tools)
        let hostDetail: (String, MCPServerDetailModel.Host.Mark) = switch state {
        case .connected: ("connected", .done)
        case .checking: ("checking", .working)
        case .failed: ("failed", .failed)
        case .cannotRun: ("can’t run", .failed)
        case .off: ("off", .none)
        case .needsSignIn: ("needs sign-in", .none)
        case .notChecked: ("not checked yet", .offline)
        case .idle: ("not connected", .offline)
        }
        let message: String? = switch state {
        case .failed(let text): text
        case .cannotRun(let reason): reason
        default: nil
        }
        return MCPServerDetailModel(
            signIn: signIn,
            toolNames: all,
            toolCount: tools.map { _ in all.count },
            direct: settings.exposure == .direct,
            searchCost: MCPBudgetEstimate.shortLabel(MCPBudgetEstimate.searchServerTokens),
            directCost: tools == nil ? "—" : MCPBudgetEstimate.shortLabel(MCPBudgetEstimate.directTokens(count: visible.count)),
            chosenNote: settings.tools == nil ? nil : "\(visible.count) of \(all.count) chosen",
            transport: Self.transportName(entry.transport),
            hosts: [.init(name: "This Mac", detail: hostDetail.0, mark: hostDetail.1)],
            message: message)
    }

    static func transportName(_ transport: MCPTransportKind) -> String {
        switch transport {
        case .stdio: "stdio"
        case .streamableHTTP: "Streamable HTTP"
        case .sse: "HTTP+SSE"
        }
    }

    /// A failure's first line, for a row: pi adds the server's stderr under it.
    private static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "Couldn’t connect.")
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
        secretCache.removeAll()
        for (key, value) in secrets {
            try dependencies.secrets.set(value, for: MCPSecretReference.account(server: entry.name, name: key))
        }
        try MCPImport.moveSecrets(&entry, to: dependencies.secrets)
        try edit { document in
            if let replacing, replacing != entry.name { document.remove(replacing) }
            document.upsert(entry)
        }
        if let replacing, replacing != entry.name { forget(replacing) }
        refresh()
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        update(name) { $0.enabled = enabled }
        if enabled { refresh() }
    }

    func setExposure(_ name: String, _ exposure: MCPExposure) {
        update(name) { $0.exposure = exposure }
    }

    func setTools(_ name: String, _ tools: [String]?) {
        update(name) { $0.tools = tools }
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

    /// Deletes the entry, its Keychain items and pi's sign-in.
    func remove(_ name: String) {
        guard perform({ $0.remove(name) }) else { return }
        dependencies.secrets.removeAll(forServer: name)
        secretCache.removeAll()
        forget(name)
        Task { [weak self] in _ = await self?.runCLI(["logout", name], timeout: 15, onLine: nil) }
    }

    private func forget(_ name: String) {
        if let report, report.server(name) != nil {
            self.report = MCPPiReport(servers: report.servers.filter { $0.name != name }, errors: report.errors)
        }
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
        secretCache.removeAll()
        try edit { document in
            for entry in added { document.upsert(entry) }
        }
        refresh()
        return added.count
    }

    // MARK: Asking pi

    /// Asks pi for every server's state when it hasn't been asked since the file changed, or not
    /// for a while (the page appearing).
    func refreshIfStale() {
        guard !stale else { return }
        refresh()
    }

    private var stale: Bool {
        guard report != nil, reportedFor == piConfig.json, let refreshedAt else { return false }
        return dependencies.now().timeIntervalSince(refreshedAt) < Self.staleAfter
    }

    /// Runs `pi mcp list --json`, which connects every enabled server: one at a time, and a request
    /// that arrives meanwhile runs again once it ends.
    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        guard document.servers.contains(where: { $0.settings.enabled }) else {
            report = MCPPiReport(servers: [], errors: [])
            reportedFor = piConfig.json
            refreshedAt = dependencies.now()
            listing = .done(dependencies.now())
            rebuild()
            return
        }
        listing = .running
        rebuild()
        refreshTask = Task { [weak self] in
            await self?.list()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// Waits until no `pi mcp list` is running or queued.
    func settle() async {
        while let task = refreshTask { await task.value }
    }

    private func list() async {
        let sent = piConfig.json
        // Nil: pi's home isn't safe to use, and `runCLI` has put the reason on the page.
        guard let result = await runCLI(["list", "--json"], timeout: Self.listTimeout, onLine: nil) else {
            finishList(nil, failure: nil)
            return
        }
        guard !Task.isCancelled else { return }
        if let parsed = MCPPiReport.parse(result.stdout) {
            reportedFor = sent
            finishList(parsed, failure: nil)
        } else {
            let reason = result.timedOut ? "pi didn’t answer in \(Int(Self.listTimeout)) seconds."
                : (result.stderr.isEmpty ? "pi printed nothing (exit \(result.status))." : String(result.stderr.suffix(300)))
            finishList(nil, failure: reason)
        }
    }

    /// Runs `pi mcp <arguments>` in pi's home, after readying it and writing the derived `mcp.json`,
    /// with the environment pi would start with. Nil, with the reason on the page, when the home
    /// isn't safe to use.
    func runCLI(_ arguments: [String], timeout: TimeInterval, onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult? {
        if let reason = await dependencies.preparePi() {
            problem = reason
            return nil
        }
        let environment = launchEnvironment()
        return await dependencies.cli.run(arguments, environment: environment, timeout: timeout, onLine: onLine)
    }

    private func finishList(_ parsed: MCPPiReport?, failure: String?) {
        authData = dependencies.authData()
        refreshedAt = dependencies.now()
        listing = .done(dependencies.now())
        if let parsed {
            report = parsed
            if problem?.hasPrefix("Couldn’t check") == true { problem = nil }
        } else if let failure {
            report = nil
            problem = "Couldn’t check the servers: \(failure)"
        }
        rebuild()
    }

    // MARK: Sign-in

    /// Opens the sign-in sheet for a server and starts it: pi's own `mcp login`.
    func beginSignIn(_ name: String) {
        guard let entry = document.server(name), let url = entry.url.flatMap(URL.init(string:)) else { return }
        closeSignIn()
        let flow = MCPSignInFlow(
            server: name, url: url,
            run: { [weak self] arguments, onLine in await self?.runCLI(arguments, timeout: MCPSignInFlow.timeout + 10, onLine: onLine) },
            openURL: dependencies.openURL, copy: dependencies.copy,
            finished: { [weak self] in self?.refresh() })
        signIn = flow
        flow.start()
    }

    func signOut(_ name: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.runCLI(["logout", name], timeout: 15, onLine: nil)
            self.authData = self.dependencies.authData()
            self.refresh()
        }
    }

    func closeSignIn() {
        signIn?.cancel()
        signIn = nil
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
