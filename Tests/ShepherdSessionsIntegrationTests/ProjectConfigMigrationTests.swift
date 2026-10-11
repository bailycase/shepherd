import Foundation
import Darwin
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project configuration cutover", .integrationTimeLimit)
struct ProjectConfigMigrationTests {
    @Test func legacySessionHeadersAreIncludedAndOversizedLedgerReadsAndWritesFailConsistently() async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let support = scratch.appendingPathComponent("support"), sessions = support.appendingPathComponent("sessions")
        let project = scratch.appendingPathComponent("session-only")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session", "cwd": project.path])
        try (header + Data([10])).write(to: sessions.appendingPathComponent("old.jsonl"))
        func store() -> ProjectSettingsStore {
            ProjectSettingsStore(historyURL: support.appendingPathComponent("projects.json"), home: scratch.appendingPathComponent("home"), sessions: sessions)
        }
        let first = store()
        first.migrateExistingProjectConfiguration(in: ShepherdState())
        try await first.prepareProjectConfiguration(for: project.path)
        #expect(fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
        let ledger = support.appendingPathComponent("project-config-migration.json")
        let handle = try FileHandle(forWritingTo: ledger)
        try handle.truncate(atOffset: 4 * 1024 * 1024 + 1)
        try handle.close()
        let oversized = store()
        oversized.migrateExistingProjectConfiguration(in: ShepherdState())
        await #expect(throws: ProjectFileError.self) { try await oversized.prepareProjectConfiguration(for: project.path) }
        try fm.removeItem(at: ledger)
        let entries = (0..<1100).map { ["directory": "/" + String(repeating: "a", count: 4000) + String($0), "name": "large"] }
        try JSONSerialization.data(withJSONObject: entries).write(to: support.appendingPathComponent("projects.json"))
        for _ in 0..<2 {
            let huge = store()
            huge.migrateExistingProjectConfiguration(in: ShepherdState())
            await #expect(throws: ProjectFileError.self) { try await huge.prepareProjectConfiguration(for: project.path) }
            #expect(!fm.fileExists(atPath: ledger.path))
        }
    }

    @Test func theHostFenceRefusesRPCSpawnsAndChildPreparationUntilAnUnsafeSourceIsRepaired() async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let support = scratch.appendingPathComponent("support"), project = scratch.appendingPathComponent("project")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        let state = ShepherdState(spaces: [Space(name: "known", path: project.path)])
        try JSONEncoder().encode(state).write(to: support.appendingPathComponent("state.json"))
        let escape = project.appendingPathComponent(".pi/escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: project)
        let host = try ScratchServer(dir: support)
        defer { host.stop() }
        let marker = project.appendingPathComponent("spawned")
        let params = CreateSessionParams(cwd: project.path, command: ["/bin/sh", "-c", "touch '\(marker.path)'"], runtime: .rpc)
        await #expect(throws: ProjectFileError.self) { _ = try await host.server.createSession(params: params) }
        #expect(!fm.fileExists(atPath: marker.path))
        let client = try ExtensionClient(path: host.socketPath)
        try client.send(.prepareProjectConfiguration(id: 1, agentID: AgentID(), cwd: project.path))
        guard case .error(1, "config_migration", _) = try await client.reply() else { Issue.record("Expected migration refusal"); return }
        #expect(!fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
        try fm.removeItem(at: escape)
        try client.send(.prepareProjectConfiguration(id: 2, agentID: AgentID(), cwd: project.path))
        #expect(try await client.reply() == .ok(id: 2))
        #expect(fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
        client.closeConnection()
    }

    @Test func existingProjectsAreCopiedOnceWhileNewProjectsRemainUntouchedAcrossRestarts() async throws {
        let scratch = try makeScratchDirectory("cfg")
        let fm = FileManager.default
        let support = scratch.appendingPathComponent("support")
        let home = scratch.appendingPathComponent("home")
        let old = scratch.appendingPathComponent("old"), new = scratch.appendingPathComponent("new")
        let payload = Data(repeating: 65, count: 200_001)
        for project in [old, new] {
            try fm.createDirectory(at: project.appendingPathComponent(".pi/skills/test"), withIntermediateDirectories: true)
            try payload.write(to: project.appendingPathComponent(".pi/skills/test/SKILL.md"))
        }
        func store() -> ProjectSettingsStore {
            ProjectSettingsStore(historyURL: support.appendingPathComponent("projects.json"), home: home, sessions: support.appendingPathComponent("sessions"))
        }
        let first = store()
        first.migrateExistingProjectConfiguration(in: ShepherdState(spaces: [Space(name: "old", path: old.path)]))
        try await first.prepareProjectConfiguration(for: old.path)
        #expect(try Data(contentsOf: old.appendingPathComponent(".shepherd/skills/test/SKILL.md")) == payload)
        #expect(try Data(contentsOf: old.appendingPathComponent(".pi/skills/test/SKILL.md")) == payload)
        let both = ShepherdState(spaces: [Space(name: "old", path: old.path), Space(name: "new", path: new.path)])
        first.remember(both)
        try await first.prepareProjectConfiguration(for: new.path)
        let next = store()
        next.migrateExistingProjectConfiguration(in: both)
        try await next.prepareProjectConfiguration(for: new.path)
        #expect(!fm.fileExists(atPath: new.appendingPathComponent(".shepherd").path))
        try Data("original changed".utf8).write(to: old.appendingPathComponent(".pi/skills/test/SKILL.md"))
        try await next.prepareProjectConfiguration(for: old.path)
        #expect(try Data(contentsOf: old.appendingPathComponent(".shepherd/skills/test/SKILL.md")) == payload)
    }

    @Test func unsafeSourcesFailAtomicallyAndCanBeRetriedWithoutOverwritingAnExistingDestination() async throws {
        let root = try makeScratchDirectory("cfg")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: root.appendingPathComponent(".pi/AGENTS.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent(".pi/escape"), withDestinationURL: root.appendingPathComponent(".pi/AGENTS.md"))
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == [".pi"])
        try fm.removeItem(at: root.appendingPathComponent(".pi/escape"))
        try ProjectConfigMigration.copy(in: root)
        try Data("keep".utf8).write(to: root.appendingPathComponent(".shepherd/AGENTS.md"))
        try ProjectConfigMigration.copy(in: root)
        #expect(try String(contentsOf: root.appendingPathComponent(".shepherd/AGENTS.md"), encoding: .utf8) == "keep")
    }

    @Test func aggregateBytesAndEntryCountCannotExceedTheDefaultCopyBounds() throws {
        let root = try makeScratchDirectory("cfg"), fm = FileManager.default
        let source = root.appendingPathComponent(".pi")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let data = Data(repeating: 65, count: ProjectConfigMigration.fileLimit)
        for index in 0..<4 { try data.write(to: source.appendingPathComponent("part\(index)")) }
        try Data([65]).write(to: source.appendingPathComponent("extra"))
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
        for name in try fm.contentsOfDirectory(atPath: source.path) { try fm.removeItem(at: source.appendingPathComponent(name)) }
        for index in 0...ProjectConfigMigration.entryLimit { try Data().write(to: source.appendingPathComponent("file\(index)")) }
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
    }

    @Test func theCopyRefusesSpecialFilesAndTheDefaultByteAndDepthBounds() throws {
        let root = try makeScratchDirectory("cfg")
        let fm = FileManager.default, source = root.appendingPathComponent(".pi")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root, deadline: .distantPast) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
        let fifo = source.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        try fm.removeItem(at: fifo)
        try Data(repeating: 0, count: ProjectConfigMigration.fileLimit + 1).write(to: source.appendingPathComponent("large"))
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        try fm.removeItem(at: source.appendingPathComponent("large"))
        let deep = (0...ProjectConfigMigration.depthLimit).reduce(source) { $0.appendingPathComponent("d\($1)") }
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(throws: ProjectFileError.self) { try ProjectConfigMigration.copy(in: root) }
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
    }

    @Test func homeGlobalAndSupportFoldersAreExcludedAndFailuresBlockOnlyAffectedLaunches() async throws {
        let scratch = try makeScratchDirectory("cfg")
        let fm = FileManager.default
        let home = scratch.appendingPathComponent("home"), support = scratch.appendingPathComponent("support")
        let global = home.appendingPathComponent(".pi/agent"), managed = support.appendingPathComponent("other")
        let bad = scratch.appendingPathComponent("bad"), good = scratch.appendingPathComponent("good")
        for root in [home, global, managed, bad, good] {
            try fm.createDirectory(at: root.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: bad.appendingPathComponent(".pi/escape"), withDestinationURL: good)
        let projects = ProjectSettingsStore(historyURL: support.appendingPathComponent("projects.json"), home: home, sessions: support.appendingPathComponent("sessions"))
        projects.migrateExistingProjectConfiguration(in: ShepherdState(spaces: [home, global, managed, bad, good].map { Space(name: $0.lastPathComponent, path: $0.path) }))
        for root in [home, global, managed] {
            try await projects.prepareProjectConfiguration(for: root.path)
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".shepherd").path))
        }
        await #expect(throws: ProjectFileError.self) { try await projects.prepareProjectConfiguration(for: bad.path) }
        try await projects.prepareProjectConfiguration(for: good.path)
        #expect(fm.fileExists(atPath: good.appendingPathComponent(".shepherd").path))
        try fm.removeItem(at: bad.appendingPathComponent(".pi/escape"))
        try await projects.prepareProjectConfiguration(for: bad.path)
        #expect(fm.fileExists(atPath: bad.appendingPathComponent(".shepherd").path))
    }
}
