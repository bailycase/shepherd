import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import ShepherdTestKit
@testable import ShepherdApp

/// A probe that never runs: tests hand results to `finishProbe` themselves.
struct NoProbe: MCPProbeRunner {
    func run(input: Data, timeout: TimeInterval) async -> Data { Data(#"{"ok":false,"status":{"state":"error","message":"no"}}"#.utf8) }
}

/// Answers token requests from memory, the way an authorization server would.
final class TokenEndpointStub: MCPHTTP, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var body: String
    var status: Int

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        return (Data(body.utf8), response)
    }
}

@MainActor
enum MCPFixtures {
    /// The contract's seven board servers.
    static let boardConfig = """
    { "mcpServers": {
      "linear":  { "type": "http", "url": "https://mcp.linear.app/mcp", "shepherd": { "start": "whenUsed", "exposure": "proxy" } },
      "sentry":  { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
      "notion":  { "type": "http", "url": "https://mcp.notion.com/mcp", "shepherd": { "start": "whenUsed" } },
      "github":  { "type": "http", "url": "https://api.githubcopilot.com/mcp/",
                   "headers": { "Authorization": "Bearer ${GITHUB_TOKEN}" } },
      "postgres": { "command": "uvx", "args": ["postgres-mcp", "--access-mode=restricted"],
                    "env": { "DATABASE_URI": "${keychain:postgres/DATABASE_URI}" } },
      "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
      "grafana": { "command": "mcp-grafana", "args": ["--disable-write"],
                   "env": { "GRAFANA_URL": "https://grafana.acme.internal",
                            "GRAFANA_SERVICE_ACCOUNT_TOKEN": "${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}" },
                   "shepherd": { "start": "whenUsed", "idleMinutes": 10 } }
    }}
    """

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func token(account: String? = "baily@acme.dev", scopes: [String] = ["read", "write"], expiresIn: Int64? = 3600_000,
                      refreshedAgo: Int64 = 2 * 3600_000, refresh: String? = "r1") -> MCPOAuthToken {
        let nowMs = MCPStore.ms(now)
        return MCPOAuthToken(issuer: "https://auth.x", tokenEndpoint: "https://auth.x/token", clientID: "c", redirectURI: "http://127.0.0.1:1/callback",
                             resource: "https://mcp.x/mcp", accessToken: "access", refreshToken: refresh,
                             expiresAtMs: expiresIn.map { nowMs + $0 }, scopes: scopes, account: account, refreshedAtMs: nowMs - refreshedAgo)
    }

    static func store(_ config: String? = boardConfig, secrets: InMemorySecretStore = InMemorySecretStore(),
                      http: MCPHTTP = TokenEndpointStub(body: "{}"), now: Date = now) throws -> MCPStore {
        let directory = try makeScratchDirectory()
        let url = directory.appendingPathComponent("mcp.json")
        if let config { try Data(config.utf8).write(to: url) }
        return MCPStore(dependencies: MCPStore.Dependencies(
            file: MCPConfigFile(url: url), cacheURL: directory.appendingPathComponent("tools.json"), secrets: secrets, http: http,
            probe: MCPProbe(runner: NoProbe()), openURL: { _ in }, copy: { _ in }, now: { now }))
    }

    static func tokenJSON(_ token: MCPOAuthToken) -> String {
        String(decoding: (try? JSONEncoder().encode(token)) ?? Data(), as: UTF8.self)
    }

    static func tools(_ names: [String]) -> [MCPToolInfo] {
        names.map { MCPToolInfo(name: $0, description: "Does \($0).", inputSchema: .object(["type": .string("object")])) }
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
        #expect(store.rows.map(\.name) == ["github", "grafana", "linear", "notion", "playwright", "postgres", "sentry"])
        #expect(try row(store, "github").signIn == .variable("$GITHUB_TOKEN"))
        #expect(try row(store, "postgres").signIn == .secret("DATABASE_URI"))
        #expect(try row(store, "playwright").signIn == .none)
        // grafana's token isn't in Keychain: the row asks for it before counting variables.
        #expect(try row(store, "grafana").signIn == .missingSecret("GRAFANA_SERVICE_ACCOUNT_TOKEN"))
        try secrets.set("t", for: "secret/grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN")
        store.rebuild()
        #expect(try row(store, "grafana").signIn == .variables(2))
        #expect(try row(store, "postgres").endpoint == "uvx postgres-mcp --access-mode=restricted")
        #expect(try row(store, "linear").kind == .remote)
        #expect(try row(store, "linear").tools == nil)
    }

