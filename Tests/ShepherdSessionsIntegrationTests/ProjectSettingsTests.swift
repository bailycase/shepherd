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

    @Test(arguments: [nil, ["projects.v1"]] as [[String]?])
    func legacyClientsCannotReadMigrateEditOrApproveProjectsButKeepOtherRemoteFeatures(_ capabilities: [String]?) async throws {
        let root = try makeScratchDirectory("pgate"), fm = FileManager.default
        let support = root.appendingPathComponent("support"), project = root.appendingPathComponent("project")
        let config = project.appendingPathComponent(".pi")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("pi"), withIntermediateDirectories: true)
        let original = #"{"mcpServers":{"tools":{"command":"tools","enabled":false,"future":"keep"}}}"#
        try Data(original.utf8).write(to: config.appendingPathComponent("mcp.json"))
        try Data("instructions".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let trust = support.appendingPathComponent("pi/trust.json")
        let denial = try JSONEncoder().encode([project.path: false])
        try denial.write(to: trust)
        let state = ShepherdState(spaces: [Space(name: "existing", path: project.path)])
        try JSONEncoder().encode(state).write(to: support.appendingPathComponent("state.json"))
        let pi = PiSetup(engine: PiSetup.app.engine, home: support.appendingPathComponent("pi"), userHome: root.appendingPathComponent("home").path)
        let host = try ScratchServer(dir: support, pi: pi)
        defer { host.stop() }
        let tokenURL = support.appendingPathComponent("token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
        let old = try RawRemote(port: port)
        defer { old.closeConnection() }
        let offered = try await old.hello(token: token, capabilities: capabilities)
        #expect(offered.contains("projects.v2") && !offered.contains("projects.v1"))
        // Drain the startup snapshot without preparing any pending project.
        let current = RemoteHostClient()
        defer { current.disconnect() }
        _ = try await current.connect(host: "127.0.0.1", port: port, token: token, clientName: "current")
        try await host.server.projects.prepareProjectConfiguration(for: root.appendingPathComponent("unrelated").path)
        let ledger = support.appendingPathComponent("project-config-migration.json")
        let pending = try Data(contentsOf: ledger)
        let requests: [RemoteProjectsRequest] = [
            .list(), .files(directory: project.path), .context(directory: project.path),
            .read(directory: project.path, file: ".pi/mcp.json"),
            .read(directory: project.path, file: ".shepherd/mcp.json"), .open(directory: project.path, file: ".shepherd/SYSTEM.md"),
            .save(directory: project.path, file: "AGENTS.md", text: "wrong", expected: "instructions"),
            .save(directory: project.path, file: ".pi/mcp.json", text: "{}", expected: original),
            .save(directory: project.path, file: ".shepherd/mcp.json", text: "{}", expected: nil),
            .mcp(directory: project.path, file: ".shepherd/mcp.json", action: .credentials),
            .mcp(directory: project.path, file: ".pi/mcp.json", action: .approveProject),
            .mcp(directory: project.path, file: ".shepherd/mcp.json", action: .approveProject),
            .mcp(directory: project.path, file: ".shepherd/mcp.json", action: .login(server: "tools")),
        ]
        for (index, request) in requests.enumerated() {
            let id = index + 10
            try old.send(.projects(id: id, request: request))
            #expect(try await old.next() == .error(id: id, code: "update_required", message: "Update Shepherd on this client to edit this host's project configuration."))
        }
        #expect(try Data(contentsOf: ledger) == pending)
        #expect(try Data(contentsOf: trust) == denial)
        #expect(try String(contentsOf: config.appendingPathComponent("mcp.json"), encoding: .utf8) == original)
        #expect(try String(contentsOf: project.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "instructions")
        #expect(!fm.fileExists(atPath: project.appendingPathComponent(".shepherd").path))
        try old.send(.stateFetch(id: 100))
        #expect(try await old.next() == .state(id: 100, state: host.server.state))
        guard case .files(let files) = try await current.projects(.files(directory: project.path)) else { Issue.record("Current client could not open project"); return }
        #expect(files.contains { $0.path == ".shepherd/mcp.json" } && !files.contains { $0.path == ".pi/mcp.json" })
        _ = try await current.projects(.save(directory: project.path, file: ".shepherd/mcp.json", text: "{}", expected: original))
        #expect(try String(contentsOf: project.appendingPathComponent(".shepherd/mcp.json"), encoding: .utf8) == "{}")
        // An editor opened by an older client stays fenced after a current client prepares the project.
        try old.send(.projects(id: 101, request: .mcp(directory: project.path, file: ".shepherd/mcp.json", action: .approveProject)))
        guard case .error(101, "update_required", _) = try await old.next() else { Issue.record("Old editor bypassed the fence"); return }
        #expect(try String(contentsOf: config.appendingPathComponent("mcp.json"), encoding: .utf8) == original)
        #expect(try Data(contentsOf: trust) == denial)
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
        #expect(client.capabilities.contains(RemoteProtocol.projectsV2Capability))
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
