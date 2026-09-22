import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions

@Suite("State store")
struct StateStoreTests {
    private func validState() -> ShepherdState {
        let space = Space(name: "alpha", path: "/tmp/alpha")
        let agentID = AgentID()
        let pane = LeafPane(cwd: "/tmp/alpha", agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let expected = validState()

        let store = StateStore(url: url)
        try store.update { $0 = expected }

        let reloaded = StateStore(url: url)
        #expect(reloaded.state == store.state)
        #expect(reloaded.state == expected)
    }

    @Test func missingStateStartsEmptyWithoutQuarantine() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        #expect(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func corruptStateIsQuarantinedAndCanBeReplaced() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let original = Data("not json{".utf8)
        try original.write(to: url)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == original)

        let space = Space(name: "recovered", path: "/tmp/recovered")
        try store.update { $0.spaces = [space] }
        #expect(StateStore(url: url).state.spaces == [space])
        #expect(FileManager.default.fileExists(atPath: backups[0].path))
    }

    @Test func structurallyInvalidStateIsQuarantined() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        var invalid = validState()
        invalid.agents[0].tabID = TabID()
        let data = try JSONEncoder().encode(invalid)
        try data.write(to: url)

        let store = StateStore(url: url)
        #expect(store.state == ShepherdState())
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == data)
    }

    @Test func rejectedCandidateDoesNotChangeMemoryOrDisk() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let expected = validState()
        let store = StateStore(url: url)
        try store.update { $0 = expected }
        let originalData = try Data(contentsOf: url)

        #expect(throws: ShepherdStateValidationError.self) {
            try store.update { state in
                state.tabs[0].spaceID = SpaceID()
            }
        }
        #expect(store.state == expected)
        #expect(try Data(contentsOf: url) == originalData)

        let laterSpace = Space(name: "later", path: "/tmp/later")
        try store.update { $0.spaces.append(laterSpace) }
        #expect(store.state.spaces == [expected.spaces[0], laterSpace])
        #expect(StateStore(url: url).state == store.state)
    }
}
