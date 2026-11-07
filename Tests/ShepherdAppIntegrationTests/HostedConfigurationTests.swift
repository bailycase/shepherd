import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ MCP and Subagents served by the background host with no app (`HostStores.serve`):
/// a client over `host.sock` reads the inventory and changes it through the host's stores.
@Suite("Configuration hosted with no app", .mainActorExclusive)
@MainActor
struct HostedConfigurationTests {
    @Test func aClientEditsTheHostsMCPServersAndSubagentProfiles() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let secrets = InMemorySecretStore()
        let cli = MCPSettingsControlTests.RecordingCLI()
        cli.list = MCPSettingsControlTests.listJSON([("linear", "connected", ["search"])])
        let mcp = try MCPSettingsControlTests.store(config: #"{ "mcpServers": {} }"#, cli: cli,
                                                    pasteboard: MCPSettingsControlTests.Pasteboard(), secrets: secrets)
        let subagents = SubagentDefinitionsModel(store: try SubagentFixtures.store(in: host.dir))
        HostStores(mcp: mcp, subagents: { subagents }, piAuth: PiAuthStore(pi: host.server.pi), yourPi: YourPiModel(pi: host.server.pi),
                   remoteSignIns: RemoteSignIns()).serve(on: host.server)

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(localSocket: socket)
        _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
        defer { client.disconnect() }

        let secret = "lin_live_0123456789"
        _ = try await client.hostConfig(.mcpSave(
            json: #"{"mcpServers":{"linear":{"command":"npx","args":["linear-mcp"],"env":{"LINEAR_API_KEY":"typed"}}}}"#,
            secrets: ["LINEAR_API_KEY": secret], replacing: nil))
        #expect(secrets.value(for: "secret/linear/LINEAR_API_KEY") == secret)
        guard case .mcp(let inventory) = try await client.hostInventory(.mcp) else { Issue.record("expected the servers"); return }
        #expect(inventory.servers.map(\.name) == ["linear"])

        let text = "---\nname: remote\ndescription: Made on the phone\ntools: [read]\n---\nRead the code.\n"
        _ = try await client.hostConfig(.subagentSave(file: "remote.md", text: text, fingerprint: nil))
        guard case .subagents(let profiles) = try await client.hostInventory(.subagents) else { Issue.record("expected the profiles"); return }
        #expect(profiles.contains { $0.file == "remote.md" && $0.description == "Made on the phone" })
    }
}
