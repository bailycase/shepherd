import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

@Suite("C-RECOVER", .integrationTimeLimit)
struct StateRecoveryTests {
    @Test(arguments: ["spaces", "tabs", "agents"])
    func recoversIndependentRecordsAndKeepsTheRejectedGraph(damaged: String) throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let keep = Fixture.space("Keep"), drop = Fixture.space("Drop")
        let good = Fixture.agent(in: keep), bad = Fixture.agent(in: drop)
        let automation = Automation(name: "Drop with agent", prompt: "Check", cwd: drop.path, agentID: bad.agent.id)
        let input = ShepherdState(spaces: [keep, drop], tabs: [good.tab, bad.tab], agents: [good.agent, bad.agent],
                                  automations: [automation])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        var records = try #require(json[damaged] as? [[String: Any]])
        records[1][damaged == "tabs" ? "layout" : "name"] = 123
        records[1]["unknownEvidence"] = "keep the raw record"
        json[damaged] = records
        let original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try original.write(to: url)

        let preview = StateStore(url: url, readOnly: true)
        #expect(throws: StateStoreError.self) { try preview.update { $0.spaces.append(keep) } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
        #expect(try Data(contentsOf: url) == original)

        let store = StateStore(url: url)
        try store.state.validate()
        #expect(store.state.spaces == (damaged == "spaces" ? [keep] : [keep, drop]))
        #expect(store.state.tabs == [good.tab])
        #expect(store.state.agents == [good.agent])
        #expect(store.state.automations.isEmpty)
        #expect(try Data(contentsOf: url) == original)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let copy = try #require(files.first { $0.lastPathComponent.hasPrefix("state.json.recovery-") })
        let rejected = try #require(files.first { $0.lastPathComponent.hasPrefix("state.json.rejected-") })
        #expect(try Data(contentsOf: copy) == original)
        let rejectedJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rejected)) as? [String: [[String: Any]]])
        var expected: [String: [[String: Any]]] = [:]
        for key in ["tabs", "agents", "automations"] + (damaged == "spaces" ? ["spaces"] : []) {
            expected[key] = [try #require((json[key] as? [[String: Any]])?.last)]
        }
        #expect(try JSONSerialization.data(withJSONObject: rejectedJSON, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
        #expect(StateStore(url: url).state == store.state)
        #expect(Set(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) == Set(files))
        try store.update { $0.spaces[0].name = "Renamed" }
        #expect(StateStore(url: url).state == store.state)
        #expect(try Data(contentsOf: copy) == original)
    }

    @Test func startupSettlesRecoveredAgentsWithoutRewritingTheOriginal() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let space = Fixture.space(), good = Fixture.agent(in: space, status: .working), bad = Fixture.agent(in: space)
        let input = Fixture.workspace([good, bad], space: space)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        var agents = try #require(json["agents"] as? [[String: Any]])
        agents[1]["name"] = 123
        json["agents"] = agents
        let original = try JSONSerialization.data(withJSONObject: ["version": 1, "value": json])
        try original.write(to: url)

        let host = try ScratchServer(dir: dir)
        defer { host.stop() }
        #expect(host.server.state.agents.map(\.id) == [good.agent.id])
        #expect(host.server.state.agents.first?.status == .idle)
        #expect(try Data(contentsOf: url) == original)
        try await host.server.renameAgent(good.agent.id, to: "Saved")
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(rewritten["version"] == nil && rewritten["value"] == nil)
        #expect(try host.persisted().agents.first?.name == "Saved")
    }

    @Test func unreadableStateIsNeverMovedOrOverwritten() throws {
        let dir = try makeScratchDirectory()
        let url = dir.appendingPathComponent("state.json")
        defer {
            chmod(url.path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        let original = Data(#"{"spaces":[],"tabs":[],"agents":[]}"#.utf8)
        try original.write(to: url)
        try #require(chmod(url.path, 0o000) == 0)
        try #require((try? Data(contentsOf: url)) == nil)
        let store = StateStore(url: url)
        chmod(url.path, 0o600) // The refusal must hold even after the file becomes writable again.
        #expect(throws: StateStoreError.self) { try store.update { $0.spaces.append(Fixture.space()) } }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
    }

    @Test(arguments: [true, false])
    func stateFetchPreservesTheRepairRefusal(local: Bool) async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"spaces":[],"tabs":["#.utf8).write(to: dir.appendingPathComponent("state.json"))
        let host = try ScratchServer(dir: dir)
        defer { host.stop() }
        let client: RemoteHostClient
        let port: UInt16
        let token: String
        if local {
            let socket = dir.appendingPathComponent("host.sock").path
            try await host.server.listenLocal(path: socket)
            client = RemoteHostClient(localSocket: socket)
            port = 0
            token = ""
        } else {
            let tokenURL = dir.appendingPathComponent("scratch-token")
            port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            client = RemoteHostClient()
        }
        defer { client.disconnect() }
        do {
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "recovery test")
            Issue.record("Expected a repair refusal")
        } catch let error as RemoteHostClientError {
            guard case .rejected(let code, let message) = error else {
                Issue.record("Expected a repair refusal, got \(error)")
                return
            }
            #expect(code == "workspace_repair_required")
            #expect(message.contains("state.json"))
            let failure = RemoteHostFailure(error)
            #expect(failure.headline == "Repair needed")
            #expect(failure.message(host: "acme-mac").contains("state.json on acme-mac needs repair"))
            #expect(!failure.retries)
        }
    }

    @Test func truncatedStateRefusesOrdinaryAndProjectWritesBeforeStaging() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        host.server.setProjectsEnabled(true)
        let initial = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: initial, name: "Existing", goal: ""))
        host.stop(keepFiles: true)
        let original = Data(#"{"spaces":[],"tabs":["#.utf8)
        try original.write(to: host.stateURL)
        let restarted = try ScratchServer(dir: host.dir)
        defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        let before = restarted.server.state
        let prepared = Locked(false)
        try await restarted.server.enqueue { restarted.server.stateWritePrepared = { prepared.withValue { $0 = true } } }
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: host.dir, includingPropertiesForKeys: nil)
        let copy = try #require(files.first { $0.lastPathComponent.hasPrefix("state.json.recovery-") })
        #expect(try Data(contentsOf: copy) == original)
        func history() throws -> [String: Data] {
            let files = try fm.contentsOfDirectory(at: host.dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("project-history") }
            return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let historyBefore = try history()
        #expect(!historyBefore.isEmpty)
        let tokenURL = host.dir.appendingPathComponent("scratch-token")
        let port = try restarted.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let remote = try RawRemote(port: port)
        defer { remote.closeConnection() }
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await remote.hello(token: token)
        try remote.send(.stateFetch(id: 2))
        let stateReply = try await remote.next()
        if case .error(2, "workspace_repair_required", let message) = stateReply {
            #expect(message.contains("state.json"))
        } else {
            Issue.record("Expected a repair error, got \(stateReply)")
        }
        let root = host.dir.appendingPathComponent("logical-projects")
        let directories = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let space = Fixture.space()
        await #expect(throws: (any Error).self) {
            try await restarted.server.mutateStateOffQueue { $0.spaces.append(space) }
        }
        #expect(!prepared.current)
        #expect(restarted.server.state == before)
        #expect(try Data(contentsOf: host.stateURL) == original)
        #expect(try history() == historyBefore)
        await #expect(throws: (any Error).self) {
            _ = try await restarted.server.logicalProjects(.create(projectID: ProjectID(), name: "Refused", goal: ""))
        }
        await #expect(throws: StateStoreError.self) {
            try await restarted.server.projectHistoryRead { _ in }
        }
        #expect(restarted.server.state == before)
        #expect(try Data(contentsOf: host.stateURL) == original)
        #expect(try history() == historyBefore)
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == directories)
        #expect(try fm.contentsOfDirectory(atPath: host.dir.path).allSatisfy { !$0.hasPrefix(".logical-project-state-") })
    }
}
