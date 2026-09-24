import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// An agent's `agent_delete` over the real extension socket: the request waits in the Delete
/// agent dialog, only its destructive button deletes, and deleting follows Delete Agent, so
/// the target's processes stop while its worktree and branch stay.
@Suite("Peer deletion", .mainActorExclusive)
@MainActor
struct AgentPeerDeletionTests {
    private struct Scene {
        let app: AppHarness
        let vm: ShepherdViewModel
        let sandbox: WorktreeSandbox
        let requester: PeerRequester
        let caller: AgentFixture
        let target: AgentFixture
        /// The target's pi and the terminal pane beside it.
        let sessions: [SessionID]
        let checkout: String
    }

    /// A requesting agent and a live worktree agent (stub pi plus a terminal pane) with
    /// uncommitted work in its checkout.
    private func makeScene() async throws -> Scene {
        let app = try AppHarness()
        let sandbox = try WorktreeSandbox()
        let checkout = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/keep-this")
        try "keep work".write(toFile: checkout + "/uncommitted.txt", atomically: true, encoding: .utf8)
        let space = Fixture.space("proj", path: sandbox.repo.path)
        let caller = Fixture.agent("requesting agent", in: space, order: 0)
        var target = try await app.liveAgent("target agent", in: space, order: 1)
        let terminal = try await app.server.createSession(params: CreateSessionParams(cwd: checkout, command: ["/bin/sh", "-c", "sleep 60"]))
        let terminalPane = LeafPane(sessionID: terminal.id, cwd: checkout)
        target.tab.layout = .split(axis: .vertical, ratio: 0.5, first: .leaf(target.piPane), second: .leaf(terminalPane))
        target.auxiliary = [terminalPane]
        target.agent.worktreeBranch = "worktree/keep-this"
        target.agent.worktreePath = checkout
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [caller, target]))
        let requester = try PeerRequester(path: app.scratch.socketPath, agentID: caller.agent.id)
        return Scene(app: app, vm: vm, sandbox: sandbox, requester: requester, caller: caller, target: target,
                     sessions: [try #require(target.piPane.sessionID), terminal.id], checkout: checkout)
    }

    private func stop(_ scene: Scene) {
        scene.requester.client.closeConnection()
        scene.app.stop()
        scene.sandbox.remove()
    }

    private func awaitDialog(_ vm: ShepherdViewModel) async throws -> ShepherdViewModel.PeerDeleteConfirmation {
        try await eventuallyOnMain("the Delete agent dialog") { vm.peerDeleteConfirmation != nil }
        return try #require(vm.peerDeleteConfirmation)
    }

    private func allAlive(_ scene: Scene) async -> Bool {
        for session in scene.sessions where await scene.app.server.sessionInfo(sessionID: session)?.isAlive != true { return false }
        return true
    }

    @Test func aDeletionRequestWaitsForTheUserAndCancelKeepsTheAgent() async throws {
        let scene = try await makeScene()
        defer { stop(scene) }

        try scene.requester.requestDeletion(id: 1, of: scene.target.agent.id)
        let dialog = try await awaitDialog(scene.vm)

        #expect(dialog.agent.name == "target agent" && dialog.senderName == "requesting agent")
        #expect(scene.app.server.state.agents.count == 2)
        #expect(await allAlive(scene))
        scene.vm.cancelPeerDeletion(requestID: dialog.requestID)
        #expect(try await scene.requester.reply() == .agentResult(id: 1, result: .init(text: "user cancelled deletion; agent kept", code: "cancelled")))
        #expect(scene.vm.peerDeleteConfirmation == nil)
        #expect(scene.app.server.state.agents.count == 2)
    }

    /// The sheet's binding: a dismissal that is not the destructive button is a Cancel, so the
    /// requesting agent always hears back.
    @Test func dismissingTheDialogCountsAsCancel() async throws {
        let scene = try await makeScene()
        defer { stop(scene) }
        try scene.requester.requestDeletion(id: 1, of: scene.target.agent.id)
        _ = try await awaitDialog(scene.vm)

        scene.vm.peerDeleteItem = nil

        guard case .agentResult(1, let result) = try await scene.requester.reply() else { Issue.record("no answer"); return }
        #expect(result.code == "cancelled")
        #expect(scene.app.server.state.agents.count == 2)
    }

    /// Cancelling the tool revokes the dialog's token: the dialog closes, and buttons captured
    /// by it neither delete nor dismiss the dialog of a newer request.
    @Test func aCancelledRequestClosesTheDialogAndItsStaleButtonsDoNothing() async throws {
        let scene = try await makeScene()
        defer { stop(scene) }
        try scene.requester.requestDeletion(id: 2, of: scene.target.agent.id)
        let revoked = try await awaitDialog(scene.vm).requestID

        try scene.requester.cancel(id: 2)
        #expect(try await scene.requester.reply() == .agentResult(id: 2, result: .init(text: "request cancelled", code: "cancelled")))
        try await eventuallyOnMain("the dialog to close") { scene.vm.peerDeleteConfirmation == nil }
        #expect(await !scene.app.server.claimAgentDeletion(revoked))

        try scene.requester.requestDeletion(id: 3, of: scene.target.agent.id)
        let current = try await awaitDialog(scene.vm).requestID
        #expect(current != revoked)
        await scene.vm.confirmPeerDeletion(requestID: revoked)
        scene.vm.cancelPeerDeletion(requestID: revoked)
        #expect(scene.vm.peerDeleteConfirmation?.requestID == current)
        #expect(scene.app.server.state.agents.count == 2)
        #expect(await allAlive(scene))
    }

    @Test func anotherRequestWhileTheDialogIsUpIsBusy() async throws {
        let scene = try await makeScene()
        defer { stop(scene) }
        try scene.requester.requestDeletion(id: 1, of: scene.target.agent.id)
        let first = try await awaitDialog(scene.vm)

        try scene.requester.requestDeletion(id: 2, of: scene.target.agent.id)

        #expect(try await scene.requester.reply() == .agentResult(
            id: 2, result: .init(text: "another deletion is awaiting user confirmation", code: "busy")))
        #expect(scene.vm.peerDeleteConfirmation?.requestID == first.requestID)
    }

    /// Confirming is the dialog's destructive button, never an extension boolean.
    @Test func confirmingDeletesThroughDeleteAgentAndKeepsTheWorktree() async throws {
        let scene = try await makeScene()
        defer { stop(scene) }
        try scene.requester.requestDeletion(id: 3, of: scene.target.agent.id)
        let dialog = try await awaitDialog(scene.vm)

        await scene.vm.confirmPeerDeletion(requestID: dialog.requestID)

        guard case .agentResult(3, let result) = try await scene.requester.reply() else { Issue.record("no answer"); return }
        #expect(result.code == nil)
        #expect(scene.app.server.state.agents.map(\.id) == [scene.caller.agent.id])
        #expect(!scene.app.server.state.tabs.contains { $0.id == scene.target.tab.id })
        let server = scene.app.server, sessions = scene.sessions
        try await eventuallyAsync("the target's pi and terminal to stop") {
            for session in sessions where await server.sessionInfo(sessionID: session)?.isAlive == true { return false }
            return true
        }
        #expect(try String(contentsOfFile: scene.checkout + "/uncommitted.txt", encoding: .utf8) == "keep work")
        #expect(try scene.sandbox.branches().contains("worktree/keep-this"))
    }
}

/// The requesting agent's panes connection, read off the main actor (which answers it).
private final class PeerRequester: @unchecked Sendable {
    let client: ExtensionClient
    let agentID: AgentID

    init(path: String, agentID: AgentID) throws {
        client = try ExtensionClient(path: path)
        self.agentID = agentID
        try client.send(.helloAgent(agentID: agentID))
    }

    func requestDeletion(id: Int, of target: AgentID) throws {
        try client.send(.coordinateAgent(id: id, agentID: agentID, targetAgentID: target, request: .init(operation: .delete)))
    }

    func cancel(id: Int) throws {
        try client.send(.cancelAgentRequest(id: id, agentID: agentID))
    }

    func reply() async throws -> ExtensionReply {
        try await Task.detached { try self.client.readReply(timeout: .seconds(20)) }.value
    }
}
