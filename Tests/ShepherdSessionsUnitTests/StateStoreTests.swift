import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// state.json: atomic, validated writes.
@Suite("State store")
struct StateStoreTests {
    private static func validState() -> ShepherdState {
        let space = Space(name: "alpha", path: "/tmp/alpha")
        let agentID = AgentID()
        let pane = LeafPane(cwd: "/tmp/alpha", agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }

    @Test func aWrittenStateReloadsIdentically() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let expected = Self.validState()

        try StateStore(url: url).update { $0 = expected }
        #expect(StateStore(url: url).state == expected)
    }

    @Test func aMissingFileStartsEmptyAndWritesNothing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        #expect(store.state == ShepherdState())
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anUnexplainedDanglingReferenceBlocksWrites() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        var invalid = Self.validState()
        invalid.agents[0].tabID = TabID()
        let original = try JSONEncoder().encode(invalid)
        try original.write(to: url)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        #expect(throws: StateStoreError.self) { try store.update { $0 = ShepherdState() } }
        #expect(try Data(contentsOf: url) == original)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let copy = try #require(files.first { $0.lastPathComponent.hasPrefix("state.json.recovery-") })
        #expect(try Data(contentsOf: copy) == original)
    }

    @Test func repeatedLoadsReuseOnlyByteIdenticalRecoveryCopies() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        func copies() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state.json.recovery-") }
        }
        let first = Data(#"{"spaces":["#.utf8)
        try first.write(to: url)
        let store = StateStore(url: url)
        let copy = try #require(copies().first)
        store.load()
        #expect(try copies() == [copy])

        let second = Data(#"{"spaces":]"#.utf8)
        try second.write(to: url)
        store.load()
        let both = try copies()
        #expect(both.count == 2)
        #expect(try Set(both.map { try Data(contentsOf: $0) }) == [first, second])
    }

    @Test func whenTheRecoveryCopyFailsEveryWriteIsRefused() throws {
        let dir = try makeTempDirectory()
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("state.json")
        var originalFile = Self.validState()
        // A valid second workspace survives dropping the corrupted record.
        originalFile.spaces.append(Space(name: "Keep", path: "/tmp/keep"))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalFile)) as? [String: Any])
        var agents = try #require(json["agents"] as? [[String: Any]])
        agents[0]["name"] = 123
        json["agents"] = agents
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        // This would be recoverable if the file's directory allowed the copy.
        #expect(chmod(dir.path, 0o500) == 0)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        chmod(dir.path, 0o700)
        #expect(throws: StateStoreError.self) {
            try store.update { $0.spaces = [Space(name: "x", path: "/tmp/x")] }
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aRejectedCandidateChangesNeitherMemoryNorDisk() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let expected = Self.validState()
        let store = StateStore(url: url)
        try store.update { $0 = expected }
        let onDisk = try Data(contentsOf: url)

        #expect(throws: ShepherdStateValidationError.self) {
            try store.update { $0.tabs[0].spaceID = SpaceID() }
        }
        #expect(store.state == expected)
        #expect(try Data(contentsOf: url) == onDisk)

        let later = Space(name: "later", path: "/tmp/later")
        try store.update { $0.spaces.append(later) }
        #expect(StateStore(url: url).state.spaces == expected.spaces + [later])
    }

    @Test func aFailedWritePublishesNothingAndALaterWriteCanSucceed() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        let original = Self.validState()
        try store.update { $0 = original }
        let bytes = try Data(contentsOf: url)
        // A file where a directory is needed fails even when tests run with elevated privileges.
        let backup = dir.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: url.appendingPathComponent("sentinel"))
        let later = Space(name: "later", path: "/tmp/later")
        #expect(throws: (any Error).self) { try store.update { $0.spaces.append(later) } }
        #expect(store.state == original)
        #expect(store.committed == original)
        #expect(try Data(contentsOf: backup) == bytes)
        #expect(try Data(contentsOf: url.appendingPathComponent("sentinel")) == Data("keep".utf8))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        try store.update { $0.spaces.append(later) }
        #expect(StateStore(url: url).state.spaces == original.spaces + [later])
    }

    /// `committed`, which any thread reads, is the store's state after a load and an update, and a
    /// rejected update leaves it as it was.
    @Test func theCommittedCopyFollowsLoadsAndUpdatesButNotRejections() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        #expect(StateStore(url: url).committed == ShepherdState())
        let expected = Self.validState()
        try StateStore(url: url).update { $0 = expected }

        let store = StateStore(url: url)
        #expect(store.committed == expected)
        let later = Space(name: "later", path: "/tmp/later")
        try store.update { $0.spaces.append(later) }
        #expect(store.committed == store.state)
        #expect(store.committed.spaces == expected.spaces + [later])

        let before = store.committed
        #expect(throws: ShepherdStateValidationError.self) {
            try store.update { $0.tabs[0].spaceID = SpaceID() }
        }
        #expect(store.committed == before)
        #expect(store.committed == store.state)
    }

    /// Terminal-era files carry a per-agent `runtime` key; they load unchanged and relaunch over RPC.
    @Test func aTerminalEraFileLoadsWithoutRepair() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let state = Self.validState()
        let agent = state.agents[0]
        let json = """
        {"spaces":[{"id":"\(state.spaces[0].id.rawValue)","name":"alpha","path":"/tmp/alpha"}],
         "tabs":[{"id":"\(state.tabs[0].id.rawValue)","spaceID":"\(state.spaces[0].id.rawValue)","order":0,
                  "layout":{"type":"leaf","pane":{"id":"\(agent.paneID!.rawValue)","cwd":"/tmp/alpha","agentID":"\(agent.id.rawValue)"}}}],
         "agents":[{"id":"\(agent.id.rawValue)","name":"pi-1","spaceID":"\(state.spaces[0].id.rawValue)",
                    "tabID":"\(state.tabs[0].id.rawValue)","paneID":"\(agent.paneID!.rawValue)","status":"working",
                    "runtime":"terminal","piSessionID":"old-session"}]}
        """
        try Data(json.utf8).write(to: url)

        let loaded = StateStore(url: url).state
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
        #expect(loaded.agents.map(\.id) == [agent.id])
        #expect(loaded.agents.first?.piSessionID == "old-session")
    }

    /// Files and hosts from the token and cost rollup (#752) carry a per-agent `spend` key; it is ignored, nothing else is lost,
    /// and it is not written back.
    @Test func anAgentSpendKeyFromTheRemovedRollupIsIgnored() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let state = Self.validState()
        let agent = state.agents[0]
        let json = """
        {"spaces":[{"id":"\(state.spaces[0].id.rawValue)","name":"alpha","path":"/tmp/alpha"}],
         "tabs":[{"id":"\(state.tabs[0].id.rawValue)","spaceID":"\(state.spaces[0].id.rawValue)","order":0,
                  "layout":{"type":"leaf","pane":{"id":"\(agent.paneID!.rawValue)","cwd":"/tmp/alpha","agentID":"\(agent.id.rawValue)"}}}],
         "agents":[{"id":"\(agent.id.rawValue)","name":"pi-1","spaceID":"\(state.spaces[0].id.rawValue)",
                    "tabID":"\(state.tabs[0].id.rawValue)","paneID":"\(agent.paneID!.rawValue)","status":"working",
                    "piSessionID":"old-session","worktreeBranch":"feat/x",
                    "spend":{"tokens":3100000,"cost":4.2,"day":"2026-05-11","zone":"UTC","sessionID":"s1",
                             "today":[{"model":"acme/small","tokens":1000,"cost":0.5}]}}]}
        """
        try Data(json.utf8).write(to: url)

        let loaded = StateStore(url: url).state
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"], "loads without quarantine or repair")
        #expect(loaded.agents.map(\.id) == [agent.id])
        #expect(loaded.agents.first?.piSessionID == "old-session")
        #expect(loaded.agents.first?.worktreeBranch == "feat/x")
        let written = try JSONEncoder().encode(loaded.agents[0])
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["spend"] == nil)
        #expect(object["worktreeBranch"] as? String == "feat/x")
    }
}
