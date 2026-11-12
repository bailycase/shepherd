import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The pieces the skills and extensions units are made of: which files of a tree are units, what
/// a write may touch, how a unit that depends on another waits for it, and the unit names.
@Suite("Fleet content units")
struct FleetContentUnitTests {
    @Test func aTreesUnitsAreItsRegularFilesAndNeverALinkOrNoise() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("pdf")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "a".write(to: tree.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "#!/bin/sh".write(to: tree.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try "x".write(to: tree.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link.txt"), withDestinationURL: dir.appendingPathComponent("outside.txt"))

        let files = try #require(FleetFileTree.files(under: tree.path, limits: .init(files: 10, bytes: 100)))
        #expect(files.map(\.relative) == ["SKILL.md", "scripts/run.sh"])
        let followed = try #require(FleetFileTree.files(under: tree.path, followingFileLinks: true, limits: .init(files: 10, bytes: 100)))
        #expect(followed.map(\.relative) == ["SKILL.md", "link.txt", "scripts/run.sh"], "a copy of someone's own folder reads through a link to a file")
        #expect(FleetFileTree.files(under: tree.path, limits: .init(files: 1, bytes: 100)) == nil, "over the file limit: not synced")
        #expect(FleetFileTree.files(under: tree.path, limits: .init(files: 10, bytes: 3)) == nil, "over the size limit: not synced")
    }

    @Test func aWriteStaysInsideItsFolderAndKeepsAScriptRunnable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("skill")
        let outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FleetFileTree.write(Data("#!/bin/sh\n".utf8), to: "scripts/run.sh", under: folder)
        #expect(FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("scripts/run.sh").path))
        try FleetFileTree.write(Data("text".utf8), to: "notes.md", under: folder)
        #expect(!FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("notes.md").path))

        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("door"), withDestinationURL: outside)
        #expect(throws: FleetUnitRefused.self) { try FleetFileTree.write(Data("x".utf8), to: "door/x.txt", under: folder) }
        #expect(throws: FleetUnitRefused.self) { try FleetFileTree.write(Data("x".utf8), to: "../x.txt", under: folder) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.txt").path))

        // Removing the last file takes the folders it leaves empty with it, never the skill's own folder.
        try FleetFileTree.remove("scripts/run.sh", under: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripts").path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func theHasherReadsAFileAgainOnlyWhenItChanged() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.txt")
        try "one".write(to: path, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        let hasher = FleetFileHasher()
        func file() throws -> FleetFileTree.File { try #require(FleetFileTree.files(under: path.path, limits: .init(files: 1, bytes: 100))?.first) }
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("one".utf8)))
        // Same size and time: answered from what it remembers, not from the bytes (which changed behind its back).
        try "two".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("one".utf8)))
        try "three".write(to: path, atomically: true, encoding: .utf8)
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("three".utf8)))
    }

    @Test func skillAndExtensionUnitsSplitIntoTheirParts() {
        #expect(FleetUnit.skillParts(of: "skill:pdf")?.name == "pdf" && FleetUnit.skillParts(of: "skill:pdf")?.path == nil)
        let file = FleetUnit.skillParts(of: FleetUnit.skillFile("pdf", "scripts/run.sh"))
        #expect(file?.name == "pdf" && file?.path == "scripts/run.sh")
        #expect(FleetUnit.skillParts(of: "setting:host.defaultModel") == nil)
        #expect(FleetUnit.isValid(FleetUnit.extensionFile("paths/acme/index.ts")) && FleetUnit.isValid(FleetUnit.extensionMeta("paths/acme")))
        #expect(!FleetUnit.isValid("extension:paths/../../x"))
    }

    // MARK: A unit that waits for another

    /// A source of two units where `state` can only be written once `file` is.
    final class DependentSource: FleetUnitSource, @unchecked Sendable {
        var values: [String: Data] = [:]
        let units = ["skill:x", "skill:x/SKILL.md"]
        func storesBlob(_ unit: String) -> Bool { unit.contains("/") }
        func read() -> [String: Data] { values }
        func isSeedable(_ unit: String, _ value: Data) -> Bool { true }
        func write(_ unit: String, _ value: Data?, origin: String) throws {
            if unit == "skill:x", values["skill:x/SKILL.md"] == nil { throw FleetUnitWaiting(description: "no files yet") }
            values[unit] = value
        }
    }

    @Test func aUnitThatNeedsAnotherIsWrittenAfterItInTheSamePassAndNeverComesBackAsAnOp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sender = try FleetStore(directory: dir.appendingPathComponent("a"), mac: UUID())
        let receiverStore = try FleetStore(directory: dir.appendingPathComponent("b"), mac: UUID())
        // The state sorts first, so it is asked to write before its file exists.
        let state = sender.appendLocal(unit: "skill:x", change: .value("{\"on\":true}"), seed: false, name: "A")!
        let hash = try #require(sender.putBlob(Data("# x".utf8)))
        let file = sender.appendLocal(unit: "skill:x/SKILL.md", change: .blob(hash: hash, size: 3), seed: false, name: "A")!
        _ = receiverStore.receive(state)
        _ = receiverStore.receive(file)
        _ = receiverStore.putBlob(Data("# x".utf8), named: hash)

        let materializer = FleetMaterializer(store: receiverStore, directory: dir.appendingPathComponent("b"))
        let source = DependentSource()
        materializer.add(source)
        let result = materializer.materialize(name: "B")
        #expect(!result.failed)
        #expect(source.values["skill:x"] == Data("{\"on\":true}".utf8) && source.values["skill:x/SKILL.md"] == Data("# x".utf8), "both landed in one pass")
        #expect(materializer.scan(name: "B").isEmpty, "nothing the materializer wrote is an edit")
    }
}
