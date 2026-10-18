import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Thread move flow", .mainActorExclusive)
@MainActor
struct ThreadMoveFlowTests {
    @Test func theAgentToolMovesAThreadAndRefusesSelfMoves() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Space(name: "Parent", path: app.dir.path)
        let child = Space(name: "Child", path: app.dir.path + "/child", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let caller = Fixture.agent("Caller", in: parent)
        let target = Fixture.agent("Target", in: parent, order: 1)
        _ = try await app.start(with: Fixture.state(spaces: [parent, child], agents: [caller, target]))
        let peer = try ThreadMovePeer(path: app.scratch.socketPath)
        let client = peer.client
        defer { client.closeConnection() }
        try client.send(.helloAgent(agentID: caller.agent.id))
        try client.send(.moveAgent(id: 1, agentID: caller.agent.id, targetAgentID: target.agent.id, spaceID: child.id))
        let reply = try await peer.reply()
        #expect(reply == .ok(id: 1))
        #expect(app.server.state.agents.first { $0.id == target.agent.id }?.spaceID == child.id)
        try client.send(.moveAgent(id: 2, agentID: caller.agent.id, targetAgentID: caller.agent.id, spaceID: child.id))
        let refusal = try await peer.reply()
        guard case .error(2, "self_control", _) = refusal else { Issue.record("Self move was not refused"); return }
    }

    @Test func movingALiveIdleThreadRestartsItsProcessInTheDestinationFolder() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Space(name: "Parent", path: app.dir.path)
        let child = Space(name: "Child", path: app.dir.path + "/child", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        var fixture = Fixture.agent("Move me", in: parent)
        fixture.agent.piSessionID = "stub-session"
        #expect(PiSessionFile.seedIfMissing(sessionID: "stub-session", cwd: parent.path, sessionsRoot: app.server.pi.sessionsRoot))
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child], agents: [fixture]), restoringAgents: true)
        _ = try await app.readyThread(fixture.agent.id)
        let old = try #require(app.server.state.tabs.first?.layout.firstLeaf.sessionID)
        try await vm.moveThread(fixture.agent.id, to: child.id)
        try await eventuallyAsync("the moved thread to restart in the destination") {
            guard let next = app.server.state.tabs.first?.layout.firstLeaf.sessionID, next != old,
                  let info = await app.server.sessionInfo(sessionID: next) else { return false }
            return info.isAlive && info.cwd == PiSessionFolder.realPath(child.path)
        }
        #expect(await app.server.sessionInfo(sessionID: old)?.isAlive != true, "The old process is stopped or retired after replacement")
        #expect(app.server.state.agents.first?.id == fixture.agent.id)
        #expect(PiSessionFile.exists(sessionID: "stub-session", cwd: child.path, sessionsRoot: app.server.pi.sessionsRoot))
    }

    @Test func droppingAThreadOntoAChildUsesTheSameMoveAndRejectsForeignPayloads() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Space(name: "Parent", path: app.dir.path)
        let child = Space(name: "Child", path: app.dir.path + "/child", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let target = Fixture.agent("Target", in: parent)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child], agents: [target]))
        vm.settings.sidebarStyle = .projects
        #expect(!vm.dropThread(["/tmp/file"], on: .local(child.id)))
        #expect(!vm.dropThread([], on: .local(child.id)))
        let payload = try #require(ThreadMoveDrag(.local(target.agent.id))?.text)
        #expect(!vm.dropThread([payload, payload], on: .local(child.id)))
        #expect(vm.dropThread([payload], on: .local(child.id)))
        try await eventuallyOnMain("the dropped thread to move") { vm.state.agents.first?.spaceID == child.id }
        #expect(vm.sidebarTree.project(holding: .local(target.agent.id))?.space == child.id)
        #expect(vm.selectedAgentID == target.agent.id)
        #expect(vm.selectedSpaceID == child.id)
        #expect(vm.activeTabID == target.tab.id)
        #expect(vm.dropThread([payload], on: .local(parent.id)))
        try await eventuallyOnMain("the child thread to return to its parent space") { vm.state.agents.first?.spaceID == parent.id }
    }

    @Test func aRemoteMoveRunsOnItsOwnerAndCannotDropIntoALocalSpace() async throws {
        let app = try AppHarness()
        let host = try RemoteHostHarness()
        defer { app.stop(); host.stop() }
        let source = Space(name: "Host source", path: host.host.dir.path)
        let destination = Space(name: "Host child", path: source.path + "/child", parentID: source.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: destination.path, withIntermediateDirectories: true)
        let agent = Fixture.agent("Remote thread", in: source)
        _ = try await host.host.start(with: Fixture.state(spaces: [source, destination], agents: [agent]))
        let local = Space(name: "Local only", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [local], agents: []))
        let connection = try await host.connect(app.remoteHosts)
        #expect(connection.supportsThreadMove)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let payload = try #require(ThreadMoveDrag(.remote(ref))?.text)
        #expect(!vm.dropThread([payload], on: .local(local.id)))
        try await app.remoteHosts.agentAction(ref, action: .move(spaceID: destination.id))
        try await eventuallyOnMain("the owner to publish the moved remote thread") {
            connection.state.agents.first?.spaceID == destination.id
        }
        #expect(host.host.server.state.tabs.first?.spaceID == destination.id)
        #expect(app.server.state.agents.isEmpty)
    }

    @Test func theMoveMenuUsesTheRealControls() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressMove() }
        }
        expectScenarioCompleted(result)
    }

    private static func pressMove() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Space(name: "Parent", path: app.dir.path)
        let child = Space(name: "Child", path: app.dir.path + "/child", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let target = Fixture.agent("Target", in: parent)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child], agents: [target]))
        let menu = OffscreenWindow(size: CGSize(width: 300, height: 150), dark: true,
                                  VStack { ThreadMoveMenu(vm: vm, row: .local(target.agent.id)).items })
        defer { menu.close() }
        let control = try menu.press("Child")
        #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the menu move to finish") { vm.state.agents.first?.spaceID == child.id }
        try menu.press("Parent")
        try await eventuallyOnMain("the menu to move back") { vm.state.agents.first?.spaceID == parent.id }
        var busy = try #require(app.server.state.agents.first)
        busy.status = .working
        try await app.server.updateAgent(busy)
        try menu.press("Child")
        try await eventuallyOnMain("the active-thread refusal") { vm.remoteActionError != nil }
        #expect(app.server.state.agents.first?.spaceID == parent.id)
        let message = try #require(vm.remoteActionError)
        let error = OffscreenWindow(size: CGSize(width: 540, height: 280), dark: true,
                                    ActionErrorDialog(message: message) { vm.remoteActionError = nil })
        defer { error.close() }
        let dismiss = try error.press("OK")
        #expect(ControlPress.undersized([dismiss], minimum: .desktop).isEmpty)
        #expect(vm.remoteActionError == nil)
    }
}

/// One ordered writer and one off-main reader, as the other peer socket fixtures use.
private final class ThreadMovePeer: @unchecked Sendable {
    let client: ExtensionClient
    init(path: String) throws { client = try ExtensionClient(path: path) }
    func reply() async throws -> ExtensionReply {
        try await Task.detached { try self.client.readReply() }.value
    }
}