    @Test func oauthRowsFollowTheAppsOwnState() async throws {
        let secrets = InMemorySecretStore(["oauth/linear": MCPFixtures.tokenJSON(MCPFixtures.token())])
        let store = try MCPFixtures.store(secrets: secrets)
        // Nothing known yet: a remote server without a header connects when used.
        #expect(try row(store, "notion").signIn == .none)
        #expect(try row(store, "notion").status == .idle)
        // The server answered 401 to a probe: it uses OAuth and nobody signed in.
        let notion = try #require(store.entry("notion"))
        store.finishProbe("notion", entry: notion, result: .failed(MCPServerStatus(state: .needsSignIn), challenge: "Bearer"))
        #expect(try row(store, "notion").signIn == .signIn)
        #expect(try row(store, "notion").status == .needsYou)
        // Signed in: the account shows, and a live agent's connection shows.
        #expect(try row(store, "linear").signIn == .account("baily@acme.dev"))
        #expect(try row(store, "linear").status == .idle)
        store.receive(MCPServerReport(server: "linear", status: MCPServerStatus(state: .connected)), from: AgentID())
        #expect(try row(store, "linear").signIn == .account("baily@acme.dev"))
        #expect(try row(store, "linear").status == .connected)
        guard case .signedIn(let account, let scopes, let note) = store.details["linear"]?.signIn else {
            Issue.record("linear isn't signed in")
            return
        }
        #expect(account == "baily@acme.dev" && scopes == ["read", "write"] && note == "OAuth · refreshed 2h ago")
    }

    /// The status table, in the contract's order: off, the app's OAuth state, a live connection,
    /// a recent failure, starting, idle.
    @Test func statusFollowsTheContractsOrder() throws {
        let store = try MCPFixtures.store()
        let agent = AgentID()
        store.receive(MCPServerReport(server: "playwright", status: MCPServerStatus(state: .starting)), from: agent)
        #expect(try row(store, "playwright").status == .starting)
        #expect(try row(store, "playwright").note == .starting("Starting on This Mac…"))
        store.receive(MCPServerReport(server: "playwright", status: MCPServerStatus(state: .error, message: "npx failed")), from: agent)
        #expect(try row(store, "playwright").status == .error)
        #expect(try row(store, "playwright").note == .error("npx failed"))
        store.receive(MCPServerReport(server: "playwright", status: MCPServerStatus(state: .connected), tools: MCPFixtures.tools(["a", "b"])),
                      from: AgentID())
        #expect(try row(store, "playwright").status == .connected)
        #expect(try row(store, "playwright").tools == 2)
        #expect(store.count(.connected) == 1)
        // The agent that connected goes away: its report no longer counts; the older error does.
        store.retainReports(of: [agent])
        #expect(try row(store, "playwright").status == .error)
        store.retainReports(of: [])
        #expect(try row(store, "playwright").status == .idle)
        store.setEnabled("playwright", false)
        #expect(try row(store, "playwright").status == .off)
        #expect(try row(store, "playwright").enabled == false)
    }

    @Test func needsYouCountsSignInsErrorsAndMissingSecrets() throws {
        let store = try MCPFixtures.store()
        // postgres and grafana miss their Keychain values.
        #expect(Set(store.rows(filter: .needsYou, query: "").map(\.name)) == ["postgres", "grafana"])
        #expect(store.rows(filter: .all, query: "linear").map(\.name) == ["linear"])
        #expect(store.rows(filter: .all, query: "npx").map(\.name) == ["playwright"])
    }

