import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI
import ShepherdTestKit
@testable import ShepherdApp

/// pi's `mcp` subcommands, scripted: records what Settings ran and with which environment, and answers
/// from `reply` (its lines are heard as they would be streamed). `blocks` makes `login` wait for its
/// task to be cancelled, as pi waits for a browser.
final class FakeMCPCLI: MCPCLI, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var environment: [String: String]
        var timeout: TimeInterval = 0
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var reply: @Sendable ([String]) -> (lines: [String], result: MCPCLIResult) = { _ in ([], MCPCLIResult(status: 0, stdout: "", stderr: "")) }
    var blocksLogin = false

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
             onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
        lock.withLock { recorded.append(Call(arguments: arguments, environment: environment, timeout: timeout)) }
        let answer = reply(arguments)
        for line in answer.lines { onLine?(line) }
        if blocksLogin, arguments.first == "login" {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return MCPCLIResult(status: 143, stdout: answer.result.stdout, stderr: "")
        }
        return answer.result
    }

    /// `pi mcp list --json` printing `servers`, one `(name, state, tools, error)` each.
    static func list(_ servers: [(name: String, state: String, tools: [String], error: String?)], errors: [String] = []) -> MCPCLIResult {
        let items = servers.map { server -> [String: Any] in
            var item: [String: Any] = ["name": server.name, "scope": "global", "enabled": server.state != "disabled", "exposure": "deferred",
                                       "transport": "x", "state": server.state, "tools": server.tools]
            if let error = server.error { item["error"] = error }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["servers": items, "errors": errors])) ?? Data()
        return MCPCLIResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }
}

/// What the store's dependencies read and write, which a test changes while the store runs.
final class MCPHarnessState: @unchecked Sendable {
    private let lock = NSLock()
    private var _prepareProblem: String?
    private var _auth: Data?
    private var _written: [Data] = []
    private var _opened: [URL] = []

    var prepareProblem: String? {
        get { lock.withLock { _prepareProblem } }
        set { lock.withLock { _prepareProblem = newValue } }
    }
    var auth: Data? {
        get { lock.withLock { _auth } }
        set { lock.withLock { _auth = newValue } }
    }
    var written: [Data] { lock.withLock { _written } }
    var opened: [URL] { lock.withLock { _opened } }
    func write(_ data: Data) { lock.withLock { _written.append(data) } }
    func open(_ url: URL) { lock.withLock { _opened.append(url) } }
}

@MainActor
final class MCPStoreHarness {
    let store: MCPStore
    let cli: FakeMCPCLI
    let secrets: InMemorySecretStore
    let state = MCPHarnessState()

    init(config: String?, secrets: InMemorySecretStore = InMemorySecretStore(), cli: FakeMCPCLI = FakeMCPCLI(), prepareProblem: String? = nil) throws {
        let directory = try makeScratchDirectory()
        let url = directory.appendingPathComponent("mcp.json")
        if let config { try Data(config.utf8).write(to: url) }
        self.cli = cli
        self.secrets = secrets
        let state = state
        state.prepareProblem = prepareProblem
        var dependencies = MCPStore.Dependencies(
            file: MCPConfigFile(url: url), secrets: secrets, http: URLSessionHTTP(), cli: cli,
            preparePi: { state.prepareProblem }, authData: { state.auth },
            openURL: { state.open($0) }, copy: { _ in }, now: { MCPFixtures.now })
        dependencies.userHome = "/Users/test"
        dependencies.writePiConfig = { state.write($0) }
        store = MCPStore(dependencies: dependencies)
    }

    var written: [Data] { state.written }
    var opened: [URL] { state.opened }
    var auth: Data? {
        get { state.auth }
        set { state.auth = newValue }
    }
    var rows: [MCPServerRowModel] { store.rows }

