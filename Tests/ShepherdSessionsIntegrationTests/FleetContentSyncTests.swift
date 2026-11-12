import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Fleet's content units between real scratch hosts (slice 2b-ii): MCP servers in the shared `mcp.json`,
/// Shepherd's own hooks, subagent profiles and spaces. Each Mac has its own home folder, its own
/// `mcp.json`, hooks files and pi home, so what one Mac saves is what the other writes through its own
/// writer, and nothing is shared but the wire.
@Suite("Fleet content sync", .integrationTimeLimit)
struct FleetContentSyncTests {
    typealias Mac = FleetSyncTests.Mac

    /// A Mac in the fleet with every file it syncs under its own scratch folder.
    final class Node: @unchecked Sendable {
        let mac: Mac
        let home: URL
        var server: SessionServer { mac.server }
        var name: String { mac.name }
        var mcpURL: URL { home.appendingPathComponent("config/mcp/mcp.json") }
        var mcp: MCPConfigFile { MCPConfigFile(url: mcpURL) }
        var hooksFile: String { home.path + "/.shepherd/hooks.json" }
        /// Subagent profiles, through the store the host itself writes with (the staged engine, not the app's).
        let subagents: SubagentDefinitionsStore

        init(_ name: String) async throws {
            mac = try await Mac(name, enable: false)
            home = mac.host.dir.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            mac.server.mcpConfigFile = MCPConfigFile(url: home.appendingPathComponent("config/mcp/mcp.json"))
            mac.server.hooks = HookCatalog(home: home.path, support: mac.host.dir)
            subagents = try SubagentFixtures.store(piHome: mac.server.pi.home)
            mac.server.fleetSubagentStore = subagents
        }

        func stop() { mac.stop() }

        func servers() -> [String: MCPServerEntry] {
            guard case .document(let document) = mcp.read() else { return [:] }
            return Dictionary(uniqueKeysWithValues: document.servers.map { ($0.name, $0) })
        }

        func hooks() -> [HookEntry] { server.hooks.load().entries.filter { $0.file == hooksFile } }

        func spaces() -> [Space] { server.state.spaces.filter(FleetSpacesSource.syncs) }
    }

    /// Two paired Macs with links both ways, each syncing its own files. `before` runs while Fleet is still off.
    static func pair(before: (Node, Node) throws -> Void = { _, _ in }) async throws -> (Node, Node) {
        let a = try await Node("MacBook Pro"), b = try await Node("Mac mini")
        try before(a, b)
        a.mac.enable()
        b.mac.enable()
        try await a.mac.pair(with: b.mac)
        try await a.mac.waitForLink(to: b.mac)
        try await b.mac.waitForLink(to: a.mac)
        return (a, b)
    }

    static let postgres = MCPServerEntry.local("postgres", command: "uvx", args: ["postgres-mcp", "--access-mode=restricted"], env: ["DATABASE_URI": "${keychain:postgres/DATABASE_URI}"])

    // MARK: MCP

    @Test func aServerAddedOnOneMacAppearsInTheOthersSharedFile() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try a.mcp.update { $0.upsert(Self.postgres) }
        try await eventually("Mac mini's mcp.json to list postgres") { b.servers()["postgres"] != nil }
        let there = try #require(b.servers()["postgres"])
        #expect(there.command == "uvx" && there.args == ["postgres-mcp", "--access-mode=restricted"])
        // The secret stayed a reference: its value is in a Keychain, which does not sync here.
        #expect(there.env["DATABASE_URI"] == "${keychain:postgres/DATABASE_URI}")

