import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Subagent definitions", .integrationTimeLimit)
struct SubagentDefinitionsTests {
    @Test func createEditDeleteAndRestoreUseOnlyOwnedFilesAndKeepCustomDefinitions() throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        let initial = try files.snapshot()
        #expect(initial.count == 4)
        #expect(initial.allSatisfy { $0.error == nil && $0.isDefault })
        let reviewer = try files.open("reviewer.md")
        let changed = reviewer.text.replacingOccurrences(of: "Review for correctness", with: "Review the assigned patch for correctness")
        try files.save("reviewer.md", text: changed, expected: reviewer.fingerprint)
        #expect(try files.open("reviewer.md").text == changed)
        let custom = "---\nname: custom\ndescription: Real custom description\ntools: [read]\ndefaultContext: fork\n---\nDo the assigned work.\n"
        try files.save("custom.md", text: custom, expected: nil)
        let parsed = try #require(files.snapshot().first { $0.name == "custom" })
        #expect(parsed.capability == "read-only · fork")
        let scout = try files.open("scout.md")
        try files.delete("scout.md", expected: scout.fingerprint)
        #expect(try files.snapshot().count == 4)
        let freshStore = try SubagentFixtures.store(in: scratch.dir)
        #expect(try freshStore.snapshot().allSatisfy { $0.file != "scout.md" }, "a new store must not resurrect a deleted default")
        let current = try files.snapshot()
        let expected = Dictionary(uniqueKeysWithValues: current.filter(\.isDefault).compactMap { d in d.fingerprint.map { (d.file, $0) } })
        try files.restore(expected: expected)
        #expect(try files.snapshot().count == 5)
        #expect(try files.open("reviewer.md").text == reviewer.text)
        #expect(try files.open("custom.md").text == custom)
    }

    @Test func unsupportedFieldsUnsafePathsAndStaleSnapshotsNeverOverwriteFiles() throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        _ = try files.snapshot()
        let reviewer = try files.open("reviewer.md")
        let invalid = reviewer.text.replacingOccurrences(of: "---\n\n", with: "runner: unsupported\n---\n\n")
        #expect(throws: (any Error).self) { try files.save("reviewer.md", text: invalid, expected: reviewer.fingerprint) }
        #expect(try files.open("reviewer.md").text == reviewer.text)
        try Data(invalid.utf8).write(to: files.directory.appendingPathComponent("reviewer.md"))
        let row = try #require(files.snapshot().first { $0.file == "reviewer.md" })
        #expect(row.error == "Unsupported agent fields: runner")
        #expect(throws: (any Error).self) { try files.save("reviewer.md", text: reviewer.text, expected: reviewer.fingerprint) }
        #expect(throws: (any Error).self) { try files.delete("reviewer.md", expected: reviewer.fingerprint) }
        #expect(try files.open("reviewer.md").text == invalid)
        #expect(throws: SubagentDefinitionsStore.Failure.self) {
            try files.save("duplicate.md", text: "---\nname: scout\ndescription: An accidental duplicate.\n---\nAn accidental duplicate.\n", expected: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("duplicate.md").path))
        #expect(throws: SubagentDefinitionsStore.Failure.self) {
            try files.save("oversized.md", text: String(repeating: "x", count: 128 * 1024 + 1), expected: nil)
        }
        for file in ["skills/helper.md", "node_modules/helper.md", "nested/skills/helper.md"] {
            #expect(!SubagentDefinitionsStore.acceptsFilename(file))
            #expect(throws: (any Error).self) { try files.save(file, text: "---\nname: helper\ndescription: A bounded helper.\n---\nRead a bounded task.\n", expected: nil) }
        }
        let outside = scratch.dir.appendingPathComponent("outside.md")
        try Data(reviewer.text.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: files.directory.appendingPathComponent("unsafe.md"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try files.open("unsafe.md") }
        #expect(throws: (any Error).self) { try files.save("unsafe.md", text: reviewer.text, expected: nil) }
        #expect(throws: (any Error).self) { try files.save("../outside.md", text: reviewer.text, expected: nil) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == reviewer.text)
        #expect(try files.snapshot().first { $0.file == "unsafe.md" }?.error != nil)
        let snapshot = try files.snapshot()
        let expected = Dictionary(uniqueKeysWithValues: snapshot.filter(\.isDefault).compactMap { d in d.fingerprint.map { (d.file, $0) } })
        try Data("Changed elsewhere".utf8).write(to: files.directory.appendingPathComponent("worker.md"))
        #expect(throws: (any Error).self) { try files.restore(expected: expected) }
        #expect(try files.open("reviewer.md").text == invalid, "preflight prevents partial restore on a known conflict")
    }

    @Test func creationAndRestorationRefuseToExceedTheCatalogFileLimit() throws {
        let scratch = try ScratchServer(); defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        for i in 0..<508 {
            try "---\nname: custom-\(i)\ndescription: A bounded helper.\n---\nRead a bounded task.\n".write(to: files.directory.appendingPathComponent("custom-\(i).md"), atomically: true, encoding: .utf8)
        }
        #expect(try files.snapshot().count == 512)
        #expect(throws: (any Error).self) { try files.save("extra.md", text: "---\nname: extra\ndescription: A bounded helper.\n---\nRead a bounded task.\n", expected: nil) }
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("extra.md").path))
        let custom = try files.open("custom-0.md")
        try files.save(custom.file, text: custom.text + "Keep this definition.\n", expected: custom.fingerprint)
        let scout = try files.open("scout.md")
        try files.delete(scout.file, expected: scout.fingerprint)
        try files.save("extra.md", text: "---\nname: extra\ndescription: A bounded helper.\n---\nRead a bounded task.\n", expected: nil)
        let before = try files.snapshot()
        let expected = Dictionary(uniqueKeysWithValues: before.filter(\.isDefault).compactMap { d in d.fingerprint.map { (d.file, $0) } })
        #expect(throws: (any Error).self) { try files.restore(expected: expected) }
        #expect(try files.snapshot() == before, "a refused restore changes no definition")
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("scout.md").path))
    }

    @Test func newNestedFilesCannotExceedTheFolderLimit() throws {
        let scratch = try ScratchServer(); defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        for i in 0..<511 { try FileManager.default.createDirectory(at: files.directory.appendingPathComponent("folder-\(i)"), withIntermediateDirectories: false) }
        #expect(try files.snapshot().count == 4)
        #expect(throws: (any Error).self) { try files.save("extra/helper.md", text: "---\nname: helper\ndescription: A bounded helper.\n---\nRead a bounded task.\n", expected: nil) }
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("extra").path))
        try files.save("folder-0/helper.md", text: "---\nname: helper\ndescription: A bounded helper.\n---\nRead a bounded task.\n", expected: nil)
        #expect(try files.snapshot().count == 5)
    }

    @Test func restoringRefusesADefaultNameUsedByACustomDefinitionBeforeWriting() throws {
        let scratch = try ScratchServer(); defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        let scout = try files.open("scout.md")
        try files.delete(scout.file, expected: scout.fingerprint)
        try files.save("custom-scout.md", text: "---\nname: scout\ndescription: A bounded helper.\n---\nKeep this custom scout.\n", expected: nil)
        let before = try files.snapshot()
        let expected = Dictionary(uniqueKeysWithValues: before.filter(\.isDefault).compactMap { d in d.fingerprint.map { (d.file, $0) } })
        #expect(throws: (any Error).self) { try files.restore(expected: expected) }
        #expect(try files.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("scout.md").path))
        #expect(before.first { $0.file == "custom-scout.md" }?.error == nil)
    }

    @Test func concurrentFirstUseKeepsOneSetOfDefaultsWithoutConflicting() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let first = try SubagentFixtures.store(in: scratch.dir, seed: false)
        let second = try SubagentFixtures.store(in: scratch.dir, seed: false)
        async let a = Task.detached { try first.snapshot() }.value
        async let b = Task.detached { try second.snapshot() }.value
        let results = try await [a, b]
        #expect(results.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.error == nil } })
        #expect(try first.snapshot().count == 4)
    }

    @Test func restoringRecoversInvalidUtf8AndOversizedRegularDefaultsWithoutReadingUnboundedData() throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir)
        try Data([0xff, 0xfe]).write(to: files.directory.appendingPathComponent("scout.md"))
        try Data(repeating: 0x61, count: 128 * 1024 + 1).write(to: files.directory.appendingPathComponent("worker.md"))
        let broken = try files.snapshot()
        let damaged = broken.filter { ["scout.md", "worker.md"].contains($0.file) }
        #expect(damaged.count == 2 && damaged.allSatisfy { $0.error != nil && $0.fingerprint != nil })
        let expected = Dictionary(uniqueKeysWithValues: broken.filter(\.isDefault).compactMap { row in row.fingerprint.map { (row.file, $0) } })
        try files.restore(expected: expected)
        #expect(try files.snapshot().allSatisfy { $0.error == nil })
    }
}
