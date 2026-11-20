import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// How a host keeps Shepherd's root instructions for pi: the two files the instructions
/// extension reads, and their history. The unit under test is the files.
@Suite("Instructions store", .timeLimit(.minutes(1)))
struct InstructionsStoreTests {
    static let start = Date(timeIntervalSince1970: 1_000)

    @Test func aHostWithNoFilesHasEmptyInstructionsAndNoHistory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = InstructionsStore(directory: dir.appendingPathComponent("instructions")).snapshot()
        #expect(snapshot.agents.isEmpty && snapshot.appendSystem.isEmpty)
        #expect(snapshot.history.isEmpty)
        #expect(snapshot.historyProblem == nil)
        #expect(snapshot.directory.hasSuffix("/instructions"))
    }

    @Test func aSaveWritesTheFilePiReadsAndSaysWhatChanged() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        let snapshot = try store.save(.appendSystem, content: "- Never force-push.\n", now: Self.start)
        #expect(try String(contentsOf: dir.appendingPathComponent("APPEND_SYSTEM.md"), encoding: .utf8) == "- Never force-push.\n")
        #expect(snapshot.appendSystem == "- Never force-push.\n")
        #expect(snapshot.history.map(\.summary) == ["Added “Never force-push.”"])
        #expect(snapshot.history.first?.file == .appendSystem)
        #expect(snapshot.history.first?.savedAt == 1_000)
        #expect(snapshot.history.first?.origin == nil)
    }

    @Test func savingWhatAFileAlreadyHoldsChangesNothing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        try store.save(.agents, content: "a\n", now: Self.start)
        let again = try store.save(.agents, content: "a\n", origin: "studio", sync: true, now: Self.start.addingTimeInterval(5))
        #expect(again.history.count == 1)
    }

    @Test func aCopyFromAnotherHostSaysWhereItCameFrom() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        let snapshot = try store.save(.agents, content: "# How I work\n", origin: "studio", sync: true, now: Self.start)
        #expect(snapshot.history.first?.summary == "Synced from studio")
        #expect(snapshot.history.first?.origin == "studio")
        let typed = try store.save(.agents, content: "# How I work\n- Tests first.\n", origin: "iPhone", now: Self.start)
        #expect(typed.history.first?.summary == "Added “Tests first.”")
        #expect(typed.history.first?.origin == "iPhone")
    }

    @Test func restoringPutsAnEarlierVersionBackAsANewSave() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        let first = try store.save(.agents, content: "first\n", now: Self.start)
        try store.save(.agents, content: "second\n", now: Self.start.addingTimeInterval(60))
        let restored = try store.restore(revisionID: try #require(first.history.first?.id), origin: "studio",
                                         now: Self.start.addingTimeInterval(120))
        #expect(restored.agents == "first\n")
        #expect(restored.history.count == 3)
        #expect(restored.history.first?.summary.hasPrefix("Restored the ") == true)
        #expect(restored.history.first?.origin == "studio")
        #expect(throws: InstructionsStore.StoreError.noSuchRevision) { try store.restore(revisionID: UUID()) }
    }

    @Test func eachFileKeepsItsNewestSaves() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        try store.save(.appendSystem, content: "kept\n", now: Self.start)
        for index in 0...InstructionsStore.limit {
            try store.save(.agents, content: "version \(index)\n", now: Self.start.addingTimeInterval(Double(index + 1)))
        }
        let history = store.snapshot().history
        #expect(history.filter { $0.file == .agents }.count == InstructionsStore.limit)
        #expect(history.filter { $0.file == .appendSystem }.count == 1)
        #expect(history.first?.summary == "Edited “version \(InstructionsStore.limit)”")
    }

    @Test(arguments: [
        (#"{"version":1,"revisions":["# as String?, "valid JSON"),
        (#"{"version":1,"revisions":"not an array"}"#, "decode Array"),
        (#"{"version":1,"revisions":[{"content":"missing required fields"}]}"#, "No value associated with key"),
        (nil, "permission"),
    ])
    func damagedHistoryRefusesChangesWithoutOverwritingFiles(malformed: String?, errorDetail: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        let first = try store.save(.agents, content: "earlier\n", now: Self.start)
        let revisionID = try #require(first.history.first?.id)
        try store.save(.agents, content: "current\n", now: Self.start)
        try store.save(.appendSystem, content: "rules\n", now: Self.start)
        let url = dir.appendingPathComponent("history.json")
        if let malformed { try Data(malformed.utf8).write(to: url) }
        let original = try Data(contentsOf: url)
        defer { if malformed == nil { _ = chmod(url.path, 0o600) } }
        if malformed == nil {
            try #require(chmod(url.path, 0o000) == 0)
            try #require(throws: CocoaError.self) { try Data(contentsOf: url) }
        }

        let snapshot = store.snapshot()
        #expect(snapshot.agents == "current\n")
        #expect(snapshot.appendSystem == "rules\n")
        let message = try #require(snapshot.historyProblem)
        #expect(message.contains(url.path))
        #expect(message.contains("restore this file from a backup or repair it"))
        #expect(message.contains(errorDetail))
        let repair = InstructionsStore.StoreError.damagedHistory(message)
        #expect(throws: repair) { try store.save(.agents, content: "manual change\n", now: Self.start) }
        #expect(throws: repair) { try store.save(.appendSystem, content: "synced change\n", sync: true, now: Self.start) }
        #expect(throws: repair) { try store.restore(revisionID: revisionID, now: Self.start) }

        if malformed == nil { try #require(chmod(url.path, 0o600) == 0) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try Data(contentsOf: dir.appendingPathComponent("AGENTS.md")) == Data("current\n".utf8))
        #expect(try Data(contentsOf: dir.appendingPathComponent("APPEND_SYSTEM.md")) == Data("rules\n".utf8))
        if malformed == nil {
            #expect(store.snapshot().historyProblem == nil)
            let saved = try store.save(.agents, content: "repaired\n", now: Self.start)
            #expect(saved.history.count == 4)
        }
    }

    @Test(arguments: [false, true])
    func bothHistoryShapesReadAndWriteBackAsLegacyJSON(enveloped: Bool) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstructionsStore(directory: dir)
        let url = dir.appendingPathComponent("history.json")
        let old = #"{"id":"00000000-0000-4000-8000-000000000001","file":"AGENTS.md","savedAt":500,"summary":"Initial instructions","content":"earlier\n"}"#
        let legacy = #"{"version":1,"revisions":[\#(old)]}"#
        let input = enveloped ? #"{"version":1,"value":\#(legacy)}"# : legacy
        try Data(input.utf8).write(to: url)

        #expect(store.snapshot().history.first?.summary == "Initial instructions")
        let saved = try store.save(.agents, content: "synced\n", origin: "studio", sync: true, now: Self.start)
        let newID = try #require(saved.history.first?.id)
        let expected = Data(#"""
            {"version":1,"revisions":[
                {"id":"\#(newID.uuidString)","file":"AGENTS.md","savedAt":1000,"summary":"Synced from studio","origin":"studio","content":"synced\n"},
                \#(old)
            ]}
            """#.utf8)
        func canonicalJSON(_ data: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
        }
        #expect(try canonicalJSON(Data(contentsOf: url)) == canonicalJSON(expected))
        #expect(store.snapshot() == saved)
    }

    /// Another process (a second window, a test) sees each save whole.
    @Test func aSecondStoreOnTheSameDirectoryReadsTheSameFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try InstructionsStore(directory: dir).save(.agents, content: "shared\n", now: Self.start)
        let other = InstructionsStore(directory: dir).snapshot()
        #expect(other.agents == "shared\n")
        #expect(other.history.count == 1)
    }
}
