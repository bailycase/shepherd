import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Last turn and the "Edited N files" card with a real server and the stub pi working in a
/// scratch repository: the host snapshots the working tree when pi starts a run and when it
/// settles, and Undo puts back exactly what the turn changed.
@Suite("Changes turns", .integrationTimeLimit)
struct ChangesTurnTests {
    struct Turn {
        let host: ScratchServer
        let pi: PiAgent
        let repo: ChangesRepo
        var changes: ChangesService { host.server.changes }
        var agent: AgentID { pi.agent.id }

        func turns() -> [ChangesTurn] { changes.turns(agentID: agent) }
    }

    /// A repository with the user's own uncommitted edit, an agent in it, and one turn in which
    /// the agent modifies a.txt, deletes d.txt, renames c.txt to e.txt and creates new.txt.
    static func agentTurn() async throws -> Turn {
        let repo = try ChangesRepo(files: ["a.txt": "one\n", "b.txt": "bee\n", "c.txt": "a file that moves\nwith its lines\n", "d.txt": "dee\n"])
        // The stub's gates appear in its cwd; they are not the agent's work.
        try "tool-*\nsettle\ncontinue-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        try repo.write("stash-me.txt", "x\n")
        try repo.git("stash", "-u")
        try repo.write("b.txt", "bee, edited by the user\n")
        let host = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let turn = Turn(host: host, pi: pi, repo: repo)
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:1 refactor the ledger", from: idle).failureCode == nil)
        try await eventually("the turn's baseline") { turn.changes.turnStore.latest(turn.agent)?.startTree != nil }

        try repo.write("a.txt", "one\ntwo\n")
        try repo.remove("d.txt")
        try repo.move("c.txt", "e.txt")
        try repo.write("new.txt", "brand new\n")
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        try await eventually("the turn to end") { turn.turns().last?.state == .ready }
        return turn
    }

    @Test func lastTurnIsWhatTheAgentChanged() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        #expect(turn.title == "Edited 4 files" && turn.canUndo && !turn.canRedo)
        #expect(turn.prompt == "tools:1 refactor the ledger")
        #expect(Set(turn.files.map(\.path)) == ["a.txt", "d.txt", "e.txt", "new.txt"])

        let list = try await t.changes.list(agentID: t.agent, scope: .lastTurn)
        #expect(list.summary == ["A new.txt", "D d.txt", "M a.txt", "R c.txt→e.txt"], "the user's own b.txt edit is not the turn's")
        #expect(list.comparison.turn?.id == turn.id && list.title == "Last turn")
        #expect(try await t.changes.list(agentID: t.agent, scope: .turn(id: turn.id)).summary == list.summary)

