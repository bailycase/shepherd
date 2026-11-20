import Foundation
import ShepherdCore
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

struct TurnStoreTests {
    private static let agent = AgentID(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let legacy = """
        {"00000000-0000-4000-8000-000000000001":[{"cwd":"/tmp/acme","startTree":"start","endTree":"end",
        "turn":{"id":"00000000-0000-4000-8000-000000000002","startedAt":1000,"state":"ready",
        "fileCount":1,"added":1,"removed":0,"files":[],"canUndo":false,"canRedo":false},
        "recovery":{"redo":false,"completed":[],"inFlight":"README.md"}}]}
        """

    @Test(arguments: ["truncated", "empty", "wrong-type", "bad-element", "unreadable"])
    func damageRefusesWritesAndRepairRestoresHistory(kind: String) throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turns.json")
        let good = Data(Self.legacy.utf8)
        let damaged: Data = switch kind {
        case "truncated": Data(good.dropLast())
        case "empty": Data()
        case "wrong-type": Data("[]".utf8)
        case "bad-element": Data((Self.legacy.dropLast(2) + ",{}]}").utf8)
        default: good
        }
        try damaged.write(to: url)
        let unreadable = kind == "unreadable"
        if unreadable {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            #expect(throws: (any Error).self) { try Data(contentsOf: url) }
        }
        let store = TurnStore(url: url)
        #expect(store.all(Self.agent).isEmpty)
        store.remove(Self.agent)
        store.prune(keeping: [])
        store.update(Self.agent) { _ in Issue.record("A damaged store ran an asynchronous mutation") }
        store.flush()
        #expect(throws: (any Error).self) {
            try store.updateAndCheckpoint(Self.agent) { _ in Issue.record("A damaged store staged a checkpoint") }
        }
        if unreadable {
            #expect(throws: (any Error).self) { try Data(contentsOf: url) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        #expect(try Data(contentsOf: url) == damaged)

        if !unreadable {
            try FileManager.default.removeItem(at: url)
            #expect(throws: (any Error).self) { try store.updateAndCheckpoint(Self.agent) { _ in } }
            #expect(!FileManager.default.fileExists(atPath: url.path), "deletion is not a repair")
            try good.write(to: url, options: .atomic)
        }
        #expect(store.latest(Self.agent)?.recovery?.inFlight == "README.md")
        try #require(store.published(Self.agent).last?.canUndo == true)
        try store.updateAndCheckpoint(Self.agent) { $0[0].recovery = nil }
        #expect(TurnStore(url: url).latest(Self.agent)?.turn.state == .ready)
    }

    @Test func envelopeLoadsAndCheckpointsWriteTheLegacyShape() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turns.json")
        try Data("{\"version\":1,\"value\":\(Self.legacy)}".utf8).write(to: url)
        let store = TurnStore(url: url)
        let records = store.all(Self.agent)
        try #require(records.last?.recovery?.inFlight == "README.md")
        try store.updateAndCheckpoint(Self.agent) { _ in }
        let persisted = try JSONDecoder().decode([String: [TurnRecord]].self, from: Data(contentsOf: url))
        #expect(persisted == [Self.agent.rawValue: records])
    }

    @Test func queuedSaveRechecksDiskBeforeReplacingIt() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turns.json")
        let good = Data(Self.legacy.utf8)
        let damaged = Data(good.dropLast())
        try good.write(to: url)
        let store = TurnStore(url: url)
        // Damage lands after staging but before the atomic replacement.
        store.beforeWrite = { _ in try damaged.write(to: url, options: .atomic) }
        store.update(Self.agent) { $0.removeAll() }
        store.flush()
        #expect(try Data(contentsOf: url) == damaged)
        try good.write(to: url, options: .atomic)
        #expect(store.latest(Self.agent)?.recovery?.inFlight == "README.md")
    }
}
