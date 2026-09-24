import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

/// state.json: atomic, validated writes; invalid files are moved aside rather than overwritten.
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

    private func quarantined(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.json.corrupt-") }
    }

    @Test func aWrittenStateReloadsIdentically() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let expected = Self.validState()

        try StateStore(url: url).update { $0 = expected }
        #expect(StateStore(url: url).state == expected)
    }

    @Test func aMissingFileStartsEmptyAndQuarantinesNothing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        #expect(store.state == ShepherdState())
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test(arguments: ["undecodable", "structurally invalid"])
    func anInvalidFileIsQuarantinedByteForByteAndTheStoreStartsEmpty(kind: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        var invalid = Self.validState()
        invalid.agents[0].tabID = TabID()
        let original = kind == "undecodable" ? Data("not json{".utf8) : try JSONEncoder().encode(invalid)
        try original.write(to: url)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try quarantined(in: dir)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == original)
    }

    @Test func aQuarantinedStoreAcceptsNewWritesAndKeepsTheEvidence() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{".utf8).write(to: url)

        let store = StateStore(url: url)
        let space = Space(name: "recovered", path: "/tmp/recovered")
        try store.update { $0.spaces = [space] }
        #expect(StateStore(url: url).state.spaces == [space])
        #expect(try quarantined(in: dir).count == 1)
    }

    @Test func whenQuarantineFailsEveryWriteIsRefusedSoEvidenceSurvives() throws {
        let dir = try makeTempDirectory()
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("state.json")
        let original = Data("not json{".utf8)
        try original.write(to: url)
        // A read-only directory makes the move-aside fail.
        #expect(chmod(dir.path, 0o500) == 0)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        #expect(throws: StateStoreError.self) {
            try store.update { $0.spaces = [Space(name: "x", path: "/tmp/x")] }
        }
        chmod(dir.path, 0o700)
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
    @Test func aTerminalEraFileLoadsWithoutQuarantine() throws {
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
        #expect(try quarantined(in: dir).isEmpty)
        #expect(loaded.agents.map(\.id) == [agent.id])
        #expect(loaded.agents.first?.piSessionID == "old-session")
    }
}
