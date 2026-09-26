import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Stage 1 end to end: an agent's bundled MCP extension (on node, with pi stood in) reaches the
/// servers in Settings ▸ MCP servers through the app. The view model is wired as the app wires
/// it, to a real `MCPStore` on a scratch config with in-memory secrets. A local stdio server gets
/// its `${keychain:…}` secret, a remote one on 127.0.0.1 gets an OAuth bearer from a sign-in
/// already done, a server nobody signed in to answers with the sign-in text, and each row in
/// Settings shows what the extension reported.
@Suite("MCP end to end", .mainActorExclusive, .enabled(if: MCPAgentHarness.node != nil, "needs node 22.6 or later"))
@MainActor
struct MCPEndToEndTests {
    private struct NoProbe: MCPProbeRunner {
        func run(input: Data, timeout: TimeInterval) async -> Data { Data() }
    }

    @Test func anAgentSearchesAndCallsToolsOnALocalAndASignedInServer() async throws {
        let fake = try FakeMCPOAuth(seed: (access: "at-seeded", refresh: "rt-seeded", scope: "read"))
        defer { fake.stop() }
        let node = try #require(MCPAgentHarness.node)
        let dir = try makeScratchDirectory()
        let config = dir.appendingPathComponent("mcp.json")
        let entries: [String: JSONValue] = [
            "local": .object([
                "command": .string(node.path), "args": .array([.string(MCPAgentHarness.stdioFixture.path)]),
                "env": .object(["FAKE_TOKEN": .string("${keychain:local/FAKE_TOKEN}")]),
            ]),
            "tracker": .object(["type": .string("http"), "url": .string(fake.mcpURL.absoluteString)]),
            "unsigned": .object(["type": .string("http"), "url": .string(fake.mcpURL.absoluteString)]),
        ]
        try JSONEncoder().encode(JSONValue.object(["mcpServers": .object(entries)])).write(to: config)

        // What a completed sign-in leaves in Keychain: a token for tracker's server, refreshed an
        // hour ago with a refresh token the authorization server still honours.
        let nowMs = MCPStore.ms(Date())
        let token = MCPOAuthToken(
            issuer: fake.base + "/auth", tokenEndpoint: fake.base + "/auth/token", clientID: "client-1",
            redirectURI: "http://127.0.0.1:1/callback", resource: fake.mcpURL.absoluteString, accessToken: "at-seeded",
            refreshToken: "rt-seeded", expiresAtMs: nowMs + 3_600_000, scopes: ["read"], account: "baily@acme.dev",
            refreshedAtMs: nowMs - 3_600_000)
        let secrets = InMemorySecretStore([
            "secret/local/FAKE_TOKEN": "s3cret",
            "oauth/tracker": String(decoding: try JSONEncoder().encode(token), as: UTF8.self),
        ])
        let store = MCPStore(dependencies: .init(
            file: MCPConfigFile(url: config), cacheURL: dir.appendingPathComponent("tools.json"), secrets: secrets,
            http: URLSessionHTTP(), probe: MCPProbe(runner: NoProbe()), openURL: { _ in }, copy: { _ in }, now: { Date() }))

        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: dir.path)
        let worker = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [worker]), mcp: store)
        #expect(vm.mcp === store)

        let extensionDir = dir.appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        let agent = try MCPAgentHarness(
            directory: extensionDir, extensionSource: MCPExtension.extensionSource, clientSource: MCPExtension.clientSource,
            environment: [
                "SHEPHERD_AGENT_ID": worker.agent.id.rawValue, "SHEPHERD_SOCKET": app.scratch.socketPath,
                "SHEPHERD_EXT_MCP_CONFIG": config.path, "SHEPHERD_EXT_MCP_CACHE": dir.appendingPathComponent("tools.json").path,
            ])
        defer { agent.stop() }

        let run = try await agent.run([
            .mcp(["action": .string("search"), "query": .string("echo")]),
            .mcp(["action": .string("call"), "server": .string("local"), "tool": .string("env"),
                  "arguments": .object(["name": .string("FAKE_TOKEN")])]),
            .mcp(["action": .string("search"), "query": .string("issues")]),
            .mcp(["action": .string("call"), "server": .string("tracker"), "tool": .string("list_issues"), "arguments": .object([:])]),
            .mcp(["action": .string("call"), "server": .string("unsigned"), "tool": .string("list_issues"), "arguments": .object([:])]),
        ])
        #expect(run.tools == ["mcp"])
        try #require(run.results.count == 5)
        #expect(run.results[0].text?.contains("local/echo") == true, "\(run.results[0])")
        // The secret reached the stdio server's environment from the app's secret store.
        #expect(run.results[1].text == "FAKE_TOKEN=s3cret", "\(run.results[1])")
        #expect(run.results[2].text?.contains("tracker/list_issues") == true, "\(run.results[2])")
        #expect(run.results[3].text == "ISSUE-1 The login page loops", "\(run.results[3])")
        // No sign-in: the agent reads where to sign in, and nothing crashed.
        #expect(run.results[4].ok == false)
        #expect(run.results[4].error?.contains("unsigned needs you to sign in: Settings ▸ MCP servers.") == true, "\(run.results[4])")

        // tracker's server saw the bearer the app handed over (refreshed on its first 401).
        let calls = try await fake.log().filter { $0["path"] == "/mcp" && $0["body"]?.contains("list_issues") == true }
        #expect(calls.contains { $0["authorization"]?.hasPrefix("Bearer at-") == true && $0["body"]?.contains("tools/call") == true })

        // Settings ▸ MCP servers shows what the extension reported, while the agent lives.
        try await eventuallyOnMain("the rows to show the reports") {
            store.rows.first { $0.name == "local" }?.status == .connected
                && store.rows.first { $0.name == "tracker" }?.status == .connected
        }
        #expect(store.rows.first { $0.name == "local" }?.tools == 6)
        #expect(store.rows.first { $0.name == "tracker" }?.tools == 2)
        #expect(store.rows.first { $0.name == "unsigned" }?.status == .needsYou)
        #expect(store.entry("unsigned").map(store.status(of:))?.state == .needsSignIn)
        #expect(store.count(.connected) == 2)
    }

    /// The page's own probe runs the client MCPExtension installs, with node in a login shell,
    /// before any agent has launched: a server with no cache lists its tools.
    @Test func theProbeListsAServersToolsWithTheInstalledClient() async throws {
        let node = try #require(MCPAgentHarness.node)
        let dir = try makeScratchDirectory()
        let config = dir.appendingPathComponent("mcp.json")
        let entry: JSONValue = .object([
            "command": .string(node.path), "args": .array([.string(MCPAgentHarness.stdioFixture.path)]),
            "env": .object(["FAKE_TOKEN": .string("${keychain:local/FAKE_TOKEN}")]),
        ])
        try JSONEncoder().encode(JSONValue.object(["mcpServers": .object(["local": entry])])).write(to: config)
        let store = MCPStore(dependencies: .init(
            file: MCPConfigFile(url: config), cacheURL: dir.appendingPathComponent("tools.json"),
            secrets: InMemorySecretStore(["secret/local/FAKE_TOKEN": "s3cret"]), http: URLSessionHTTP(),
            probe: MCPProbe(runner: NodeProbeRunner(clientPath: ShepherdViewModel.mcpClientPath)),
            openURL: { _ in }, copy: { _ in }, now: { Date() }))
        store.probe("local")
        try await eventuallyOnMain("the probe to list local's tools") { store.rows.first.map { $0.tools != nil || $0.status == .error } == true }
        #expect(store.rows.first?.tools == 6, "\(String(describing: store.rows.first))")
        // A probe lists tools; only an agent's connection makes the row connected (CONTRACT §5).
        #expect(store.rows.first?.status == .idle)
        #expect(FileManager.default.fileExists(atPath: try MCPExtension.clientPath()))
    }
}
