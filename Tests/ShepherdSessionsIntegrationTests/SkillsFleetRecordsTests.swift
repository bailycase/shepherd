import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Fleet reads and writes skills through `skills.json`'s records. A Mac whose records can't be read
/// publishes nothing about its skills and takes no files for them: the pass is skipped, and the next
/// one after a repair does everything. These run real scans and materializations over real folders.
@Suite("Skills records in Fleet sync", .integrationTimeLimit)
struct SkillsFleetRecordsTests {
    static let skillText = "---\nname: pdf\ndescription: PDFs.\n---\n"

    /// A Mac with a skills folder, its records, and the Fleet source over them. `afterWrite` runs after
    /// each file the source writes, which is how a test breaks the records in the middle of a pass.
    final class Mac {
        let dir: URL
        let store: FleetStore
        let materializer: FleetMaterializer
        let skills: SkillsStore
        let source: FleetSkillsSource
        var afterWrite: () -> Void = {}
        var records: URL { skills.stateDirectory.appendingPathComponent("skills.json") }

        init() throws {
            dir = try makeScratchDirectory("skills-fleet")
            store = try FleetStore(directory: dir.appendingPathComponent("store"), mac: UUID())
            materializer = FleetMaterializer(store: store, directory: dir.appendingPathComponent("store"))
            skills = SkillsStore(directory: dir.appendingPathComponent("skills"), stateDirectory: dir.appendingPathComponent("skills-state"))
            let hook = Hook()
            source = FleetSkillsSource(skills, written: { hook.run() })
            materializer.add(source)
            hook.owner = self
            try FileManager.default.createDirectory(at: skills.stateDirectory, withIntermediateDirectories: true)
        }

        /// The box that lets the source's callback reach the Mac that owns the source.
        final class Hook {
            weak var owner: Mac?
            func run() { owner?.afterWrite() }
        }

