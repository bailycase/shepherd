import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Revert File from a remote review (`changes.revert.v1`): one file back to HEAD, fenced to the
/// working-tree version the client displayed, and never the index, HEAD or other files.
@Suite("Changes revert", .integrationTimeLimit)
struct ChangesRevertTests {
    @Test func revertsOneFileOfTheDisplayedWorkingTreeAndNothingElse() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n", "b.txt": "bee\n", "c.txt": "moves\n", "d.txt": "dee\n"])
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("b.txt", "bee, edited\n")
        try repo.move("c.txt", "e.txt")
        try repo.remove("d.txt")
        try repo.write("new.txt", "new\n")
        try repo.write("staged.txt", "staged\n")
        try repo.git("add", "staged.txt")
        let h = try ChangesHarness(repo: repo)
        let list = try await h.list(.uncommitted)
        #expect(list.summary == ["A new.txt", "A staged.txt", "D d.txt", "M a.txt", "M b.txt", "R c.txt→e.txt"])
        let before = try repo.state()

        try await h.service.revertFile(agentID: h.agent, revision: list.revision, path: "a.txt")
        #expect(repo.read("a.txt") == "one\n" && repo.read("b.txt") == "bee, edited\n", "only a.txt went back")
        try await h.service.revertFile(agentID: h.agent, revision: list.revision, path: "d.txt")
        #expect(repo.read("d.txt") == "dee\n")
        try await h.service.revertFile(agentID: h.agent, revision: list.revision, path: "new.txt")
        #expect(repo.read("new.txt") == nil)
        try await h.service.revertFile(agentID: h.agent, revision: list.revision, path: "e.txt", oldPath: "c.txt")
        #expect(repo.read("c.txt") == "moves\n" && repo.read("e.txt") == nil)
        try await h.service.revertFile(agentID: h.agent, revision: list.revision, path: "staged.txt")
        #expect(repo.read("staged.txt") == nil)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: h.directory.appendingPathComponent("Trash").path)
        #expect(Set(trashed) == ["new.txt", "e.txt", "staged.txt"])
        let after = try repo.state()
        #expect(after.index == before.index && after.head == before.head && after.refs == before.refs && after.stash == before.stash)
        #expect(try await h.list(.uncommitted).summary == ["M b.txt"])
        #expect(try await h.list(.staged).summary == ["A staged.txt"], "the index still holds staged.txt, as Undo would leave it")
    }

    @Test func refusesAFileThatChangedSinceItWasShownAndAnyOtherRevision() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n", "b.txt": "bee\n"])
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("b.txt", "bee\nbee\n")
        let h = try ChangesHarness(repo: repo)
        let shown = try await h.list(.uncommitted)
        try repo.write("a.txt", "one\ntwo\nthree, by the user\n")
        let before = try repo.state()

        let stale = await #expect(throws: ChangesError.self) {
            try await h.service.revertFile(agentID: h.agent, revision: shown.revision, path: "a.txt")
        }
        #expect(stale?.code == ChangesError.changedSince && stale?.files == ["a.txt"])
        try repo.expectUnchanged(since: before)

        // b.txt is as shown, so the same list still reverts it.
        try await h.service.revertFile(agentID: h.agent, revision: shown.revision, path: "b.txt")
        #expect(repo.read("b.txt") == "bee\n" && repo.read("a.txt") == "one\ntwo\nthree, by the user\n")

        // A list that is not the working tree against HEAD (Unstaged, once the index differs from
        // HEAD), or a path outside the tree, is refused.
        try repo.git("add", "a.txt")
        let unstaged = try await h.list(.unstaged)
        #expect(unstaged.revision.old != shown.revision.old)
        let wrongScope = await #expect(throws: ChangesError.self) {
            try await h.service.revertFile(agentID: h.agent, revision: unstaged.revision, path: "a.txt")
        }
        #expect(wrongScope?.code == ChangesError.invalid)
        for path in ["../a.txt", "-a.txt", ".git/config", ""] {
            let bad = await #expect(throws: ChangesError.self) {
                try await h.service.revertFile(agentID: h.agent, revision: shown.revision, path: path)
            }
            #expect(bad?.code == ChangesError.invalid, Comment(rawValue: path))
        }
        #expect(repo.read("a.txt") == "one\ntwo\nthree, by the user\n")
    }

    /// The query travels the remote protocol, served by the host's engine without a GUI, behind
    /// `changes.revert.v1`.
    @Test func revertTravelsTheRemoteProtocol() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n"])
        try repo.write("a.txt", "one\ntwo\n")
        let remote = try RemoteHost()
        defer { remote.stop() }
        let space = Fixture.space("repo", path: repo.path)
        let worker = Fixture.agent(in: space)
        try await remote.host.seed(Fixture.workspace([worker], space: space))
        let client = try await remote.typed()
        #expect(client.capabilities.contains(RemoteProtocol.changesRevertCapability))
        guard case .changesList(let list) = try await client.agentQuery(agentID: worker.agent.id, query: .changesList(scope: .uncommitted, options: ChangesOptions())) else {
            Issue.record("expected a list"); return
        }
        #expect(list.summary == ["M a.txt"])
        guard case .ok = try await client.agentQuery(agentID: worker.agent.id, query: .changesRevertFile(revision: list.revision, path: "a.txt", oldPath: nil)) else {
            Issue.record("expected ok"); return
        }
        #expect(repo.read("a.txt") == "one\n")
        let again = await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.agentQuery(agentID: worker.agent.id, query: .changesRevertFile(revision: list.revision, path: "a.txt", oldPath: nil))
        }
        guard case .rejected(let code, _)? = again else { Issue.record("expected a refusal"); return }
        #expect(code == ChangesError.changedSince)
    }
}