    func row(_ name: String) throws -> MCPServerRowModel { try #require(store.rows.first { $0.name == name }) }
}

@MainActor
enum MCPFixtures {
    /// The contract's seven board servers.
    static let boardConfig = """
    { "mcpServers": {
      "linear":  { "type": "http", "url": "https://mcp.linear.app/mcp", "shepherd": { "exposure": "proxy" } },
      "sentry":  { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
      "notion":  { "type": "http", "url": "https://mcp.notion.com/mcp" },
      "github":  { "type": "http", "url": "https://api.githubcopilot.com/mcp/",
                   "headers": { "Authorization": "Bearer ${GITHUB_TOKEN}" } },
      "postgres": { "command": "uvx", "args": ["postgres-mcp", "--access-mode=restricted"],
                    "env": { "DATABASE_URI": "${keychain:postgres/DATABASE_URI}" } },
      "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
      "grafana": { "command": "mcp-grafana", "args": ["--disable-write"],
                   "env": { "GRAFANA_URL": "https://grafana.acme.internal",
                            "GRAFANA_SERVICE_ACCOUNT_TOKEN": "${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}" } }
    }}
    """

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func harness(_ config: String? = boardConfig, secrets: InMemorySecretStore = InMemorySecretStore(),
                        cli: FakeMCPCLI = FakeMCPCLI(), prepareProblem: String? = nil) throws -> MCPStoreHarness {
        try MCPStoreHarness(config: config, secrets: secrets, cli: cli, prepareProblem: prepareProblem)
    }

    static func store(_ config: String? = boardConfig, secrets: InMemorySecretStore = InMemorySecretStore()) throws -> MCPStore {
        try harness(config, secrets: secrets).store
    }
}

@Suite("MCP store")
@MainActor
struct MCPStoreTests {
    private func row(_ store: MCPStore, _ name: String) throws -> MCPServerRowModel {
        try #require(store.rows.first { $0.name == name })
    }

