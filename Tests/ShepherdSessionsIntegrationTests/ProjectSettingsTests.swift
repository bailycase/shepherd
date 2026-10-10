import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project settings files", .integrationTimeLimit)
struct ProjectSettingsTests {
    @Test func projectFilesAreScopedConflictCheckedAndRetainedAfterWorkspaceDeletion() async throws {
        let directory = try makeScratchDirectory("srv")
        // Project listing imports old pi sessions: do not share earlier suites' session home.
        let pi = PiSetup(engine: PiSetup.app.engine, home: directory.appendingPathComponent("pi"))
        let scratch = try ScratchServer(dir: directory, pi: pi)
        defer { scratch.stop() }
        let fm = FileManager.default
        let first = scratch.dir.appendingPathComponent("one"), second = scratch.dir.appendingPathComponent("two")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: first.appendingPathComponent("AGENTS.md"))
        try Data("second".utf8).write(to: second.appendingPathComponent("AGENTS.md"))
        let state = ShepherdState(spaces: [Space(name: "one", path: first.path, sidebarHidden: true), Space(name: "two", path: second.path)])
        try await scratch.server.putState(state)
        let store = scratch.server.projects
        guard case .listing(let listing) = try await store.request(.list(), state: state) else { Issue.record("Expected projects"); return }
        #expect(listing.projects.map(\.directory) == [first.path, second.path])
        #expect(listing.projects.allSatisfy { $0.summary == "AGENTS.md only" })
        _ = try await store.request(.save(directory: first.path, file: "AGENTS.md", text: "new", expected: "first"), state: state)
        #expect(try String(contentsOf: second.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "second")
        await #expect(throws: ProjectFileError.self) {
            _ = try await store.request(.save(directory: first.path, file: "AGENTS.md", text: "stale", expected: "first"), state: state)
        }
        #expect(try String(contentsOf: first.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "new")
        _ = try await store.request(.save(directory: first.path, file: ".shepherd/settings.json", text: "{\"unknownOption\":true}", expected: nil), state: state)
        #expect(try String(contentsOf: first.appendingPathComponent(".shepherd/settings.json"), encoding: .utf8).contains("unknownOption"))
        await #expect(throws: ProjectFileError.self) {
            _ = try await store.request(.save(directory: first.path, file: ".shepherd/settings.json", text: "[]", expected: "{\"unknownOption\":true}"), state: state)
        }
        try await scratch.server.putState(ShepherdState())
        let reopened = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("projects.json"), home: scratch.dir, sessions: scratch.dir.appendingPathComponent("no-sessions"))
        guard case .listing(let retained) = try await reopened.request(.list(), state: ShepherdState()) else { Issue.record("Expected retained history"); return }
        #expect(retained.projects.map(\.directory) == [first.path, second.path])
    }

    @Test func traversalSymlinksUnknownDirectoriesAndOversizedFilesAreRefused() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let fm = FileManager.default, root = scratch.dir.appendingPathComponent("project"), outside = scratch.dir.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("settings.json"))
        try fm.createSymbolicLink(at: root.appendingPathComponent(".shepherd"), withDestinationURL: outside)
        let state = ShepherdState(spaces: [Space(name: "project", path: root.path)])
        let store = scratch.server.projects
        for request in [RemoteProjectsRequest.read(directory: root.path, file: "../outside/settings.json"),
                        .read(directory: root.path, file: ".shepherd/auth.json"),
                        .read(directory: outside.path, file: "AGENTS.md"),
                        .read(directory: root.path, file: ".shepherd/settings.json"),
                        .save(directory: root.path, file: ".shepherd/settings.json", text: "{}", expected: nil)] {
            await #expect(throws: ProjectFileError.self) { _ = try await store.request(request, state: state) }
        }
        #expect(try String(contentsOf: outside.appendingPathComponent("settings.json"), encoding: .utf8) == "untouched")
        try Data(repeating: 65, count: ProjectSettingsStore.fileLimit + 1).write(to: root.appendingPathComponent("AGENTS.md"))
        await #expect(throws: ProjectFileError.self) { _ = try await store.request(.read(directory: root.path, file: "AGENTS.md"), state: state) }
        try fm.removeItem(at: root.appendingPathComponent("AGENTS.md"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("AGENTS.md"), withDestinationURL: outside.appendingPathComponent("settings.json"))
        await #expect(throws: ProjectFileError.self) { _ = try await store.request(.read(directory: root.path, file: "AGENTS.md"), state: state) }
    }

    @Test func aRemoteClientEditsOnlyTheNamedHostProjectAndOldHostsRequireAnUpdate() async throws {
        // Startup imports old pi sessions before this test adds its named project.
        let pi = PiSetup(engine: PiSetup.app.engine, home: try makeScratchDirectory("rpi"))
        let host = try RemoteHost(pi: pi)
        defer { host.stop() }
        let directory = host.host.dir.appendingPathComponent("remote-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await host.server.putState(ShepherdState(spaces: [Space(name: "remote", path: directory.path)]))
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.projectsCapability))
        guard case .listing(let listing) = try await client.projects(.list()) else { Issue.record("Expected remote list"); return }
        #expect(listing.projects.first?.name == "remote")
        _ = try await client.projects(.save(directory: directory.path, file: "AGENTS.md", text: "remote only", expected: nil))
        #expect(try String(contentsOf: directory.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "remote only")
        let old = try RemoteHost()
        defer { old.stop() }
        old.server.advertisedCapabilities = []
        let oldClient = try await old.typed()
        defer { oldClient.disconnect() }
        await #expect(throws: RemoteHostClientError.self) { _ = try await oldClient.projects(.list()) }
    }
}
