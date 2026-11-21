import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// `skills.json` records where each skill came from. A file that exists and can't be read is damage:
/// the host says so, refuses every change that would write it, and takes the file back the moment
/// it reads cleanly. Only a missing file means "no records".
@Suite("Skills records", .integrationTimeLimit)
struct SkillsRecordsTests {
    static let record = #"{"source":{"repo":"acme/skills","path":"skills/pdf","commit":"abc123"},"installedAt":1}"#
    static let legacy = #"{"version":1,"autoUpdate":true,"checkedAt":5,"skills":{"pdf":"#+record+#"},"removed":{}}"#
    static let envelope = #"{"version":1,"value":"#+legacy+"}"

    struct Fixture {
        let store: SkillsStore
        let directory: URL
        let state: URL
        var records: URL { state.appendingPathComponent("skills.json") }

        init() throws {
            let root = try makeScratchDirectory("skills-records")
            directory = root.appendingPathComponent("agent-skills", isDirectory: true)
            state = root.appendingPathComponent("support-skills", isDirectory: true)
            store = SkillsStore(directory: directory, stateDirectory: state)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try skill("pdf")
        }

        func skill(_ name: String) throws {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: A skill.\n---\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }

        func write(_ json: String) throws { try Data(json.utf8).write(to: records, options: .atomic) }
        func bytes() throws -> Data { try Data(contentsOf: records) }
        var skillIsInstalled: Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("pdf/SKILL.md").path)
        }
    }

    static let invalidUTF8InAString: Data = {
        let parts = legacy.components(separatedBy: "acme/skills")
        return Data(parts[0].utf8) + Data("acme/".utf8) + Data([0xff]) + Data("skills".utf8) + Data(parts[1].utf8)
    }()

    /// Every way the file can exist and still not be a records file.
    static let damage: [(String, Data)] = [
        ("truncated", Data(#"{"version":1,"skills":{"#.utf8)),
        ("null autoUpdate", Data(legacy.replacingOccurrences(of: #""autoUpdate":true"#, with: #""autoUpdate":null"#).utf8)),
        ("wrong type autoUpdate", Data(legacy.replacingOccurrences(of: #""autoUpdate":true"#, with: #""autoUpdate":"yes""#).utf8)),
        ("null checkedAt", Data(legacy.replacingOccurrences(of: #""checkedAt":5"#, with: #""checkedAt":null"#).utf8)),
        ("skills is a list", Data(#"{"version":1,"skills":[]}"#.utf8)),
        ("a record without a source", Data(#"{"version":1,"skills":{"pdf":{"installedAt":1}}}"#.utf8)),
        ("null removed record", Data(#"{"removed":{"pdf":{"wasOn":true,"record":null,"removedAt":1}}}"#.utf8)),
        ("a list", Data("[]".utf8)),
        ("invalid UTF-8", Data([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d])),
        // The next two are whole, well formed JSON that a plain decoder reads: only the bytes are wrong.
        ("invalid UTF-8 inside a string", invalidUTF8InAString),
        ("UTF-16", Data(legacy.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })),
        ("an envelope with an extra key", Data((String(envelope.dropLast()) + #","notes":"kept by hand"}"#).utf8)),
        ("null committedAt in a source", Data(legacy.replacingOccurrences(of: #""commit":"abc123""#, with: #""commit":"abc123","committedAt":null"#).utf8)),
        ("null committedAt in an update", Data(legacy.replacingOccurrences(
            of: #""installedAt":1"#, with: #""installedAt":1,"update":{"commit":"def456","committedAt":null,"filesChanged":2}"#).utf8)),
        ("null where nothing reads it", Data(legacy.replacingOccurrences(of: #""removed":{}"#, with: #""removed":{},"extra":null"#).utf8)),
        // A dictionary keeps one of two members with the same key, so these only show to a reader of the tokens.
        ("a null before a repeated key", Data(legacy.replacingOccurrences(of: #""removed":{}"#, with: #""removed":{},"extra":null,"extra":1"#).utf8)),
        ("a null after a repeated key", Data(legacy.replacingOccurrences(of: #""removed":{}"#, with: #""removed":{},"extra":1,"extra":null"#).utf8)),
        ("a repeated key spelled with an escape", Data(legacy.replacingOccurrences(of: #""removed":{}"#, with: #""removed":{},"extra":1,"\u0065xtra":2"#).utf8)),
        ("a repeated setting", Data(legacy.replacingOccurrences(of: #""autoUpdate":true"#, with: #""autoUpdate":false,"autoUpdate":true"#).utf8)),
        ("a repeated skill", Data(legacy.replacingOccurrences(of: record, with: record + #","pdf":"# + record).utf8)),
        // The decoder reads these where nothing needs them; a strict parse does not.
        ("a number JSON forbids in a key nothing reads", Data(legacy.replacingOccurrences(of: #""removed":{}"#, with: #""removed":{},"extra":01"#).utf8)),
        ("an unknown envelope version", Data(envelope.replacingOccurrences(of: #""version":1,"value""#, with: #""version":2,"value""#).utf8)),
    ]

    @Test func bothShapesRead() throws {
        for json in [Self.legacy, Self.envelope] {
            let fixture = try Fixture()
            try fixture.write(json)
            let snapshot = fixture.store.snapshot()
            #expect(snapshot.problem == nil)
            #expect(snapshot.autoUpdate)
            #expect(snapshot.checkedAt == 5)
            #expect(snapshot.skill("pdf")?.source?.commit == "abc123")
        }
    }

    @Test func aMissingFileMeansNoRecords() throws {
        let fixture = try Fixture()
        let snapshot = fixture.store.snapshot()
        #expect(snapshot.problem == nil)
        #expect(snapshot.skill("pdf")?.source == nil)
        _ = try fixture.store.configure(autoUpdate: true)
        #expect(fixture.store.snapshot().autoUpdate)
    }

    @Test(arguments: damage) func aDamagedFileIsReportedAndNeverWrittenOver(shape: (String, Data)) throws {
        let fixture = try Fixture()
        try shape.1.write(to: fixture.records)
        let snapshot = fixture.store.snapshot()
        let problem = try #require(snapshot.problem, "\(shape.0)")
        #expect(problem.contains(fixture.records.path))
        #expect(problem.contains("backup"))
        #expect(!FleetSkillsSource(fixture.store).isReady)
        #expect(snapshot.skills.map(\.name) == ["pdf"], "the skills themselves still show")

        func refused(_ change: () throws -> Void) {
            do { try change(); Issue.record("\(shape.0): a change wrote over damaged records") } catch let error as SkillsStore.StoreError {
                #expect(error == .damagedRecords(problem))
                #expect(error.code == "write_failed")
            } catch { Issue.record("\(shape.0): \(error)") }
        }
        refused { _ = try fixture.store.configure(autoUpdate: true) }
        refused { _ = try fixture.store.remove("pdf") }
        refused { _ = try fixture.store.restore("pdf") }
        refused { _ = try fixture.store.checkUpdates() }
        refused { _ = try fixture.store.install(repo: "acme/skills", paths: ["skills/pdf"], commit: nil, invocation: nil) }
        refused { _ = try fixture.store.installFiles(name: "docx", files: [SkillFile(path: "SKILL.md", contents: Data("x".utf8))], invocation: .automatic) }
        refused { _ = try fixture.store.applySynced("pdf", on: false, source: nil) }
        #expect(try fixture.bytes() == shape.1, "\(shape.0): the damaged bytes are untouched")
        #expect(fixture.skillIsInstalled, "\(shape.0): a refused remove moved nothing")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("docx").path))
    }

    /// Records of 256 KiB or more are refused unread, because the server queue does the decoding.
    @Test func recordsAreReadBelowTheBoundAndRefusedAtIt() throws {
        let limit = SkillsStore.maxRecordsBytes
        func padded(to size: Int) -> String { Self.legacy + String(repeating: " ", count: size - Self.legacy.utf8.count) }

        let under = try Fixture()
        try under.write(padded(to: limit - 1))
        #expect(under.store.snapshot().problem == nil)
        #expect(under.store.snapshot().skill("pdf")?.source?.commit == "abc123")
        #expect(FleetSkillsSource(under.store).isReady)

        let over = try Fixture()
        try over.write(padded(to: limit))
        let problem = try #require(over.store.snapshot().problem)
        #expect(problem.contains(over.records.path) && problem.contains("256 KiB") && problem.contains("backup"))
        #expect(!FleetSkillsSource(over.store).isReady)
        #expect(throws: SkillsStore.StoreError.self) { try over.store.configure(autoUpdate: false) }
        #expect(try over.bytes().count == limit, "the big file is untouched")
        // The same file, made small again, takes over at once.
        try over.write(Self.legacy)
        #expect(over.store.snapshot().problem == nil)
    }

    /// The writer holds the bound the reader does: a save that would write a file the next read refuses fails instead.
    @Test func aSaveThatWouldWriteRecordsTheNextReadRefusesFailsAndLeavesTheFileAlone() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        let huge = SkillSource(repo: "acme/skills", path: String(repeating: "p", count: SkillsStore.maxRecordsBytes), commit: "abc123")
        do {
            _ = try fixture.store.applySynced("pdf", on: true, source: huge)
            Issue.record("the save should have been refused")
        } catch {
            #expect("\(error)".contains("256 KiB"))
        }
        #expect(try fixture.bytes() == Data(Self.legacy.utf8), "nothing was written")
        #expect(fixture.store.snapshot().problem == nil, "and the records still read")
    }

    /// A change that moves a folder and then can't save its records would leave a repository skill with no
    /// source. The size is checked first, so a refusal leaves the folders and the file as they were.
    @Test func aChangeThatWouldOutgrowTheRecordsIsRefusedBeforeAnyFolderMoves() throws {
        let limit = SkillsStore.maxRecordsBytes
        let skeleton = #"{"version":1,"removed":{"":{"wasOn":true,"removedAt":99999999999}}}"#
        let full = skeleton.replacingOccurrences(of: #"{"":"#, with: #"{"\#(String(repeating: "n", count: limit - 1 - skeleton.utf8.count))":"#)
        #expect(full.utf8.count == limit - 1)
        let fixture = try Fixture()
        try fixture.write(full)
        try Data("notes\n".utf8).write(to: fixture.directory.appendingPathComponent("pdf/notes.md"))
        let repo = try makeScratchRepo(files: ["skills/pdf/SKILL.md": "---\nname: pdf\ndescription: From the repository.\n---\n"])
        let folder = fixture.directory.appendingPathComponent("pdf")
        func files() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try ["SKILL.md", "notes.md"].map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        }
        let before = try files()

        func refused(_ change: () throws -> Void) {
            do { try change(); Issue.record("the change should have been refused") } catch {
                #expect("\(error)".contains("256 KiB"), "\(error)")
            }
            #expect((try? files()) == before, "the skill's folder is as it was")
            #expect((try? fixture.bytes()) == Data(full.utf8), "the records are as they were")
        }
        refused { _ = try fixture.store.install(repo: "file://" + repo.path, paths: ["skills/pdf"], commit: nil, invocation: nil) }
        refused { _ = try fixture.store.remove("pdf") }
        refused { _ = try fixture.store.applySynced("pdf", on: false, source: SkillSource(repo: "acme/skills", path: "skills/pdf", commit: "abc123")) }
        #expect(fixture.store.snapshot().skill("pdf")?.isOn == true, "applySynced didn't move it off")
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("removed").path))
    }

    @Test func aChangeThatDoesNotWriteTheRecordsStillWorks() throws {
        let fixture = try Fixture()
        try fixture.write("{")
        _ = try fixture.store.setOn("pdf", on: false)
        #expect(fixture.store.snapshot().skill("pdf")?.isOn == false)
        #expect(try fixture.bytes() == Data("{".utf8))
    }

    @Test func repairingTheFileLiftsTheRefusalWithoutARestart() throws {
        let fixture = try Fixture()
        try fixture.write("{")
        #expect(fixture.store.snapshot().problem != nil)
        try fixture.write(Self.legacy)
        #expect(FleetSkillsSource(fixture.store).isReady)
        let snapshot = try fixture.store.configure(autoUpdate: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.skill("pdf")?.source?.commit == "abc123", "the repaired file's records were kept, not replaced")
    }

    @Test func deletingTheDamagedFileIsARepair() throws {
        let fixture = try Fixture()
        try fixture.write("{")
        try FileManager.default.removeItem(at: fixture.records)
        #expect(fixture.store.snapshot().problem == nil)
        _ = try fixture.store.configure(autoUpdate: true)
        #expect(fixture.store.snapshot().autoUpdate)
    }

    @Test func aBackupRestoredBeforeAWriteIsWhatTheWriteBuildsOn() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        #expect(fixture.store.snapshot().skill("pdf")?.source != nil)
        // The file is damaged and then put back from a backup holding a different source.
        try fixture.write("{")
        #expect(fixture.store.snapshot().problem != nil)
        try fixture.write(Self.legacy.replacingOccurrences(of: "abc123", with: "def456"))
        _ = try fixture.store.configure(autoUpdate: false)
        #expect(fixture.store.snapshot().skill("pdf")?.source?.commit == "def456")
    }

    @Test func aFileThatCannotBeReadIsDamageUntilItCan() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.records.path)
        let problem = try #require(fixture.store.snapshot().problem)
        #expect(problem.contains(fixture.records.path))
        #expect(throws: SkillsStore.StoreError.self) { try fixture.store.configure(autoUpdate: false) }
        // One failed read is not permanent: the next use reads it again.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.records.path)
        #expect(fixture.store.snapshot().problem == nil)
        #expect(fixture.store.snapshot().skill("pdf")?.source?.commit == "abc123")
    }

    @Test func aTouchedDamagedFileStaysDamagedAndAHealthyOneStaysHealthy() throws {
        let fixture = try Fixture()
        try fixture.write("{")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fixture.records.path)
        #expect(fixture.store.snapshot().problem != nil)
        try fixture.write(Self.legacy)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.records.path)
        #expect(fixture.store.snapshot().problem == nil)
        try fixture.write(Self.legacy)
        #expect(fixture.store.snapshot().skill("pdf")?.source?.commit == "abc123")
    }

    @Test func aRemovalThatCannotBeRecordedPutsTheSkillBackAndSucceedsOnRetry() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path) }
        do {
            _ = try fixture.store.remove("pdf")
            Issue.record("the removal didn't fail on a read-only folder")
        } catch let error as SkillsStore.StoreError {
            guard case .writeFailed = error else { Issue.record("\(error)"); return }
        }
        #expect(fixture.skillIsInstalled)
        #expect(fixture.store.snapshot().skill("pdf")?.source?.commit == "abc123")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path)
        _ = try fixture.store.remove("pdf")
        #expect(!fixture.skillIsInstalled)
        let restored = try fixture.store.restore("pdf")
        #expect(restored.skill("pdf")?.source?.commit == "abc123")
    }

    /// The records can't be saved after the skill has already moved (`removed/` exists, so the move works):
    /// the skill goes back where it was and a retry succeeds.
    @Test func aRemovalThatFailsAtTheSavePutsTheSkillBackAndItsRecordsStay() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        let removed = fixture.state.appendingPathComponent("removed", isDirectory: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path) }
        #expect(throws: SkillsStore.StoreError.self) { try fixture.store.remove("pdf") }
        #expect(fixture.skillIsInstalled)
        #expect(!FileManager.default.fileExists(atPath: removed.appendingPathComponent("pdf").path))
        #expect(try fixture.bytes() == Data(Self.legacy.utf8))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path)
        _ = try fixture.store.remove("pdf")
        #expect(!fixture.skillIsInstalled)
    }

    @Test func aRestoreThatCannotBeRecordedLeavesTheSkillRemovedAndSucceedsOnRetry() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        _ = try fixture.store.remove("pdf")
        let recorded = try fixture.bytes()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path) }
        #expect(throws: SkillsStore.StoreError.self) { try fixture.store.restore("pdf") }
        #expect(!fixture.skillIsInstalled, "the failed restore moved it back to Undo")
        #expect(try fixture.bytes() == recorded)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.state.path)
        let restored = try fixture.store.restore("pdf")
        #expect(fixture.skillIsInstalled)
        #expect(restored.skill("pdf")?.source?.commit == "abc123")
    }

    /// Touching the file or rewriting the same bytes is not damage and not a different file: the next
    /// save builds on what is there and keeps it.
    @Test func aTouchedOrIdenticallyRewrittenFileIsSavedOnWithItsRecordsKept() throws {
        let fixture = try Fixture()
        try fixture.write(Self.legacy)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.records.path)
        try fixture.write(Self.legacy)
        _ = try fixture.store.configure(autoUpdate: false)
        let saved = try fixture.bytes()
        #expect(String(decoding: saved, as: UTF8.self).contains("abc123"))
        let snapshot = fixture.store.snapshot()
        #expect(snapshot.problem == nil && !snapshot.autoUpdate && snapshot.checkedAt == 5)
        #expect(snapshot.skill("pdf")?.source?.commit == "abc123")
    }

    @Test func fleetLeavesSkillsAloneWhileTheRecordsAreDamaged() throws {
        let fixture = try Fixture()
        let source = FleetSkillsSource(fixture.store)
        #expect(source.isReady)
        try fixture.write("{")
        #expect(!source.isReady)
        try fixture.write(Self.legacy)
        #expect(source.isReady)
    }

    @Test func aClientSeesTheProblemAndItsRefusedChangeSaysTheSame() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let url = host.server.skills.stateDirectory.appendingPathComponent("skills.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        let client = try await host.typed()
        defer { client.disconnect() }

        guard case .skills(let snapshot) = try await client.skills() else { Issue.record("expected the host's skills"); return }
        let problem = try #require(snapshot.problem)
        #expect(problem.contains(url.path))
        do {
            _ = try await client.skills(.configure(autoUpdate: true))
            Issue.record("the host let a client change skills over damaged records")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "write_failed")
            #expect(message == problem)
        }
        #expect(try Data(contentsOf: url) == Data("{".utf8))
    }
}