    @Test func theBoardsServersReadWithTheirSignInColumn() throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "postgres://db"])
        let store = try MCPFixtures.store(secrets: secrets)
        // In the file's order, as the board lists them.
        #expect(store.rows.map(\.name) == ["linear", "sentry", "notion", "github", "postgres", "playwright", "grafana"])
        #expect(try row(store, "github").signIn == .variable("$GITHUB_TOKEN"))
        #expect(try row(store, "postgres").signIn == .secret("DATABASE_URI"))
        #expect(try row(store, "playwright").signIn == .none)
        // grafana's token isn't in Keychain: the row asks for it before counting variables.
        #expect(try row(store, "grafana").signIn == .missingSecret("GRAFANA_SERVICE_ACCOUNT_TOKEN"))
        try secrets.set("t", for: "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN")
        store.reload()
        store.rebuild()
        #expect(try row(store, "grafana").signIn == .variables(2))
        #expect(try row(store, "postgres").endpoint == "uvx postgres-mcp --access-mode=restricted")
        #expect(try row(store, "linear").kind == .remote)
        #expect(try row(store, "linear").tools == nil, "nothing is known until pi has been asked")
    }

    // MARK: What pi reports

    @Test func aRowShowsWhatPiListedForItsServer() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([
            (name: "linear", state: "connected", tools: ["list_issues", "create_issue", "get_issue"], error: nil),
            (name: "sentry", state: "needs-auth", tools: [], error: nil),
            (name: "notion", state: "failed", tools: [], error: "fetch failed\nconnect ECONNREFUSED"),
            (name: "github", state: "connected", tools: ["search"], error: nil),
            (name: "postgres", state: "disconnected", tools: [], error: nil),
            (name: "playwright", state: "disabled", tools: [], error: nil),
        ])) }
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "x", "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN": "y"])
        let harness = try MCPFixtures.harness(secrets: secrets, cli: cli)
        harness.store.refresh()
        #expect(harness.rows.first?.status == .starting, "while pi is being asked, nothing is claimed")
        await harness.store.settle()
        let store = harness.store
        #expect(try row(store, "linear").status == .connected)
        #expect(try row(store, "linear").tools == 3)
        #expect(try row(store, "sentry").status == .needsYou)
        #expect(try row(store, "sentry").signIn == .signIn)
        #expect(try row(store, "notion").status == .error)
        #expect(try row(store, "notion").note == .error("fetch failed"), "a row shows the first line; the detail has the rest")
        #expect(store.details["notion"]?.message == "fetch failed\nconnect ECONNREFUSED")
        #expect(try row(store, "github").status == .connected)
        #expect(try row(store, "postgres").status == .idle)
        #expect(try row(store, "grafana").status == .idle, "pi listed nothing for it")
        #expect(store.connectedCount == 2)
        #expect(store.count(.connected) == 2 && store.count(.needsYou) == 2)
        #expect(store.details["linear"]?.toolNames == ["list_issues", "create_issue", "get_issue"])
        #expect(store.details["linear"]?.hosts == [.init(name: "This Mac", detail: "connected", mark: .done)])
    }

    @Test func pisSignInShowsAsSignedInAndNeedsYouWhenItIsGone() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([(name: "linear", state: "connected", tools: ["a"], error: nil)])) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.auth = Data(#"{"mcp__linear|https://mcp.linear.app/mcp": {"serverUrl": "https://mcp.linear.app/mcp"}}"#.utf8)
        harness.store.refresh()
        await harness.store.settle()
        #expect(try row(harness.store, "linear").signIn == .account("Signed in"))
        #expect(harness.store.details["linear"]?.signIn == .signedIn(account: nil, scopes: [], note: "OAuth · kept fresh by pi"))
        // Another server of the same name and a different URL is not the same sign-in.
        harness.auth = Data(#"{"mcp__linear|https://elsewhere/mcp": {}}"#.utf8)
        harness.store.refresh()
        await harness.store.settle()
        #expect(try row(harness.store, "linear").signIn == .none)
    }

    @Test func listRunsWithThePiFileWrittenAndTheSecretsInItsEnvironment() async throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "postgres://db", "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa"])
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([])) }
        let harness = try MCPFixtures.harness(secrets: secrets, cli: cli)
        harness.store.refresh()
        await harness.store.settle()
        let call = try #require(cli.calls.first)
        #expect(call.arguments == ["list", "--json"])
        #expect(call.environment["SHEPHERD_MCP_SECRET_POSTGRES_DATABASE_URI"] == "postgres://db")
        #expect(call.environment["SHEPHERD_MCP_SECRET_GRAFANA_GRAFANA_SERVICE_ACCOUNT_TOKEN"] == "glsa")
        #expect(Set((call.environment[PiHome.mcpSecretNamesKey] ?? "").split(separator: " ").map(String.init)) == [
            "SHEPHERD_MCP_SECRET_POSTGRES_DATABASE_URI", "SHEPHERD_MCP_SECRET_GRAFANA_GRAFANA_SERVICE_ACCOUNT_TOKEN",
        ])
        let file = String(decoding: try #require(harness.written.last), as: UTF8.self)
        #expect(file.contains("\"linear\"") && file.contains("\"exposure\": \"deferred\""))
        #expect(!file.contains("postgres://db") && !file.contains("glsa"), "no secret value reaches pi's file")
    }

    @Test func aHomeThatIsNotReadyRunsNothingAndSaysWhy() async throws {
        let harness = try MCPFixtures.harness(prepareProblem: "Shepherd's pi home overlaps your pi.")
        harness.store.refresh()
        await harness.store.settle()
        #expect(harness.cli.calls.isEmpty)
        #expect(harness.written.isEmpty, "nothing of Shepherd's is written into a home that fails its guards")
        #expect(harness.store.problem == "Shepherd's pi home overlaps your pi.")
    }

    @Test func aCommandThatFailsToRunIsShownOnThePageNotOnTheRows() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], MCPCLIResult(status: 1, stdout: "", stderr: "Error: boom")) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.refresh()
        await harness.store.settle()
        #expect(harness.store.problem == "Couldn’t check the servers: Error: boom")
        #expect(try row(harness.store, "linear").status == .idle)
        cli.reply = { _ in ([], FakeMCPCLI.list([(name: "linear", state: "connected", tools: [], error: nil)])) }
        harness.store.refresh()
        await harness.store.settle()
        #expect(harness.store.problem == nil, "a good answer clears it")
    }

    @Test func aListPiDoesNotAnswerInTimeIsAskedWithItsBoundAndShownAsSuch() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], MCPCLIResult(status: 143, stdout: "", stderr: "", timedOut: true)) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.refresh()
        await harness.store.settle()
        #expect(cli.calls.map(\.timeout) == [MCPStore.listTimeout] && MCPStore.listTimeout == 45)
        #expect(harness.store.problem == "Couldn’t check the servers: pi didn’t answer in 45 seconds.")
        #expect(try row(harness.store, "linear").status == .idle, "the rows stay as they were, not failed")
    }

    @Test func serversPiCannotRunSayWhyOnTheirRowsAndAreNotCounted() async throws {
        let config = #"{"mcpServers": {"old": {"type": "sse", "url": "https://x.example.com/sse"}, "fine": {"command": "x"}}}"#
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([(name: "fine", state: "connected", tools: ["a"], error: nil)])) }
        let harness = try MCPFixtures.harness(config, cli: cli)
        harness.store.refresh()
        await harness.store.settle()
        let old = try row(harness.store, "old")
        #expect(old.status == .error)
        if case .error(let text)? = old.note { #expect(text.contains("Streamable HTTP")) } else { Issue.record("no reason on the row") }
        #expect(harness.store.details["old"]?.hosts.first?.detail == "can’t run")
        #expect(harness.store.connectedCount == 1)
        #expect(!String(decoding: try #require(harness.written.last), as: UTF8.self).contains("\"old\""))
    }

    @Test func askingAgainWhileOneRunsRunsOnceMoreAfterIt() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([])) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.refresh()
        harness.store.refresh()
        harness.store.refresh()
        await harness.store.settle()
        #expect(cli.calls.count == 2, "three asks while one runs make one more run, not three")
    }

    @Test func aFreshListIsNotAskedForAgainUntilTheFileChangesOrItGrowsStale() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([(name: "linear", state: "connected", tools: [], error: nil)])) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.refreshIfStale()
        await harness.store.settle()
        harness.store.refreshIfStale()
        await harness.store.settle()
        #expect(cli.calls.count == 1)
        harness.store.setEnabled("sentry", false)
        harness.store.refreshIfStale()
        await harness.store.settle()
        #expect(cli.calls.count == 2, "a changed file is asked about again")
    }

    @Test func switchingAServerOnAsksPiAndSwitchingItOffDoesNot() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([])) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.setEnabled("linear", false)
        await harness.store.settle()
        #expect(cli.calls.isEmpty)
        #expect(try row(harness.store, "linear").status == .off)
        harness.store.setEnabled("linear", true)
        await harness.store.settle()
        #expect(cli.calls.count == 1)
    }

    // MARK: pi's file

    @Test func theLaunchEnvironmentIsTheKeychainValuesTheFileRefersTo() throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "postgres://db"])
        let harness = try MCPFixtures.harness(secrets: secrets)
        let environment = harness.store.launchEnvironment()
        #expect(environment["SHEPHERD_MCP_SECRET_POSTGRES_DATABASE_URI"] == "postgres://db")
        #expect(environment["SHEPHERD_MCP_SECRET_GRAFANA_GRAFANA_SERVICE_ACCOUNT_TOKEN"] == nil, "a value that isn't in Keychain is not set")
        #expect(Set((environment[PiHome.mcpSecretNamesKey] ?? "").split(separator: " ").map(String.init)) == [
            "SHEPHERD_MCP_SECRET_POSTGRES_DATABASE_URI", "SHEPHERD_MCP_SECRET_GRAFANA_GRAFANA_SERVICE_ACCOUNT_TOKEN",
        ], "a name is listed even while its value is missing, so the model's shell never sees it either")
        #expect(!harness.written.isEmpty)
    }

    @Test func anEditReachesTheNextLaunch() throws {
        let harness = try MCPFixtures.harness()
        _ = harness.store.launchEnvironment()
        harness.store.setExposure("linear", .direct)
        _ = harness.store.launchEnvironment()
        let text = String(decoding: try #require(harness.written.last), as: UTF8.self)
        #expect(text.contains("\"direct\""))
    }

    // MARK: Sign-in

    @Test func signingInRunsPisLoginAndTellsItsOutputAsTheSheetsSteps() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { arguments in
            if arguments.first == "login" {
                return (["Sign in to MCP server \"notion\" in your browser:", "https://mcp.notion.com/authorize?x=1"],
                        MCPCLIResult(status: 0, stdout: "Sign in to MCP server \"notion\" in your browser:\nhttps://mcp.notion.com/authorize?x=1\nSigned in to MCP server \"notion\" (14 tools).\n", stderr: ""))
            }
            return ([], FakeMCPCLI.list([(name: "notion", state: "connected", tools: Array(repeating: "t", count: 14), error: nil)]))
        }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.beginSignIn("notion")
        let flow = try #require(harness.store.signIn)
        while !flow.succeeded { try await Task.sleep(for: .milliseconds(5)) }
        #expect(cli.calls.first?.arguments == ["login", "notion", "--timeout", "300"])
        #expect(flow.model.phase == .done)
        #expect(flow.model.steps.map(\.state) == [.done, .done, .done])
        #expect(flow.model.subtitle == "notion is connected: 14 tools.")
        #expect(flow.authorizationURL?.absoluteString == "https://mcp.notion.com/authorize?x=1")
        flow.openBrowserAgain()
        #expect(harness.opened.map(\.absoluteString) == ["https://mcp.notion.com/authorize?x=1"])
        await harness.store.settle()
        #expect(cli.calls.map(\.arguments.first) == ["login", "list"], "the page asks pi again once signed in")
    }

    @Test func aSignInPiGivesUpOnShowsWhyAndSavesNothing() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in (["Sign in to MCP server \"notion\" in your browser:", "https://mcp.notion.com/authorize"],
                            MCPCLIResult(status: 1, stdout: "", stderr: "Sign-in to MCP server \"notion\" was cancelled or not completed within 300 seconds.")) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.beginSignIn("notion")
        let flow = try #require(harness.store.signIn)
        while flow.model.phase == .waiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(flow.model.phase == .failed)
        #expect(flow.model.steps.map(\.state) == [.done, .done, .failed])
        #expect(flow.model.steps.last?.title == "Signing in didn’t finish")
        #expect(flow.model.subtitle == "Nothing was saved.")
        #expect(flow.model.details?.contains("not completed within 300 seconds") == true)
        #expect(!flow.succeeded)
    }

    @Test func closingTheSheetEndsPisLoginAndClosingItTwiceIsFine() async throws {
        let cli = FakeMCPCLI()
        cli.blocksLogin = true
        cli.reply = { _ in (["https://mcp.notion.com/authorize"], MCPCLIResult(status: 0, stdout: "", stderr: "")) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.beginSignIn("notion")
        let flow = try #require(harness.store.signIn)
        while flow.authorizationURL == nil { try await Task.sleep(for: .milliseconds(5)) }
        harness.store.closeSignIn()
        harness.store.closeSignIn()
        #expect(harness.store.signIn == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!flow.succeeded, "a cancelled login never reads as signed in")
    }

    @Test func signingOutRunsPisLogoutAndAsksAgain() async throws {
        let cli = FakeMCPCLI()
        cli.reply = { _ in ([], FakeMCPCLI.list([(name: "linear", state: "needs-auth", tools: [], error: nil)])) }
        let harness = try MCPFixtures.harness(cli: cli)
        harness.store.signOut("linear")
        while cli.calls.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await harness.store.settle()
        #expect(cli.calls.map(\.arguments).prefix(2) == [["logout", "linear"], ["list", "--json"]])
        #expect(try row(harness.store, "linear").signIn == .signIn)
    }

    @Test func pisOutputIsReadDefensively() {
        #expect(MCPPiReport.parse("not json") == nil)
        #expect(MCPPiReport.parse(#"{"servers": [{"name": "a"}, {"nope": 1}], "errors": ["x: server \"b\": legacy SSE"]}"#)
            == MCPPiReport(servers: [.init(name: "a", enabled: true, state: "failed", tools: [], error: nil)], errors: ["x: server \"b\": legacy SSE"]))
        let report = MCPPiReport(servers: [], errors: ["/h/mcp.json: server \"b\": legacy SSE transport is not supported", "plain error"])
        #expect(report.configProblems == ["b": "legacy SSE transport is not supported"])
        #expect(MCPPiAuth.hasCredentials(server: "my-server", url: "https://x/mcp", in: Data(#"{"mcp__my_server|https://x/mcp": {}}"#.utf8)))
        #expect(!MCPPiAuth.hasCredentials(server: "a", url: "https://x/mcp", in: Data("[]".utf8)))
        #expect(!MCPPiAuth.hasCredentials(server: "a", url: "https://x/mcp", in: nil))
    }

    // MARK: Editing

    /// A secret typed in the sheet goes to Keychain; the file only ever holds its reference.
    @Test func secretsAreNeverWrittenAsPlaintext() throws {
        let secrets = InMemorySecretStore()
        let store = try MCPFixtures.store(nil, secrets: secrets)
        var entry = MCPServerEntry.local("grafana", command: "mcp-grafana", env: ["GRAFANA_URL": "https://g"])
        entry.env["GRAFANA_SERVICE_ACCOUNT_TOKEN"] = MCPSecretReference.reference(server: "grafana", name: "GRAFANA_SERVICE_ACCOUNT_TOKEN")
        try store.save(entry, secrets: ["GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa_topsecret"])
        let imported = MCPServerEntry.remote("api", url: "https://api.x/mcp", headers: ["Authorization": "Bearer sk-live-123"])
        try store.importEntries([imported], replace: false)
        let text = try String(contentsOf: store.dependencies.file.url, encoding: .utf8)
        #expect(!text.contains("glsa_topsecret") && !text.contains("sk-live-123"))
        #expect(text.contains("${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}"))
        #expect(text.contains("Bearer ${keychain:api/Authorization}"))
        #expect(secrets.value(for: "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN") == "glsa_topsecret")
        #expect(secrets.value(for: "secret/api/Authorization") == "sk-live-123")
        // Copy JSON hands out the references, never the values.
        #expect(store.json(for: "api")?.contains("${keychain:api/Authorization}") == true)
    }

    @Test func removingAServerDeletesItsKeychainItemsAndPisSignIn() async throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "x", "oauth/postgres": "{}", "secret/grafana/T": "y"])
        let harness = try MCPFixtures.harness(secrets: secrets)
        harness.store.remove("postgres")
        #expect(harness.store.entry("postgres") == nil)
        #expect(secrets.accounts(withPrefix: "") == ["secret/grafana/T"])
        while !harness.cli.calls.contains(where: { $0.arguments == ["logout", "postgres"] }) { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func settingsEditsReachTheFile() throws {
        let store = try MCPFixtures.store()
        store.setExposure("linear", .direct)
        store.setTools("linear", ["create_issue"])
        guard case .document(let document) = store.dependencies.file.read() else { Issue.record("unreadable"); return }
        let settings = try #require(document.server("linear")).settings
        #expect(settings.exposure == .direct && settings.tools == ["create_issue"])
    }

    @Test func anInvalidFileDisablesEditing() throws {
        let store = try MCPFixtures.store("{ nope")
        #expect(!store.isEditable)
        #expect(store.invalidMessage == "mcp.json isn’t valid JSON (line 1)")
        store.setEnabled("linear", false)
        #expect(try String(contentsOf: store.dependencies.file.url, encoding: .utf8) == "{ nope")
    }

    // MARK: Import

    @Test(arguments: [
        (#"{"mcpServers": {"a": {"command": "x"}, "b": {"url": "https://b/mcp"}}}"#, ["a", "b"]),
        (#"{"servers": {"gh": {"type": "http", "url": "https://api.githubcopilot.com/mcp/"}}}"#, ["gh"]),
        (#"{"linear": {"url": "https://mcp.linear.app/mcp"}}"#, ["linear"]),
        (#""linear": {"url": "https://mcp.linear.app/mcp"},"#, ["linear"]),
    ])
    func importReadsEveryShape(text: String, names: [String]) throws {
        #expect(try MCPImport.parse(text).get().map(\.name) == names)
    }

    @Test func importRefusesWhatIsntServers() {
        #expect(MCPImport.parse(#"{"theme": "dark"}"#) == .failure(.noServers))
        #expect(MCPImport.parse("{\n\"a\": }") == .failure(.invalid(line: 2)))
    }

    @Test func importSkipsOrReplacesClashes() throws {
        let store = try MCPFixtures.store()
        let incoming = [MCPServerEntry.remote("linear", url: "https://other/mcp"), .local("new", command: "x")]
        #expect(store.clashes(incoming) == ["linear"])
        #expect(try store.importEntries(incoming, replace: false) == 1)
        #expect(store.entry("linear")?.url == "https://mcp.linear.app/mcp")
        #expect(try store.importEntries(incoming, replace: true) == 2)
        #expect(store.entry("linear")?.url == "https://other/mcp")
    }

    // MARK: Budget

    @Test(arguments: [(0, 0), (184, 180), (185, 190), (999, 1000), (3_870, 3_900), (12_349, 12_300)])
    func totalsRoundToTensThenHundreds(tokens: Int, rounded: Int) {
        #expect(MCPBudgetEstimate.rounded(tokens) == rounded)
    }

    @Test func searchedServersShareOneToolSearchAndDirectOnesDeclareEachTool() {
        typealias Server = MCPBudgetEstimate.Server
        #expect(MCPBudgetEstimate.estimate([]).tokens == 0)
        let one = MCPBudgetEstimate.estimate([Server(name: "a", direct: false, toolCount: 40)])
        #expect(one.tokens == MCPBudgetEstimate.searchBaseTokens + MCPBudgetEstimate.searchServerTokens)
        let two = MCPBudgetEstimate.estimate([Server(name: "a", direct: false, toolCount: 40), Server(name: "b", direct: false, toolCount: 9)])
        #expect(two.tokens == one.tokens + MCPBudgetEstimate.searchServerTokens, "the declaration is paid once")
        let mixed = MCPBudgetEstimate.estimate([Server(name: "a", direct: false, toolCount: 40), Server(name: "b", direct: true, toolCount: 9)])
        #expect(mixed.tokens == one.tokens + 9 * MCPBudgetEstimate.directToolTokens)
        #expect(mixed.note == "b is set to Direct, which declares 9 tools in every prompt. The rest are searched.")
        let direct = MCPBudgetEstimate.estimate([Server(name: "b", direct: true, toolCount: 1)])
        #expect(direct.tokens == MCPBudgetEstimate.directToolTokens, "no tool_search is declared when nothing is searched")
        #expect(MCPBudgetEstimate.shortLabel(3_870) == "~3,900 tok")
    }

    // MARK: Names

    @Test(arguments: [
        ("https://mcp.notion.com/mcp", "notion"), ("https://mcp.linear.app/mcp", "linear"),
        ("https://api.githubcopilot.com/mcp/", "github"), ("https://mcp.sentry.dev/mcp", "sentry"),
    ])
    func aURLSuggestsItsServersName(url: String, name: String) throws {
        #expect(MCPServerName.suggested(for: try #require(URL(string: url))) == name)
    }

    @Test(arguments: [
        ("npx @playwright/mcp@latest", "playwright"), ("mcp-grafana --disable-write", "grafana"),
        ("uvx postgres-mcp --access-mode=restricted", "postgres"), ("npx -y @modelcontextprotocol/server-filesystem /tmp", "modelcontextprotocol"),
    ])
    func aCommandSuggestsItsServersName(command: String, name: String) {
        #expect(MCPServerName.suggested(forCommand: MCPCommandLine.split(command)) == name)
    }

    @Test func commandLinesSplitLikeAShell() {
        #expect(MCPCommandLine.split(#"node "/path with space/server.js" --flag='a b' x\ y"#)
            == ["node", "/path with space/server.js", "--flag=a b", "x y"])
        #expect(MCPCommandLine.join(["node", "/path with space/s.js"]) == "node '/path with space/s.js'")
    }

    @Test(arguments: [("my-server", "mcp__my_server", true), ("My_Server2", "mcp__My_Server2", true), ("a.b", "mcp__a.b", false), ("", "mcp__", false), ("é", "mcp__é", false)])
    func aServerNameIsPisAndPrefixesItsTools(name: String, prefix: String, valid: Bool) {
        #expect(MCPServerName.toolPrefix(name) == prefix)
        #expect(MCPServerName.isValid(name) == valid)
    }
}
