import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

/// A probe that answers as the node client would for a connected server, and records what it
/// was handed.
private final class RecordingProbe: MCPProbeRunner, @unchecked Sendable {
    let inputs = Locked<[String]>([])

    func run(input: Data, timeout: TimeInterval) async -> Data {
        inputs.withValue { $0.append(String(decoding: input, as: UTF8.self)) }
        return Data(#"{"ok":true,"transport":"streamableHTTP","serverName":"Fake MCP","tools":[{"name":"list_issues","description":"Lists issues.","inputSchema":{"type":"object"}},{"name":"create_issue","description":"Creates an issue.","inputSchema":{"type":"object"}}]}"#.utf8)
    }
}

/// OAuth end to end against a fake protected MCP server and authorization server on 127.0.0.1:
/// discovery from the 401, dynamic registration, PKCE in a scripted browser that follows the
/// authorize redirect to the loopback listener, the token exchange, refresh, and signing in
/// again for more scopes. No real network.
@Suite("MCP OAuth flow", .mainActorExclusive)
@MainActor
struct MCPOAuthFlowTests {
    private struct Harness {
        let fake: FakeMCPOAuth
        let store: MCPStore
        let secrets: InMemorySecretStore
        let probe: RecordingProbe
        let now: Locked<Date>
    }