        // The thread carries the turn, keyed by the message that started it.
        let snapshot = try await t.pi.snapshot("the turn in the thread") { $0.turnChanges?.last?.state == .ready }
        let user = try #require(snapshot.messages.last { $0.role == "user" })
        #expect(changesTurn(forMessageAt: user.timestamp, in: snapshot.turnChanges)?.id == turn.id)
    }

    /// Undo restores the modified, deleted and renamed files and trashes the created ones; the
    /// user's own edit, the index, HEAD, refs and the stash stay as they were. Redo reapplies it.
    @Test func undoPutsBackExactlyTheTurnAndRedoReappliesIt() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        let before = try t.repo.state()

        let undone = try await t.changes.undoTurn(agentID: t.agent, turnID: turn.id)
        #expect(undone.state == .undone && undone.canRedo && !undone.canUndo)
        #expect(undone.title == "Undid the agent’s edits to 4 files")
        #expect(t.repo.read("a.txt") == "one\n")
        #expect(t.repo.read("d.txt") == "dee\n")
        #expect(t.repo.read("c.txt") == "a file that moves\nwith its lines\n")
        #expect(t.repo.read("e.txt") == nil && t.repo.read("new.txt") == nil)
        #expect(t.repo.read("b.txt") == "bee, edited by the user\n")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: t.host.trash.path).map { String($0.split(separator: "-").last ?? "") }
        #expect(Set(trashed) == ["e.txt", "new.txt"])
        let after = try t.repo.state()
        #expect(after.index == before.index && after.indexModified == before.indexModified)
        #expect(after.head == before.head && after.refs == before.refs && after.stash == before.stash && after.gitEntries == before.gitEntries)
        _ = try await t.pi.snapshot("the undone turn in the thread") { $0.turnChanges?.last?.state == .undone }

        let redone = try await t.changes.redoTurn(agentID: t.agent, turnID: turn.id)
        #expect(redone.state == .ready && redone.canUndo)
        #expect(t.repo.read("a.txt") == "one\ntwo\n" && t.repo.read("new.txt") == "brand new\n")
        #expect(t.repo.read("e.txt") == "a file that moves\nwith its lines\n")
        #expect(t.repo.read("c.txt") == nil && t.repo.read("d.txt") == nil)
        try t.repo.expectUnchanged(since: before)
    }

    /// A file the turn touched that changed afterwards is never overwritten: Undo refuses, naming
    /// it, and leaves every file as it is.
    @Test func undoRefusesWhenAFileChangedSinceTheTurn() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        try t.repo.write("a.txt", "one\ntwo\nthree, by the user\n")
        let before = try t.repo.state()

        let error = await #expect(throws: ChangesError.self) { _ = try await t.changes.undoTurn(agentID: t.agent, turnID: turn.id) }
        #expect(error?.code == ChangesError.changedSince && error?.files == ["a.txt"])
        try t.repo.expectUnchanged(since: before)
        #expect(t.turns().last?.state == .ready)
        #expect(!FileManager.default.fileExists(atPath: t.host.trash.path))
    }

    /// The next turn ends the last one's Undo; the engine's turns and their Undo also reach a
    /// remote client, which falls back to nothing it does not know.
    @Test func turnsAndUndoTravelTheRemoteProtocol() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n"])
        try "tool-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host, cwd: repo.url)
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:1 edit", from: idle).failureCode == nil)
        let changes = remote.server.changes
        try await eventually("the turn's baseline") { changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        try repo.write("a.txt", "one\ntwo\n")
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        try await eventually("the turn to end") { changes.turns(agentID: pi.agent.id).last?.state == .ready }

        let client = try await remote.typed()
        #expect(client.capabilities.contains(RemoteProtocol.changesCapability))
        guard case .changesOverview(let overview) = try await client.agentQuery(agentID: pi.agent.id, query: .changesOverview) else {
            Issue.record("expected an overview"); return
        }
        #expect(overview.lastTurn?.fileCount == 1 && overview.entries.first?.files == 1)
        guard case .changesList(let list) = try await client.agentQuery(agentID: pi.agent.id, query: .changesList(scope: .lastTurn, options: ChangesOptions())) else {
            Issue.record("expected a list"); return
        }
        #expect(list.summary == ["M a.txt"])
        guard case .changesFile(let file) = try await client.agentQuery(
            agentID: pi.agent.id, query: .changesFile(revision: list.revision, path: "a.txt", oldPath: nil, options: ChangesOptions())) else {
            Issue.record("expected a file"); return
        }
        #expect(file.file.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["two"])
        let turnID = try #require(list.comparison.turn?.id)
        guard case .changesTurn(let undone) = try await client.agentQuery(agentID: pi.agent.id, query: .changesUndoTurn(turnID: turnID)) else {
            Issue.record("expected the undone turn"); return
        }
        #expect(undone.state == .undone && repo.read("a.txt") == "one\n")
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.agentQuery(agentID: pi.agent.id, query: .changesFile(revision: ChangesRevision(old: "HEAD", new: "HEAD"),
                                                                                     path: "a.txt", oldPath: nil, options: ChangesOptions()))
        }

        // The next turn ends the undone one's Redo.
        let settled = try await pi.snapshot("the first turn to settle") { !$0.running }
        #expect(try await pi.send("tools:1 again", from: settled).failureCode == nil)
        try await eventually("the second turn's baseline") { changes.turnStore.latest(pi.agent.id)?.turn.id != turnID && changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        #expect(changes.turns(agentID: pi.agent.id).first { $0.id == turnID }?.canRedo == false)
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-2").path, contents: nil)
    }
}
