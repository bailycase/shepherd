import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// How a host keeps Shepherd's root instructions for pi: the two files the instructions
/// extension reads, and their history. The unit under test is the files.
@Suite("Instructions store")
struct InstructionsStoreTests {
    static let start = Date(timeIntervalSince1970: 1_000)

    @Test func aHostWithNoFilesHasEmptyInstructionsAndNoHistory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = InstructionsStore(directory: dir.appendingPathComponent("instructions")).snapshot()
        #expect(snapshot.agents.isEmpty && snapshot.appendSystem.isEmpty)
        #expect(snapshot.history.isEmpty)
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
