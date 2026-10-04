import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project settings safety", .integrationTimeLimit)
struct ProjectSettingsSafetyTests {
    @Test func globalConfigurationDirectoriesNeverBecomeProjectFiles() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let home = scratch.dir.appendingPathComponent("home")
        let instructions = scratch.dir.appendingPathComponent("instructions")
        let globalSkills = home.appendingPathComponent(".agents/skills/check")
        for directory in [home, instructions, globalSkills] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let store = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("projects.json"), home: home, sessions: scratch.dir.appendingPathComponent("sessions"))
        for directory in [home, instructions, globalSkills] {
            let state = ShepherdState(spaces: [Space(name: "global", path: directory.path)])
            do { _ = try await store.request(.read(directory: directory.path, file: "AGENTS.md"), state: state); Issue.record("Global files became project files") }
            catch let error as ProjectFileError { #expect(error.code == "global_settings") }
        }
    }

    @Test func symlinkedAndCustomGlobalPiDirectoriesCannotBeEditedAsProjects() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let home = scratch.dir.appendingPathComponent("home")
        let global = scratch.dir.appendingPathComponent("global-pi")
        let custom = scratch.dir.appendingPathComponent("custom-pi")
        for root in [home, global, custom] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".pi"), withDestinationURL: global)
        for root in [global, custom] { try Data("global instructions".utf8).write(to: root.appendingPathComponent("AGENTS.md")) }
        let store = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("registry/projects.json"), home: home,
                                         sessions: scratch.dir.appendingPathComponent("sessions"), globalDirectories: { [custom] })
        let state = ShepherdState(spaces: [Space(name: "global", path: global.path), Space(name: "custom", path: custom.path)])
        for root in [global, custom] {
            do { _ = try await store.request(.read(directory: root.path, file: "AGENTS.md"), state: state); Issue.record("Global instructions were exposed as a project") }
            catch let error as ProjectFileError { #expect(error.code == "global_settings") }
            #expect(try Data(contentsOf: root.appendingPathComponent("AGENTS.md")) == Data("global instructions".utf8))
        }
    }

    @Test func failedHistoryPersistenceRetriesOnTheNextRequest() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let registry = scratch.dir.appendingPathComponent("projects.json")
        let store = ProjectSettingsStore(historyURL: registry, home: scratch.dir,
                                         sessions: scratch.dir.appendingPathComponent("sessions"))
        let one = Space(name: "one", path: scratch.dir.appendingPathComponent("one").path)
        let two = Space(name: "two", path: scratch.dir.appendingPathComponent("two").path)
        _ = try await store.request(.list(), state: ShepherdState(spaces: [one]))
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        do { _ = try await store.request(.list(), state: ShepherdState(spaces: [one, two])); Issue.record("Writing to a directory succeeded") }
        catch { }
        try FileManager.default.removeItem(at: registry)
        _ = try await store.request(.list(), state: ShepherdState(spaces: [one, two]))
        let reloaded = ProjectSettingsStore(historyURL: registry, home: scratch.dir, sessions: scratch.dir.appendingPathComponent("sessions"))
        guard case .listing(let listing) = try await reloaded.request(.list(), state: ShepherdState()) else { Issue.record("Missing listing"); return }
        let names = listing.projects.map(\.name)
        #expect(names == ["one", "two"])
    }

    @Test func projectAppendInstructionsAndCommentedPiSettingsUseTheLocationsPiReads() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let root = scratch.dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = ShepherdState(spaces: [Space(name: "project", path: root.path)])
        let store = scratch.server.projects
        _ = try await store.request(.save(directory: root.path, file: ".pi/APPEND_SYSTEM.md", text: "Project only\n", expected: nil), state: state)
        #expect(try String(contentsOf: root.appendingPathComponent(".pi/APPEND_SYSTEM.md"), encoding: .utf8) == "Project only\n")
        let settings = "\u{feff}{\n // Keep local defaults\n \"defaultProvider\": \"anthropic\"\n}\n"
        _ = try await store.request(.save(directory: root.path, file: ".pi/settings.json", text: settings, expected: nil), state: state)
        #expect(try Data(contentsOf: root.appendingPathComponent(".pi/settings.json")) == Data(settings.utf8))
        do { _ = try await store.request(.save(directory: root.path, file: "APPEND_SYSTEM.md", text: "wrong location", expected: nil), state: state); Issue.record("Ineffective append path admitted") }
        catch let error as ProjectFileError { #expect(error.code == "invalid_file") }
    }
}
