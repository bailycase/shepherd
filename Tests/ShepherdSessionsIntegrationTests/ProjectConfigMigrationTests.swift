import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project configuration aliases", .integrationTimeLimit)
struct ProjectConfigMigrationTests {
    @Test func existingProjectsReadLivePiFilesWithoutCopyingAcrossRestarts() async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let support = scratch.appendingPathComponent("support"), project = scratch.appendingPathComponent("project")
        try fm.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        let file = project.appendingPathComponent(".pi/settings.json")
        try Data("{\"theme\":\"light\"}".utf8).write(to: file)
        let state = ShepherdState(spaces: [Space(name: "project", path: project.path)])
        func store() -> ProjectSettingsStore {
            ProjectSettingsStore(historyURL: support.appendingPathComponent("projects.json"), home: scratch.appendingPathComponent("home"), sessions: support.appendingPathComponent("sessions"))
        }
        for value in ["{\"theme\":\"light\"}", "{\"theme\":\"dark\"}"] {
            try Data(value.utf8).write(to: file)
            let projects = store()
            projects.migrateExistingProjectConfiguration(in: state)
            try await projects.prepareProjectConfiguration(for: project.path)
            guard case .text(let text) = try await projects.request(.read(directory: project.path, file: ".pi/settings.json"), state: state) else { Issue.record("Expected Pi settings"); return }
            #expect(text.text == value)
            #expect(!fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
            #expect(!fm.fileExists(atPath: support.appendingPathComponent("project-config-migration.json").path))
        }
    }

    @Test func bothRootsAreInventoriedAndEditsKeepTheirConcreteSource() async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let project = scratch.appendingPathComponent("project"), support = scratch.appendingPathComponent("support")
        for base in [".pi", ".shepherd"] {
            try fm.createDirectory(at: project.appendingPathComponent(base + "/skills/test"), withIntermediateDirectories: true)
            try Data("---\nname: test\ndescription: fixture\n---\n".utf8).write(to: project.appendingPathComponent(base + "/skills/test/SKILL.md"))
            try Data("{\"theme\":\"\(base)\"}".utf8).write(to: project.appendingPathComponent(base + "/settings.json"))
            try Data("{\"mcpServers\":{\"\(base.dropFirst())\":{\"command\":\"fixture\"}}}".utf8).write(to: project.appendingPathComponent(base + "/mcp.json"))
        }
        let state = ShepherdState(spaces: [Space(name: "project", path: project.path)])
        let projects = ProjectSettingsStore(historyURL: support.appendingPathComponent("projects.json"), home: scratch.appendingPathComponent("home"), sessions: support.appendingPathComponent("sessions"))
        guard case .files(let files) = try await projects.request(.files(directory: project.path), state: state) else { Issue.record("Expected inventory"); return }
        for base in [".pi", ".shepherd"] {
            #expect(files.contains { $0.path == base + "/settings.json" && $0.exists })
            #expect(files.contains { $0.path == base + "/skills/test/SKILL.md" && $0.exists })
        }
        #expect(ProjectConfiguration.file("settings.json", in: project) == ".shepherd/settings.json")
        _ = try await projects.request(.save(directory: project.path, file: ".pi/settings.json", text: "{}", expected: "{\"theme\":\".pi\"}"), state: state)
        #expect(try String(contentsOf: project.appendingPathComponent(".pi/settings.json"), encoding: .utf8) == "{}")
        #expect(try String(contentsOf: project.appendingPathComponent(".shepherd/settings.json"), encoding: .utf8) == "{\"theme\":\".shepherd\"}")
        guard case .context(let context) = try await projects.request(.context(directory: project.path), state: state) else { Issue.record("Expected context"); return }
        #expect(context.mcpServers == 2)
        try #"{"packages":["./local-package"]}"#.write(to: project.appendingPathComponent(".pi/settings.json"), atomically: true, encoding: .utf8)
        guard case .context(let mergedContext) = try await projects.request(.context(directory: project.path), state: state) else { Issue.record("missing context"); return }
        #expect(mergedContext.resources == 3)
        let preferred = project.appendingPathComponent(".shepherd/settings.json")
        try fm.removeItem(at: preferred)
        try fm.createSymbolicLink(at: preferred, withDestinationURL: project.appendingPathComponent("missing.json"))
        #expect(ProjectConfiguration.file("settings.json", in: project) == ".shepherd/settings.json")
        await #expect(throws: ProjectFileError.self) {
            _ = try await projects.request(.context(directory: project.path), state: state)
        }
    }

    @Test(arguments: [".pi", ".shepherd"])
    func aliasesRetainSymlinkAndSecretFileProtections(_ base: String) async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let project = scratch.appendingPathComponent("project"), outside = scratch.appendingPathComponent("outside")
        for folder in [project, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: outside.appendingPathComponent("settings.json"))
        try fm.createSymbolicLink(at: project.appendingPathComponent(base), withDestinationURL: outside)
        let state = ShepherdState(spaces: [Space(name: "project", path: project.path)])
        let projects = ProjectSettingsStore(historyURL: scratch.appendingPathComponent("support/projects.json"), home: scratch.appendingPathComponent("home"), sessions: scratch.appendingPathComponent("sessions"))
        for file in [base + "/settings.json", base + "/auth.json", base + "/../outside/settings.json"] {
            await #expect(throws: ProjectFileError.self) { _ = try await projects.request(.read(directory: project.path, file: file), state: state) }
        }
        await #expect(throws: ProjectFileError.self) { _ = try await projects.request(.save(directory: project.path, file: base + "/settings.json", text: "{\"bad\":true}", expected: "{}"), state: state) }
        #expect(try String(contentsOf: outside.appendingPathComponent("settings.json"), encoding: .utf8) == "{}")
    }

    @Test func theCompatibilityLaunchRequestDoesNotCopyProjectFiles() async throws {
        let scratch = try makeScratchDirectory("cfg"), fm = FileManager.default
        let project = scratch.appendingPathComponent("project")
        try fm.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        let host = try ScratchServer(dir: scratch.appendingPathComponent("support"))
        defer { host.stop() }
        let client = try ExtensionClient(path: host.socketPath)
        defer { client.closeConnection() }
        try client.send(.prepareProjectConfiguration(id: 1, agentID: AgentID(), cwd: project.path))
        #expect(try await client.reply() == .ok(id: 1))
        #expect(!fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
    }
}
