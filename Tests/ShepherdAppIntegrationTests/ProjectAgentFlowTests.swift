import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Project agent flow", .mainActorExclusive)
@MainActor
struct ProjectAgentFlowTests {
    private func ask(_ message: ExtensionMessage, app: AppHarness) async throws -> ExtensionReply {
        let client = try ExtensionClient(path: app.scratch.socketPath)
        try client.send(message)
        return try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
    }

    @Test func registrationUpdatesLiveSidebarAndSettingsWithoutSelectingOrStartingThreads() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = getpid()
        app.server.extensionPeerCheck = { _, peer in peer == own }
        let parent = Fixture.space("Existing", path: app.dir.path)
        let agent = Fixture.agent("requester", in: parent, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let directory = app.dir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs = app.server.state.tabs

        let reply = try await ask(.registerProject(id: 1, agentID: agent.agent.id, path: directory.path, name: "psp-hub"), app: app)
        guard case .projectResult(1, let value?, true) = reply else {
            Issue.record("Unexpected registration reply: \(reply)"); return
        }
        #expect(value.name == "psp-hub")
        #expect(value.path == directory.resolvingSymlinksInPath().path)
        #expect(app.server.state.spaces == [value, parent])
        #expect(vm.state.spaces == app.server.state.spaces)
        #expect(vm.sidebarTree.projects.contains { $0.name == "psp-hub" })
        #expect(vm.projects.rows.contains { $0.project.name == "psp-hub" && $0.project.directory == value.path })
        #expect(vm.selectedAgentID == agent.agent.id)
        #expect(app.server.state.tabs == tabs)
        #expect(app.server.state.agents.count == 1)

        let alias = app.dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let duplicate = try await ask(.registerProject(id: 2, agentID: agent.agent.id, path: alias.path + "/.", name: "Do not rename"), app: app)
        #expect(duplicate == .projectResult(id: 2, space: value, created: false))
        #expect(app.server.state.spaces == [value, parent])

        // Force a stale local presentation, then refresh from the live server, not state.json.
        vm.adopt(Fixture.state(spaces: [parent], agents: [agent]))
        let refreshed = try await ask(.refreshProjects(id: 3, agentID: agent.agent.id), app: app)
        #expect(refreshed == .projectResult(id: 3, space: nil, created: false))
        #expect(vm.state.spaces == app.server.state.spaces)
        #expect(vm.sidebarTree.projects.contains { $0.name == "psp-hub" })
        #expect(vm.projects.rows.contains { $0.project.name == "psp-hub" })
    }

    @Test func invalidRegistrationAndUnownedConnectionsCannotChangeProjects() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = getpid()
        app.server.extensionPeerCheck = { _, peer in peer == own }
        let parent = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("requester", in: parent, order: 0)
        _ = try await app.start(with: Fixture.state(spaces: [parent], agents: [agent]))
        let file = app.dir.appendingPathComponent("file")
        try Data().write(to: file)
        for (path, name) in [("relative", "Name"), (file.path, "Name"), (app.dir.path + "/missing", "Name"), (app.dir.path, "   "), (app.dir.path, "bad\nname")] {
            let reply = try await ask(.registerProject(id: 4, agentID: agent.agent.id, path: path, name: name), app: app)
            guard case .error(4, _, _) = reply else { Issue.record("Expected invalid input error, got \(reply)"); continue }
        }
        #expect(app.server.state.spaces == [parent])
        app.server.extensionPeerCheck = { _, _ in false }
        let refused = try await ask(.refreshProjects(id: 5, agentID: agent.agent.id), app: app)
        guard case .error(5, _, _) = refused else { Issue.record("Unowned connection was accepted"); return }
        #expect(app.server.state.spaces == [parent])
    }

    @Test func refreshKeepsHistorySeparateAndSettingsAddUsesTheSameRegistration() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: []))
        let cached = app.dir.appendingPathComponent("cached")
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        let history = Fixture.space("History only", path: cached.path)
        _ = try await app.server.projects.request(.list(offset: 0), state: Fixture.state(spaces: [parent, history], agents: []))
        _ = try await vm.handleProjectRequest(.refresh)
        #expect(vm.projects.rows.contains { $0.project.name == "History only" })
        #expect(vm.state.spaces == [parent])
        let host = try #require(vm.projectsSources.first)
        try await vm.addSettingsProject(path: cached.path, host: host)
        try await vm.addSettingsProject(path: cached.path + "/.", host: host)
        #expect(app.server.state.spaces.count == 2)
        #expect(vm.state.spaces == app.server.state.spaces)
    }
}
