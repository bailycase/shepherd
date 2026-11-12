import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// An agent on the stub pi in a scratch repository, partway through a scripted turn: it names
/// `writes` as its own edits, then holds until `release()`. The test changes files meanwhile, as
/// bash would, and acts as the person; the turn's record is read once it is released.
@MainActor
struct HeldTurn {
    let app: AppHarness
    let vm: ShepherdViewModel
    let repo: URL
    let agentID: AgentID

    private var gate: URL { repo.appendingPathComponent("gate-turn") }

    /// Starts the agent in `repo` and sends it the scripted prompt, once the engine has the turn.
    /// `writes` are the paths its `write` calls name; the files themselves are the test's to change.
    static func start(in repo: URL, writes: [String] = []) async throws -> HeldTurn {
        try "project-script.json\ngate-*\n".write(to: repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let calls = writes.map { path -> [String: Any] in
            ["tool": ["toolName": "write", "arguments": ["path": path, "content": "x\n"], "content": [["type": "text", "text": "ok"]]]]
        }
        let script: [String: Any] = ["prompts": ["edit": calls + [["wait": "gate-turn"]]]]
        try JSONSerialization.data(withJSONObject: script).write(to: repo.appendingPathComponent("project-script.json"))

        let app = try AppHarness()
        // A commit from review writes its message from the file list, never with a model.
        app.settings.worktreeGeneratePRDescription = false
        let space = Fixture.space(path: repo.path)
        let agent = try await app.liveAgent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let id = agent.agent.id
        var ready: NativeThreadSnapshot?
        try await eventuallyAsync("the agent to take a prompt", timeout: .seconds(30)) {
            guard case .snapshot(let value)? = try? await app.server.nativeThread(agentID: id, request: .snapshot()),
                  !value.piSessionID.isEmpty, value.supportedActions.contains("send") else { return false }
            ready = value
            return true
        }
        let snapshot = try #require(ready)
        let sent = try await app.server.nativeThread(agentID: id, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: "edit",
            delivery: .followUp, images: nil))
        if case .failure(let code, let message) = sent { throw TimedOut(what: "the prompt to be accepted (\(code): \(message))") }
        let held = HeldTurn(app: app, vm: vm, repo: repo, agentID: id)
        try await eventuallyOnMain("the turn to start") { held.turn?.state == .running }
        // The stub's write calls are played before it holds: the engine has heard them.
        try await eventuallyAsync("the write calls to be done") {
            guard case .snapshot(let value)? = try? await app.server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return (value.provisional + value.messages).filter { $0.toolName == "write" && $0.status == "complete" }.count >= writes.count
        }
        return held
    }

    var turn: ChangesTurn? { app.server.changes.turns(agentID: agentID).last }

    /// Lets the held turn finish and waits for its record.
    func release() async throws -> ChangesTurn {
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        try await eventuallyOnMain("the turn to be recorded") { turn?.state == .ready }
        return try #require(turn)
    }

    func close() {
        app.stop()
        try? FileManager.default.removeItem(at: repo)
    }
}