    @Test func credentialsResolveKeychainValuesAndRefuseWhatsMissing() async throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "postgres://db"])
        let store = try MCPFixtures.store(secrets: secrets)
        let agent = AgentID()
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "postgres", reason: .connect))
            == .credentials(MCPCredentials(env: ["DATABASE_URI": "postgres://db"])))
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "grafana", reason: .connect))
            == .failure(code: "missing_secret",
                        message: "grafana’s GRAFANA_SERVICE_ACCOUNT_TOKEN isn’t set: add it in Settings ▸ MCP servers."))
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "nope", reason: .connect))
            == .failure(code: "no_such_server", message: "nope isn’t in Settings ▸ MCP servers."))
        store.setEnabled("postgres", false)
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "postgres", reason: .connect))
            == .failure(code: "no_such_server", message: "postgres is off in Settings ▸ MCP servers."))
    }

    @Test func aFirst401MeansSignInAndA403MeansMoreAccess() async throws {
        let secrets = InMemorySecretStore(["oauth/linear": MCPFixtures.tokenJSON(MCPFixtures.token(scopes: ["read"]))])
        let store = try MCPFixtures.store(secrets: secrets)
        var asked: [String] = []
        store.onNeedsSignIn = { asked.append($0) }
        let agent = AgentID()
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "notion", reason: .unauthorized, challenge: "Bearer"))
            == .failure(code: "needs_sign_in", message: "notion needs you to sign in: Settings ▸ MCP servers."))
        #expect(asked == ["notion"])
        #expect(try row(store, "notion").signIn == .signIn)

        let outcome = await store.credentials(for: MCPRequest(agentID: agent, server: "linear", reason: .forbidden,
                                                               challenge: #"Bearer error="insufficient_scope", scope="read issues:write""#))
        #expect(outcome == .failure(code: "needs_scopes",
                                    message: "linear needs more access (issues:write): sign in again in Settings ▸ MCP servers."))
        #expect(try row(store, "linear").signIn == .moreAccess(["issues:write"]))
    }

    @Test func aFreshTokenIsHandedOutAndAStaleOneRefreshedFirst() async throws {
        let secrets = InMemorySecretStore([
            "oauth/linear": MCPFixtures.tokenJSON(MCPFixtures.token()),
            // Four minutes left: refreshed before it's handed out.
            "oauth/sentry": MCPFixtures.tokenJSON(MCPFixtures.token(expiresIn: 4 * 60_000)),
        ])
        let http = TokenEndpointStub(body: #"{"access_token":"new","expires_in":3600,"refresh_token":"r2"}"#)
        let store = try MCPFixtures.store(secrets: secrets, http: http)
        let agent = AgentID()
        let expires = MCPStore.ms(MCPFixtures.now) + 3600_000
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "linear", reason: .connect))
            == .credentials(MCPCredentials(bearer: "access", expiresAtMs: expires)))
        #expect(http.requests.isEmpty)

        // sentry's is refreshed first, and the new token saved.
        #expect(await store.credentials(for: MCPRequest(agentID: agent, server: "sentry", reason: .connect))
            == .credentials(MCPCredentials(bearer: "new", expiresAtMs: expires)))
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token") && form.contains("refresh_token=r1"))
        #expect(store.token("sentry")?.refreshToken == "r2")
    }

    @Test func aRefusedRefreshMeansExpired() async throws {
        let secrets = InMemorySecretStore(["oauth/sentry": MCPFixtures.tokenJSON(MCPFixtures.token())])
        let http = TokenEndpointStub(body: #"{"error":"invalid_grant"}"#, status: 400)
        let store = try MCPFixtures.store(secrets: secrets, http: http)
        #expect(await store.credentials(for: MCPRequest(agentID: AgentID(), server: "sentry", reason: .unauthorized))
            == .failure(code: "expired", message: "sentry’s sign-in expired: sign in again in Settings ▸ MCP servers."))
        #expect(try row(store, "sentry").signIn == .expired)
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

    @Test func removingAServerDeletesItsKeychainItems() throws {
        let secrets = InMemorySecretStore(["secret/postgres/DATABASE_URI": "x", "oauth/postgres": "{}", "secret/grafana/T": "y"])
        let store = try MCPFixtures.store(secrets: secrets)
        store.remove("postgres")
        #expect(store.entry("postgres") == nil)
        #expect(secrets.accounts(withPrefix: "") == ["secret/grafana/T"])
    }

    @Test func settingsEditsReachTheFile() throws {
        let store = try MCPFixtures.store()
        store.setExposure("linear", .direct)
        store.setTools("linear", ["create_issue"])
        store.setStart("linear", .alwaysOn)
        guard case .document(let document) = store.dependencies.file.read() else { Issue.record("unreadable"); return }
        let settings = try #require(document.server("linear")).settings
        #expect(settings.exposure == .direct && settings.tools == ["create_issue"] && settings.start == .alwaysOn)
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

    @Test func aDirectToolCostsItsBytesOverFourPlusTen() {
        let tool = MCPToolInfo(name: "query", description: "Run SQL.", inputSchema: .object(["type": .string("object")]))
        // "query" 5 + "Run SQL." 8 + {"type":"object"} 17 = 30 bytes → 8 + 10.
        #expect(MCPBudgetEstimate.tokens(for: tool) == 18)
    }

    @Test(arguments: [(0, 0), (184, 180), (185, 190), (999, 1000), (3_870, 3_900), (12_349, 12_300)])
    func totalsRoundToTensThenHundreds(tokens: Int, rounded: Int) {
        #expect(MCPBudgetEstimate.rounded(tokens) == rounded)
    }

    @Test func proxyServersCostTwoHundredTogether() throws {
        let tools = MCPFixtures.tools(["a", "b", "c"])
        #expect(MCPBudgetEstimate.total([(.proxy, tools, nil), (.proxy, tools, nil)]) == 200)
        let direct = MCPBudgetEstimate.directTokens(tools, chosen: ["a"])
        #expect(MCPBudgetEstimate.total([(.proxy, tools, nil), (.direct, tools, ["a"])]) == 200 + direct)
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
        #expect(MCPServerName.toolPrefix("My-Server.v2") == "my_server_v2")
    }
}
