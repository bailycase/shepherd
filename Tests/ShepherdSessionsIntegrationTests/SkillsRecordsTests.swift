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
        #expect(!fixture.store.recordsAreReadable)
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
        #expect(fixture.store.recordsAreReadable)
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
