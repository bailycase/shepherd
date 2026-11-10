import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A Project the background host owns places work on a paired Mac through this Mac's app, which
/// holds the connection, as the app's own Projects did in process: only that exact host and
/// binding, and with the app quit it says to open it.
@Suite("Project placement from the background host", .mainActorExclusive)
@MainActor
struct LocalHostPlacementTests {
    @Test func aHostOwnedProjectPlacesWorkOnAPairedMacThroughTheApp() async throws {
        let s = try await LocalHostRuntimeTests.setUp()
        defer { s.stop() }
        let executor = try AppHarness()
        defer { executor.stop() }
        executor.settings.projectsEnabled = true
        try Data(#"{"model":{"provider":"stub","id":"model-a"}}"#.utf8).write(to: executor.dir.appendingPathComponent("stub-pi-startup.json"))
        _ = try await executor.start()
        let remoteSpace = Space(name: "acme-web on build-01", path: executor.dir.path)
        try await executor.server.addSpace(remoteSpace)
        let tokenURL = executor.dir.appendingPathComponent("placement-token")
        let port = try executor.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        // The app pairs with build-01; the host hears of it and lists it with its Space.
        s.hosts.addHost(name: "build-01", host: "127.0.0.1", port: port, token: token)
        let paired = try #require(s.hosts.pairedConnections.first)
        let host = ProjectHostReference.remote(hostID: paired.id, bindingID: paired.config.bindingID)
        let server = s.host.server
        try await eventuallyAsync("the host to know the app's paired Mac", timeout: .seconds(30)) {
            await server.appProjectExecutors().contains { $0.reference == host && $0.spaces?.contains { $0.id == remoteSpace.id } == true }
        }
        guard case .hosts(let options) = try await s.runtime.coordinator.perform(.hosts) else { Issue.record("no hosts"); return }
        #expect(options.map(\.name).dropFirst() == ["build-01"])

        let id = ProjectID()
        func project() -> Project { server.state.projects.first { $0.id == id }! }
        _ = try await server.logicalProjects(.create(projectID: id, name: "Checkout revamp", goal: "", linkedSpaceIDs: [s.space.id]))
        _ = try await server.logicalProjects(.settings(projectID: id, expectedRevision: project().revision,
                                                       settings: .init(threadModel: "stub/model-a", allowedHosts: [.local, host])))
        _ = try await server.logicalProjects(.linkSpace(projectID: id, expectedRevision: project().revision, spaceID: remoteSpace.id, host: host))
        func assign(_ prompt: String) async throws {
            _ = try await s.runtime.coordinator.perform(projectID: id, expectedRevision: project().revision,
                request: .assign(operationID: UUID(), spaceID: remoteSpace.id, title: "Assigned work", prompt: prompt, host: host))
        }
        try await assign("hello")
        try await eventuallyOnMain("build-01 to run the host's task", timeout: .seconds(30)) {
            executor.server.state.projectExecutions.contains { $0.key.ownerID == project().ownerID }
        }
        #expect(server.state.agents.allSatisfy { $0.spaceID != remoteSpace.id }, "the work runs on build-01, not here")
        // build-01's settlement reaches the host through the app's connection.
        try await eventuallyOnMain("the task to settle on the host", timeout: .seconds(30)) { project().tasks.first?.phase == .settled }
        let task = try #require(project().tasks.first)
        let key = try #require(task.executionAssignment?.key)

        // Another binding to the same Mac is never served, and nothing falls back.
        let executions = executor.server.state.projectExecutions.count
        await #expect(throws: (any Error).self) {
            _ = try await s.runtime.coordinator.place(host: .remote(hostID: paired.id, bindingID: UUID()), request: .snapshot(key: key, watch: false))
        }
        #expect(executor.server.state.projectExecutions.count == executions)

        // With the app gone, placing on another Mac says to open it.
        for connection in s.hosts.allConnections { s.hosts.removeHost(id: connection.id) }
        try await eventuallyAsync("the host to forget the app's paired Mac") { await server.appProjectExecutors().isEmpty }
        do {
            try await assign("hello again")
            Issue.record("placed with the app quit")
        } catch let error as LogicalProjectsError {
            #expect(error.code == "app_closed" && error.description == SessionServer.appClosedForPlacement)
        }
        do {
            _ = try await s.runtime.coordinator.place(host: host, request: .snapshot(key: key, watch: false))
            Issue.record("read with the app quit")
        } catch let error as LogicalProjectsError {
            #expect(error.code == "app_closed")
        }
    }
}