        func put(_ text: String, at path: String, in name: String = "pdf") throws {
            let url = skills.directory.appendingPathComponent(name).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        /// pdf, installed from a repository, with auto-update on.
        func installPDF() throws {
            try put(SkillsFleetRecordsTests.skillText, at: "SKILL.md")
            try Data(SkillsRecordsTests.legacy.utf8).write(to: records)
        }

        func damage() throws { try Data("{".utf8).write(to: records) }

        func scan() -> [FleetOp] { materializer.scan(name: "Mac studio") }
        func passFailed() -> Bool { materializer.materialize(name: "Mac studio").failed }

        func stateValue(_ ops: [FleetOp], _ name: String = "pdf") throws -> FleetSkillsSource.State? {
            guard let op = ops.first(where: { $0.unit == FleetUnit.skill(name) }), case .value(let text) = op.change else { return nil }
            return try JSONDecoder().decode(FleetSkillsSource.State.self, from: Data(text.utf8))
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func aReadFailureAfterTheValidatedReadNeverPublishesALocalSkillOrAutoUpdateOff() throws {
        let mac = try Mac(); defer { mac.remove() }
        try mac.installPDF()
        #expect(mac.source.isReady)
        try mac.damage()
        let values = mac.source.read()
        let state = try JSONDecoder().decode(FleetSkillsSource.State.self, from: try #require(values[FleetUnit.skill("pdf")]))
        #expect(state.source?.commit == "abc123", "the records the pass validated, not Local")
        #expect(values[FleetSkillsSource.autoUpdate] == Data("true".utf8))
    }

    @Test func aPassOverDamagedRecordsPublishesNothingAndTheNextAfterARepairPublishesTheirSources() throws {
        let mac = try Mac(); defer { mac.remove() }
        try mac.installPDF()
        let first = mac.scan()
        #expect(try mac.stateValue(first)?.source?.commit == "abc123")

        try mac.damage()
        try mac.put(Self.skillText + "edited\n", at: "SKILL.md")
        #expect(mac.scan().isEmpty, "no op while the records can't be read: not a Local skill, not a deletion")
        #expect(mac.store.winner(of: FleetSkillsSource.autoUpdate)?.change == first.first { $0.unit == FleetSkillsSource.autoUpdate }?.change)

        try Data(SkillsRecordsTests.legacy.utf8).write(to: mac.records)
        // The edit goes out first; the skill's state follows once its file is the fleet's (one more pass).
        #expect(mac.scan().contains { $0.unit == FleetUnit.skillFile("pdf", "SKILL.md") }, "the edit made meanwhile is published once the records read")
        let state = try mac.stateValue(mac.scan())
        #expect(state?.source?.commit == "abc123", "from the repaired records, not Local")
        #expect(mac.scan().isEmpty)
    }

    private struct Sender {
        let store: FleetStore
        init(_ dir: URL) throws { store = try FleetStore(directory: dir.appendingPathComponent("sender"), mac: UUID()) }

        func skill(_ name: String, _ files: [String: String], to mac: Mac) {
            for (path, text) in files.sorted(by: { $0.key < $1.key }) {
                let hash = store.putBlob(Data(text.utf8))!
                _ = store.appendLocal(unit: FleetUnit.skillFile(name, path), change: .blob(hash: hash, size: text.utf8.count), seed: false, name: "Mac mini")
            }
            let digest = FleetTreeDigest.of(files.mapValues { FleetSyncProtocol.hash(Data($0.utf8)) })
            let state = FleetSkillsSource.json(.init(on: true, source: nil, digest: digest))
            _ = store.appendLocal(unit: FleetUnit.skill(name), change: .value(String(decoding: state, as: UTF8.self)), seed: false, name: "Mac mini")
            for op in store.ops(after: mac.store.vector) {
                _ = mac.store.receive(op)
                if let hash = op.blobHash, let data = store.blob(hash) { _ = mac.store.putBlob(data, named: hash) }
            }
        }
    }

    @Test func recordsThatBreakInTheMiddleOfAPassStopTheFilesAfterThemAndAreRetriedAfterARepair() throws {
        let mac = try Mac(); defer { mac.remove() }
        let files = ["SKILL.md": Self.skillText.replacingOccurrences(of: "pdf", with: "docs"), "notes.md": "# Notes\n"]
        try Sender(mac.dir).skill("docs", files, to: mac)
        var writes = 0
        mac.afterWrite = {
            writes += 1
            if writes == 1 { try? mac.damage() }
        }

        #expect(mac.passFailed(), "the refused write is a failure to try again")
        let written = ["skills", "skills-state/off"].flatMap { base in
            files.keys.filter { FileManager.default.fileExists(atPath: mac.dir.appendingPathComponent("\(base)/docs/\($0)").path) }
        }
        #expect(written == ["SKILL.md"], "the first file landed before the records broke; no file or folder after it")
        #expect(try Data(contentsOf: mac.records) == Data("{".utf8))
        #expect(!FileManager.default.fileExists(atPath: mac.skills.directory.appendingPathComponent("docs").path), "pi never sees half a skill")

        try FileManager.default.removeItem(at: mac.records)
        #expect(mac.scan().isEmpty, "a refused write was not taken for the fleet's value, so its absence is no deletion")
        #expect(!mac.passFailed())
        for (path, text) in files {
            #expect(try String(contentsOf: mac.skills.directory.appendingPathComponent("docs/" + path), encoding: .utf8) == text)
        }
        #expect(mac.skills.snapshot().skill("docs")?.isOn == true)
        #expect(mac.scan().isEmpty)
    }

    @Test func aSyncedWriteOrDeletionOverDamagedRecordsTouchesNothing() throws {
        let mac = try Mac(); defer { mac.remove() }
        try mac.installPDF()
        try mac.put("# Reference\n", at: "reference.md")
        try mac.damage()
        let skill = mac.skills.directory.appendingPathComponent("pdf")
        let before = try FolderBytes.snapshot(skill)

        #expect(throws: SkillsStore.StoreError.self) { try mac.source.write(FleetUnit.skillFile("pdf", "reference.md"), nil, origin: "Mac mini") }
        #expect(throws: SkillsStore.StoreError.self) { try mac.source.write(FleetUnit.skillFile("pdf", "SKILL.md"), nil, origin: "Mac mini") }
        #expect(throws: SkillsStore.StoreError.self) { try mac.source.write(FleetUnit.skillFile("pdf", "SKILL.md"), Data("x".utf8), origin: "Mac mini") }
        #expect(throws: SkillsStore.StoreError.self) { try mac.source.write(FleetUnit.skillFile("fresh", "SKILL.md"), Data("x".utf8), origin: "Mac mini") }
        #expect(throws: SkillsStore.StoreError.self) { try mac.source.write(FleetUnit.skill("pdf"), nil, origin: "Mac mini") }
        #expect(try FolderBytes.snapshot(skill) == before)
        #expect(!FileManager.default.fileExists(atPath: mac.skills.directory.appendingPathComponent("fresh").path))
        #expect(!FileManager.default.fileExists(atPath: mac.skills.stateDirectory.appendingPathComponent("off/fresh").path))
        #expect(try Data(contentsOf: mac.records) == Data("{".utf8))
    }
}

/// A folder's files and their bytes, to show that a refused change left it alone.
private enum FolderBytes {
    static func snapshot(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
}