    private func harness(deny: Bool = false) throws -> Harness {
        let fake = try FakeMCPOAuth(deny: deny)
        let directory = try makeScratchDirectory()
        let config = directory.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers": {"fake": {"type": "http", "url": "\#(fake.mcpURL.absoluteString)"}}}"#.utf8).write(to: config)
        let secrets = InMemorySecretStore()
        let probe = RecordingProbe()
        let now = Locked(Date())
        let store = MCPStore(dependencies: MCPStore.Dependencies(
            file: MCPConfigFile(url: config), cacheURL: directory.appendingPathComponent("tools.json"), secrets: secrets,
            http: URLSessionHTTP(), probe: MCPProbe(runner: probe),
            // The scripted browser: it follows the authorize page's redirect to the loopback listener.
            openURL: { url in Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: url) } },
            copy: { _ in }, now: { now.current }))
        return Harness(fake: fake, store: store, secrets: secrets, probe: probe, now: now)
    }

    @Test func signingInDiscoversRegistersAndStoresTheToken() async throws {
        let h = try harness()
        defer { h.fake.stop() }
        let agent = AgentID()

        // An agent's first call: the server answers 401 and nobody has signed in.
        let challenge = try await h.fake.challenge()
        #expect(await h.store.credentials(for: MCPRequest(agentID: agent, server: "fake", reason: .unauthorized, challenge: challenge))
            == .failure(code: "needs_sign_in", message: "fake needs you to sign in: Settings ▸ MCP servers."))
        #expect(h.store.rows.first?.signIn == .signIn)

        h.store.beginSignIn("fake")
        let flow = try #require(h.store.signIn)
        try await eventuallyOnMain("the sign-in to finish") { flow.succeeded || flow.model.phase == .failed }
        #expect(flow.model.phase == .done)
        #expect(flow.model.steps.map(\.state) == [.done, .done, .done])
        #expect(flow.model.steps.map(\.title) == ["Found Fake’s sign-in server", "Registered Shepherd with Fake", "Signed in as baily@acme.dev"])
        #expect(flow.model.steps[1].note == "Dynamic client registration")
        #expect(flow.model.subtitle == "fake is connected: 2 tools.")

        let token = try #require(h.store.token("fake"))
        #expect(token.account == "baily@acme.dev")
        #expect(token.resource == h.fake.mcpURL.absoluteString)
        #expect(token.scopes == ["read", "write"])
        // The token lives in the secret store, never in mcp.json.
        #expect(h.secrets.value(for: "oauth/fake") != nil)
        #expect(!(try String(contentsOf: h.store.dependencies.file.url, encoding: .utf8)).contains(token.accessToken))
        #expect(h.store.rows.first?.signIn == .account("baily@acme.dev"))
        #expect(h.store.rows.first?.tools == 2)
        // The probe after signing in carried the bearer.
        #expect(h.probe.inputs.current.last?.contains("Bearer \(token.accessToken)") == true)

        // The server saw PKCE S256, the resource on authorize and token, and a loopback redirect.
        let log = try await h.fake.log()
        let authorize = try #require(log.first { $0["path"]?.hasPrefix("/auth/authorize") == true }?["path"])
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(string: authorize)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["resource"] == h.fake.mcpURL.absoluteString)
        #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(query["scope"] == "read write")
        let exchange = try #require(log.first { $0["path"] == "/auth/token" }?["body"])
        #expect(exchange.contains("code_verifier=") && exchange.contains("resource="))

        // Handed to an agent, it works against the server.
        guard case .credentials(let credentials) = await h.store.credentials(for: MCPRequest(agentID: agent, server: "fake", reason: .connect)) else {
            Issue.record("no credentials after signing in")
            return
        }
        #expect(credentials.bearer == token.accessToken)
        #expect(try await status(of: h.fake, bearer: token.accessToken) == 200)

        // A 401 later refreshes it: a new access token, and the old refresh token is used up.
        h.now.withValue { $0 = $0.addingTimeInterval(60) }
        guard case .credentials(let refreshed) = await h.store.credentials(for: MCPRequest(agentID: agent, server: "fake", reason: .unauthorized)) else {
            Issue.record("the refresh failed")
            return
        }
        #expect(refreshed.bearer != token.accessToken)
        #expect(try await status(of: h.fake, bearer: refreshed.bearer ?? "") == 200)
        #expect(h.store.token("fake")?.refreshToken != token.refreshToken)
    }

    /// The provider said no: the sheet says so in its words, and nothing is saved.
    @Test func aDeniedSignInSavesNothing() async throws {
        let h = try harness(deny: true)
        defer { h.fake.stop() }
        h.store.beginSignIn("fake")
        let flow = try #require(h.store.signIn)
        try await eventuallyOnMain("the sign-in to fail") { flow.model.phase == .failed || flow.succeeded }
        #expect(flow.model.phase == .failed)
        #expect(flow.model.subtitle == "Nothing was saved.")
        let failed = try #require(flow.model.steps.last)
        #expect(failed.state == .failed)
        #expect(failed.title == "Fake didn’t allow access")
        #expect(failed.note == "access_denied: you chose Cancel")
        #expect(h.store.token("fake") == nil)
        #expect(h.secrets.value(for: "oauth/fake") == nil)
    }

    /// A 403 insufficient_scope: the row asks for more access, and signing in again asks for the
    /// current scopes plus the missing one.
    @Test func moreAccessSignsInAgainForTheMissingScopes() async throws {
        let h = try harness()
        defer { h.fake.stop() }
        h.store.beginSignIn("fake")
        let first = try #require(h.store.signIn)
        try await eventuallyOnMain("the first sign-in") { first.succeeded || first.model.phase == .failed }
        let token = try #require(h.store.token("fake"))

        let challenge = try await forbiddenChallenge(h.fake, bearer: token.accessToken)
        #expect(await h.store.credentials(for: MCPRequest(agentID: AgentID(), server: "fake", reason: .forbidden, challenge: challenge))
            == .failure(code: "needs_scopes", message: "fake needs more access (issues:write): sign in again in Settings ▸ MCP servers."))
        #expect(h.store.rows.first?.signIn == .moreAccess(["issues:write"]))

        h.store.beginSignIn("fake")
        let again = try #require(h.store.signIn)
        try await eventuallyOnMain("signing in again") { again.succeeded || again.model.phase == .failed }
        #expect(again.model.phase == .done)
        #expect(h.store.token("fake")?.scopes == ["read", "write", "issues:write"])
        #expect(h.store.rows.first?.signIn == .account("baily@acme.dev"))
    }

    /// The Add sheet's URL check: the server answers 401, and its resource metadata leads to a
    /// sign-in server that registers clients ("OAuth · found").
    @Test func theAddSheetsCheckFindsOAuth() async throws {
        let fake = try FakeMCPOAuth()
        defer { fake.stop() }
        let result = await MCPURLCheck.check(fake.mcpURL, http: URLSessionHTTP())
        guard case .needsSignIn(let challenge) = result else {
            Issue.record("expected a sign-in, got \(result)")
            return
        }
        let discovery = try await MCPOAuthService(http: URLSessionHTTP()).discover(server: fake.mcpURL,
                                                                                   challenge: MCPAuthChallenge.bearer(in: challenge))
        #expect(discovery.resourceMetadata?.resourceName == "Fake MCP")
        #expect(discovery.issuer == fake.base + "/auth")
        #expect(discovery.metadata.registrationEndpoint == fake.base + "/auth/register")
    }

    private func status(of fake: FakeMCPOAuth, bearer: String) async throws -> Int {
        var request = URLRequest(url: fake.mcpURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func forbiddenChallenge(_ fake: FakeMCPOAuth, bearer: String) async throws -> String? {
        var request = URLRequest(url: fake.mcpURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_issue"}}"#.utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
    }
}
