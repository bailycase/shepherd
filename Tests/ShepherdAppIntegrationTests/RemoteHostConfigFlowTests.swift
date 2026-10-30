import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A client changing this Mac's Settings over the listener, through the view model's real
/// handlers: the Experiments switches (Design tool while it is off, Missions under a live mission)
/// and the configuration a client edits (an MCP server with a secret, a subagent profile fenced by
/// its fingerprint).
@Suite("Remote host configuration", .integrationTimeLimit)
@MainActor
struct RemoteHostConfigFlowTests {
    private static func connect(_ app: AppHarness) async throws -> RemoteHostClient {
        let tokenURL = app.dir.appendingPathComponent("remote-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "settings")
        return client
    }

    @Test func aClientTurnsTheDesignToolOnWhileItIsOffAndCantTurnMissionsOffUnderALiveMission() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        try await app.start()
        let mission = try await app.server.createMission(draft: MissionDraft(title: "Ship", goal: "Ship it."))
        _ = try await app.server.setMissionRun(id: mission.id, expectedRevision: mission.revision,
                                               run: MissionRun(model: "anthropic/claude", phase: .planning))
        try await eventuallyOnMain("the mission to plan") { app.vm.state.missions.first?.run?.phase == .planning }
        let client = try await Self.connect(app)
        defer { client.disconnect() }

        // The switch is offered while the tool is off; designs.v1 is not.
        #expect(client.capabilities.contains(RemoteProtocol.designToolExperimentCapability))
        #expect(!client.capabilities.contains(RemoteProtocol.designsCapability))
        let fetched = try await client.hostSettings()
        #expect(!fetched.designToolEnabled && fetched.missionsActive)
        #expect(try await client.hostSettings(.change(.designToolEnabled(true))).designToolEnabled)
        #expect(app.settings.designToolEnabled)
        try await eventuallyOnMain("the host to offer designs") { client.capabilities.contains(RemoteProtocol.designsCapability) }

        #expect(try await client.hostSettings(.change(.missionsEnabled(true))).missionsEnabled)
        do {
            try await client.hostSettings(.change(.missionsEnabled(false)))
            Issue.record("Missions went off under a live mission")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "settings_failed" && message == HostSettingsMapping.missionsLocked)
        }
        #expect(app.settings.missionsEnabled, "the host kept Missions on")

        // hostSettings.v2 reaches the Mac's own settings.
        let defaults = HostSettings.SubagentDefaults(concurrency: 3, model: "openai/gpt-5-mini", thinking: .low, context: .fork)
        #expect(try await client.hostSettings(.change(.subagentDefaults(defaults))).subagentDefaults == defaults)
        #expect(app.settings.childConcurrency == 3 && app.settings.childContext == "fork")
        _ = try await client.hostSettings(.change(.slashCommand(name: "review", on: false)))
        #expect(app.settings.hiddenSlashCommands == ["review"])
    }

    @Test func anMCPSecretGoesToTheKeychainAndNoReplyCarriesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let secrets = InMemorySecretStore()
        let cli = MCPSettingsControlTests.RecordingCLI()
        cli.list = MCPSettingsControlTests.listJSON([("linear", "connected", ["search"])])
        let store = try MCPSettingsControlTests.store(config: #"{ "mcpServers": {} }"#, cli: cli,
                                                      pasteboard: MCPSettingsControlTests.Pasteboard(), secrets: secrets)
        try await app.start(mcp: store)
        let client = try await Self.connect(app)
        defer { client.disconnect() }
        let secret = "lin_live_0123456789"

        let saved = try await client.hostConfig(.mcpSave(
            json: #"{"mcpServers":{"linear":{"command":"npx","args":["linear-mcp"],"env":{"LINEAR_API_KEY":"typed on the phone"}}}}"#,
            secrets: ["LINEAR_API_KEY": secret], replacing: nil))
        guard case .mcp(let inventory) = saved else { Issue.record("expected the servers"); return }
        #expect(inventory.servers.map(\.name) == ["linear"])
        #expect(secrets.value(for: "secret/linear/LINEAR_API_KEY") == secret)
        #expect(store.entry("linear")?.env["LINEAR_API_KEY"] == "${keychain:linear/LINEAR_API_KEY}")
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains(secret))

        guard case .mcpEntry(let json) = try await client.hostConfig(.mcpEntry(name: "linear")) else { Issue.record("expected JSON"); return }
        #expect(json.contains("${keychain:linear/LINEAR_API_KEY}") && !json.contains(secret))

        _ = try await client.hostConfig(.mcpSetEnabled(name: "linear", on: false))
        #expect(store.entry("linear")?.settings.enabled == false)
        // An edit keeps the Mac's own switches.
        _ = try await client.hostConfig(.mcpSave(json: json, secrets: [:], replacing: "linear"))
        #expect(store.entry("linear")?.settings.enabled == false && secrets.value(for: "secret/linear/LINEAR_API_KEY") == secret)
        await #expect(throws: RemoteHostClientError.self) {
            try await client.hostConfig(.mcpSave(json: json, secrets: [:], replacing: nil))
        }
        _ = try await client.hostConfig(.mcpRemove(name: "linear"))
        #expect(store.entry("linear") == nil && secrets.value(for: "secret/linear/LINEAR_API_KEY") == nil)
    }

    @Test func aProfileChangedSinceTheClientReadItIsRefused() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.madeSubagentDefinitions = SubagentDefinitionsModel(store: try SubagentFixtures.store(in: app.dir))
        let client = try await Self.connect(app)
        defer { client.disconnect() }
        let text = "---\nname: remote\ndescription: Made on the phone\ntools: [read]\n---\nRead the code.\n"

        guard case .subagent(let saved) = try await client.hostConfig(.subagentSave(file: "remote.md", text: text, fingerprint: nil)) else {
            Issue.record("expected the profile"); return
        }
        #expect(saved.text == text)
        _ = try await client.hostConfig(.subagentSave(file: "remote.md", text: text + "More.\n", fingerprint: saved.fingerprint))
        await #expect(throws: RemoteHostClientError.self, "the fingerprint the client read is stale now") {
            try await client.hostConfig(.subagentSave(file: "remote.md", text: text, fingerprint: saved.fingerprint))
        }
        await #expect(throws: RemoteHostClientError.self) {
            try await client.hostConfig(.subagentDelete(file: "remote.md", fingerprint: saved.fingerprint))
        }
        guard case .subagent(let current) = try await client.hostInventory(.subagent(file: "remote.md")) else { Issue.record("expected text"); return }
        guard case .subagents(let profiles) = try await client.hostConfig(.subagentDelete(file: "remote.md", fingerprint: current.fingerprint)) else {
            Issue.record("expected the profiles"); return
        }
        #expect(!profiles.contains { $0.file == "remote.md" })
        #expect(profiles.filter(\.isDefault).allSatisfy { $0.fingerprint != nil })
    }
}