        // A switch inside the entry (Shepherd's own fields) and a removal both travel.
        try a.mcp.update { document in
            var entry = document.server("postgres")!
            var settings = entry.settings
            settings.enabled = false
            entry.settings = settings
            document.upsert(entry)
        }
        try await eventually("postgres to be off on Mac mini") { b.servers()["postgres"]?.settings.enabled == false }
        try a.mcp.update { $0.remove("postgres") }
        try await eventually("postgres to go from Mac mini") { b.servers()["postgres"] == nil }
    }

    @Test func aHandEditOfTheSharedFileIsImportedAndKeepsEverythingElseInIt() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // Another tool's key and plaintext values are the file's, not Shepherd's.
        let edited = """
        {
          "mcpServers": {
            "grafana": { "command": "mcp-grafana", "env": { "GRAFANA_URL": "http://localhost:3000" } }
          },
          "otherTool": { "keep": true }
        }
        """
        try Data(edited.utf8).write(to: b.mcpURL.deletingLastPathComponent().appendingPathComponent("mcp.json"), options: .atomic)
        try await eventually("MacBook Pro to import the hand edit") { a.servers()["grafana"]?.env["GRAFANA_URL"] == "http://localhost:3000" }

        // The other Mac's later write goes in beside what the hand edit left, never over it.
        try a.mcp.update { $0.upsert(Self.postgres) }
        try await eventually("Mac mini to get postgres") { b.servers()["postgres"] != nil }
        let text = try String(contentsOf: b.mcpURL, encoding: .utf8)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((root["otherTool"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(b.servers()["grafana"] != nil)
    }

    @Test func aFileThatDoesNotParseIsWaitedOutNeverReadAsNoServers() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try a.mcp.update { $0.upsert(Self.postgres) }
        try await eventually("Mac mini to get postgres") { b.servers()["postgres"] != nil }

        // Mac mini's file is half typed. Its sync looks at it, and a broken file is not "no servers".
        let broken = Data("{ \"mcpServers\": ".utf8)
        try broken.write(to: b.mcpURL, options: .atomic)
        b.server.queue.sync { b.server.fleet?.syncEngine.localChanged() }
        let winner = try #require(b.server.fleetSyncWinner("mcpServer:postgres"))
        if case .deletion = winner.change { Issue.record("a file that doesn't parse deleted a server") }

        // A change from the other Mac cannot be written over it either.
        try a.mcp.update { $0.upsert(MCPServerEntry.remote("linear", url: "https://mcp.linear.app/mcp")) }
        try await eventually("Mac mini to hold the linear op") { b.server.fleetSyncWinner("mcpServer:linear") != nil }
        #expect(try Data(contentsOf: b.mcpURL) == broken)

        // Fixed, it is read again, and the change that waited lands.
        let fixed = #"{"mcpServers": {"postgres": {"command": "uvx", "args": ["postgres-mcp", "--access-mode=restricted"], "env": {"DATABASE_URI": "${keychain:postgres/DATABASE_URI}"}}}}"#
        try Data(fixed.utf8).write(to: b.mcpURL, options: .atomic)
        try await eventually("Mac mini to get linear") { b.servers()["linear"] != nil }
        #expect(a.servers()["postgres"] != nil && b.servers()["postgres"] != nil)
    }

    // MARK: Hooks

    @Test func aHookAndItsSwitchSyncThroughShepherdsOwnHooksFile() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let writer = HookFileWriter(settings: a.server.hooks.settingsStore)
        let hash = try writer.add(HookDraft(event: "PreToolUse", matcher: "Bash", handler: .command("./scripts/check.sh", timeout: 10)), to: a.hooksFile)
        try await eventually("Mac mini to have the hook") { b.hooks().count == 1 }
        let there = try #require(b.hooks().first)
        #expect(there.event == "PreToolUse" && there.matcher == "Bash" && there.handler.command == "./scripts/check.sh" && there.on)
        #expect(there.file == b.hooksFile, "it is in Mac mini's own file, under Mac mini's own home")
        #expect(there.hash != hash, "the hash covers the file's path, which differs; the unit's id does not")

        // Switching it off on Mac mini reaches the first Mac's own switch file.
        try b.server.hooks.settingsStore.setOn(there.hash, false)
        try await eventually("MacBook Pro's hook to be off") { a.hooks().first?.on == false }

        // Removing it removes it there, and the off switch with it.
        try writer.delete(try #require(a.hooks().first))
        try await eventually("Mac mini to lose the hook") { b.hooks().isEmpty }
        #expect(b.server.hooks.settingsStore.read().off.isEmpty)
    }

    @Test func theSourcesSwitchesSyncAndHooksOfOtherToolsDoNot() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // A hook in Claude Code's own file is that tool's, and stays on its Mac.
        let claude = a.home.path + "/.claude/settings.json"
        _ = try HookFileWriter(settings: a.server.hooks.settingsStore).add(HookDraft(event: "Stop", handler: .command("say done")), to: claude)
        try a.server.hooks.settingsStore.setReader(.codex, false)
        try await eventually("Mac mini's Codex reader to be off") { !b.server.hooks.settingsStore.read().readers.codex }
        #expect(b.server.hooks.settingsStore.read().readers.claude)
        #expect(b.server.hooks.load().entries.filter { $0.format == .claude }.isEmpty)
        #expect(b.server.fleetSyncWinner(FleetUnit.setting("hooks.readers")) != nil)
    }

    // MARK: Subagents

    @Test func aSubagentProfileSyncsThroughTheDefinitionsStore() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let text = SubagentFixtures.samples["api-review.md"]!
        try a.subagents.save("api-review.md", text: text, expected: nil)
        try await eventually("Mac mini to have api-review.md") { (try? b.subagents.files().first { $0.file == "api-review.md" }?.text) == text }

        // An edit goes the same way, and so does a removal.
        let edited = text.replacingOccurrences(of: "Do not edit files.", with: "Never edit files.")
        let current = try #require(try a.subagents.files().first { $0.file == "api-review.md" })
        try a.subagents.save("api-review.md", text: edited, expected: current.fingerprint)
        try await eventually("Mac mini to have the edit") { (try? b.subagents.files().first { $0.file == "api-review.md" }?.text) == edited }
        let there = try #require(try b.subagents.files().first { $0.file == "api-review.md" })
        try b.subagents.delete("api-review.md", expected: there.fingerprint)
        try await eventually("MacBook Pro to lose it") { (try? a.subagents.files().contains { $0.file == "api-review.md" }) == false }
    }

    @Test func aProfileThisMacsPiRefusesStaysOutAndTheOthersStillSync() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // A hand written file with a field pi's subagents don't take: it is a file on the first Mac, so it is
        // offered, and the second Mac's store refuses to load it rather than write what pi can't read.
        try FileManager.default.createDirectory(at: a.subagents.directory, withIntermediateDirectories: true)
        try Data(SubagentFixtures.samples["reviewer-strict.md"]!.utf8).write(to: a.subagents.directory.appendingPathComponent("reviewer-strict.md"), options: .atomic)
        try a.subagents.save("test-writer.md", text: SubagentFixtures.samples["test-writer.md"]!, expected: nil)
        try await eventually("Mac mini to have test-writer.md") { (try? b.subagents.files().contains { $0.file == "test-writer.md" }) == true }
        #expect(try b.subagents.files().contains { $0.file == "reviewer-strict.md" } == false)
        #expect(a.server.fleetSyncWinner("subagent:reviewer-strict.md") != nil, "it was offered")
    }

    // MARK: Spaces

    private func git(_ folder: URL, _ arguments: [String]) throws {
        let result = try BoundedCommand.run(["/usr/bin/git", "-C", folder.path] + arguments, timeout: 30)
        #expect(result.status == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    /// A folder that is a git checkout of `remote`.
    private func checkout(_ name: String, under parent: URL, remote: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git(folder, ["init", "-q"])
        try git(folder, ["remote", "add", "origin", remote])
        return folder
    }

    @Test func aSpaceSyncsWithItsRepoKeyAndStaysUnboundOnAMacWithoutTheFolder() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let folder = try checkout("acme-web", under: a.mac.host.dir, remote: "git@github.com:Acme/Web.git")
        let space = Space(name: "acme-web", path: folder.path, worktreeBase: "origin/main")
        try await a.server.addSpace(space)

        // The host works the key out of the checkout's origin, whatever its spelling.
        try await eventually("MacBook Pro to know the repo key") { a.spaces().first?.repoKey == "github.com/acme/web" }
        let unit = "space:" + space.id.rawValue
        try await eventually("Mac mini to hold the space") {
            guard case .value(let text)? = b.server.fleetSyncWinner(unit)?.change else { return false }
            return text.contains("github.com/acme/web")
        }
        // No folder here: it is not added, so no thread can start in a place that isn't there.
        #expect(b.spaces().isEmpty)

        // A folder located later binds it, and it appears with what the fleet knows.
        let there = b.mac.host.dir.appendingPathComponent("code/acme-web", isDirectory: true)
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        b.server.bindFleetSpace(space.id, to: there.path)
        try await eventually("Mac mini to have the space") { b.spaces().first?.id == space.id }
        let bound = try #require(b.spaces().first)
        #expect(bound.path == there.path && bound.name == "acme-web" && bound.repoKey == "github.com/acme/web" && bound.worktreeBase == "origin/main")

        // A rename and a hide on the first Mac reach the second, which keeps its own folder.
        var renamed = try #require(a.spaces().first)
        renamed.name = "web"
        renamed.sidebarHidden = true
        try await a.server.updateSpace(renamed)
        try await eventually("Mac mini to take the rename") { b.spaces().first?.name == "web" && b.spaces().first?.sidebarHidden == true }
        #expect(b.spaces().first?.path == there.path)
    }

    @Test func aSpaceRemovedElsewhereGoesUnlessAThreadLivesInIt() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let one = Space(name: "orders-svc", path: a.mac.host.dir.appendingPathComponent("orders-svc").path)
        let two = Space(name: "payments-api", path: a.mac.host.dir.appendingPathComponent("payments-api").path)
        for space in [one, two] {
            try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true)
            try await a.server.addSpace(space)
            let folder = b.mac.host.dir.appendingPathComponent(URL(fileURLWithPath: space.path).lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            b.server.bindFleetSpace(space.id, to: folder.path)
        }
        try await eventually("Mac mini to have both") { b.spaces().count == 2 }

        // A thread on Mac mini in the second space: removing the space elsewhere cannot take it with it.
        let pane = LeafPane(cwd: two.path)
        let tab = ShepherdCore.Tab(spaceID: two.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "fix flaky test", spaceID: two.id, tabID: tab.id, paneID: pane.id)
        try await b.server.addAgent(agent, withTab: tab)

        try await a.server.deleteSpace(one.id)
        try await a.server.deleteSpace(two.id)
        try await eventually("Mac mini to drop the first") { b.spaces().map(\.id) == [two.id] }
        #expect(b.server.state.agents.contains { $0.id == agent.id }, "its thread is still there")
        // Gone again once the thread is: the wait is only for the thread.
        try await b.server.deleteAgent(agent.id)
        b.server.queue.sync { b.server.fleet?.syncEngine.localChanged() }
        try await eventually("Mac mini to drop the second") { b.spaces().isEmpty }
    }

    @Test func spacesThatAreReservedForThisMacNeverSync() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        _ = try await a.server.designsSpaceID()
        try await a.server.addSpace(Space(name: "real", path: a.mac.host.dir.path))
        try await eventually("the real space's op to reach Mac mini") { !b.server.fleetSyncUnits().filter { $0.hasPrefix("space:") }.isEmpty }
        #expect(b.server.fleetSyncUnits().filter { $0.hasPrefix("space:") }.count == 1, "only the user's space has a unit")
    }

    // MARK: Who gets them

    /// A phone's own token makes it a client, not a member: it is offered no sync, so none of these units reach it.
    @Test func aDeviceCannotReceiveAnyOfTheseUnits() async throws {
        let (a, b) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try a.mcp.update { $0.upsert(Self.postgres) }
        try await eventually("Mac mini to have postgres") { b.servers()["postgres"] != nil }

        let token = FleetProtocol.makeToken()
        let intro = FleetDeviceIntroduction(deviceID: UUID(), name: "iPhone", kind: .iphone, tokenHash: FleetProtocol.hash(token))
        let code = try #require(try await a.mac.local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: a.mac.port, code: code, device: intro)
        let phone = RemoteHostClient()
        defer { phone.disconnect() }
        _ = try await phone.connect(host: "127.0.0.1", port: a.mac.port, token: token, clientName: "iPhone")
        #expect(!phone.capabilities.contains(RemoteProtocol.fleetSyncCapability))
        await #expect(throws: RemoteHostClientError.self) { _ = try await phone.fleetSyncState(.hello(vector: FleetVersionVector())) }
        await #expect(throws: RemoteHostClientError.self) { _ = try await phone.fleetSyncState(.ops([])) }
    }
}
