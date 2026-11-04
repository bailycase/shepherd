import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Issues & PRs through the server on a fake gh (`ForgeFixtures`): a paired device and the Mac's
/// in-process entry point get the same answers, linked to the host's own threads, and a pin
/// survives a restart. No gh, git or network runs.
@Suite("Remote forge", .integrationTimeLimit)
struct RemoteForgeTests {
    static func runner(_ seen: Locked<[ForgeCommand]>) -> ForgeService.Runner {
        { command in
            seen.withValue { $0.append(command) }
            let (output, status, errors) = ForgeFixtures.answer(command.arguments)
            return ForgeOutput(output: Data(output.utf8), errors: errors, status: status)
        }
    }

    /// A space on the fixture checkout and a working thread on the head branch of #31.
    static func state() -> (ShepherdState, AgentID) {
        let space = Fixture.space("payments", path: ForgeFixtures.root)
        var made = Fixture.agent(in: space, name: "Add refund events", status: .working)
        made.agent.worktreeBranch = "agent/refund-events"
        made.agent.worktreePath = ForgeFixtures.root + "-refund"
        return (Fixture.workspace([made], space: space), made.agent.id)
    }

    @Test func aDeviceAndTheMacReadTheSameLinkedList() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let remote = try RemoteHost(forgeRunner: Self.runner(seen))
        defer { remote.stop() }
        let (state, agentID) = Self.state()
        try await remote.host.seed(state)
        let client = try await remote.typed()
        defer { client.disconnect() }
        #expect(client.servesForge)

        let request = RemoteForgeRequest.list(kind: .pullRequest, repo: ForgeFixtures.repo, sections: nil)
        guard case .success(.list(let list)) = await client.forge(request) else { Issue.record("no list"); return }
        let authored = try #require(list.section(.authored)).pullRequests
        #expect(authored.first?.ref.number == 31 && authored.first?.thread?.agentID == agentID && authored.first?.thread?.running == true)
        #expect(await remote.server.forge(request) == .success(.list(list)))

        guard case .success(.repos(let repos)) = await client.forge(.repos) else { Issue.record("no repos"); return }
        #expect(repos == [ForgeRepo(nameWithOwner: ForgeFixtures.repo, path: ForgeFixtures.root)])
    }

    @Test func aCommentReachesGhOnStdinAndFailuresReadAsWords() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let remote = try RemoteHost(forgeRunner: Self.runner(seen))
        defer { remote.stop() }
        let client = try await remote.typed()
        defer { client.disconnect() }
        let ref = ForgeItemRef(kind: .pullRequest, repo: ForgeFixtures.repo, number: 31)

        #expect(await client.forge(.comment(ref: ref, body: "--merge `now`")) == .success(.ok))
        let comment = try #require(seen.current.last)
        #expect(comment.arguments == ["gh", "pr", "comment", "31", "--repo=acme/payments", "--body-file", "-"])
        #expect(comment.input == Data("--merge `now`".utf8))

        let missing = await client.forge(.pullRequest(ref: ForgeItemRef(kind: .pullRequest, repo: ForgeFixtures.repo, number: 999)))
        guard case .failure(let error) = missing else { Issue.record("found #999"); return }
        #expect(error.code == .notFound)
        let invalid = await client.forge(.list(kind: .issue, repo: "-x/y", sections: nil))
        guard case .failure(let refused) = invalid else { Issue.record("listed -x/y"); return }
        #expect(refused.code == .invalid)
    }

    /// Pins live in the host's support directory: a restarted host still has them.
    @Test func aPinOutlivesARestart() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let first = try ScratchServer(forgeRunner: Self.runner(seen))
        let ref = ForgeItemRef(kind: .issue, repo: ForgeFixtures.repo, number: 34)
        guard case .success(.sidebar(let pinned)) = await first.server.forge(.setPinned(ref: ref, title: "Partial refunds", pinned: true)) else {
            Issue.record("no sidebar"); return
        }
        #expect(pinned.pins.map(\.pin.ref) == [ref])
        first.stop(keepFiles: true)

        let second = try ScratchServer(dir: first.dir, forgeRunner: Self.runner(seen))
        defer { second.stop() }
        guard case .success(.sidebar(let sidebar)) = await second.server.forge(.sidebar) else { Issue.record("no sidebar"); return }
        #expect(sidebar.pins.map(\.title) == ["Partial refunds round down by a cent"])
    }

    /// A host's test default never runs the user's gh.
    @Test func withoutARunnerNoGhRuns() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        #expect(await host.server.forge(.repos) == .success(.repos([])))
        guard case .failure(let error) = await host.server.forge(.list(kind: .issue, repo: ForgeFixtures.repo, sections: nil)) else {
            Issue.record("listed"); return
        }
        #expect(error == .ghMissing)
    }
}
