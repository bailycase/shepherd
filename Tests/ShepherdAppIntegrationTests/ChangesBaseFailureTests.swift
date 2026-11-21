import Foundation
import ShepherdRemote
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The Changes base menu when the host's branch list request fails: the menu takes the failure
/// (with the host's message, no code prefix) instead of reading branches forever, and asking again
/// starts over.
@Suite("Changes base failure", .mainActorExclusive)
@MainActor
struct ChangesBaseFailureTests {
    @Test func aFailedBranchListShowsTheHostsMessageAndAskingAgainReplacesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let replies = BranchReplies()
        var engine = ChangesEngine.fixed([])
        engine.branches = { try await replies.next() }
        vm.changesEngineOverride = { _, _ in engine }
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)

        vm.loadChangesBranches(session)
        try await replies.waitForRequest()
        #expect(session.branches == nil && session.branchesError == nil, "reading while the request is in flight")

        replies.fail(RemoteHostClientError.rejected(code: ChangesError.unavailable, message: "Couldn’t read the branches."))
        try await eventuallyOnMain("the failure") { session.branchesError != nil }
        #expect(session.branchesError == "Couldn’t read the branches.")
        #expect(session.branches == nil && vm.actionError == nil, "the menu shows it, not a sheet")

        vm.loadChangesBranches(session)
        #expect(session.branchesError == nil, "asking again reads again")
        try await replies.waitForRequest()
        replies.succeed(ChangesBranches(defaultBase: "main", branches: []))
        try await eventuallyOnMain("the branches") { session.branches != nil }
        #expect(session.branchesError == nil)
    }
}

/// Branch requests the test answers by hand, one at a time.
@MainActor
private final class BranchReplies {
    private var pending: CheckedContinuation<ChangesBranches, any Error>?

    func next() async throws -> ChangesBranches {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func waitForRequest() async throws {
        try await eventuallyOnMain("a branch request") { self.pending != nil }
    }

    func fail(_ error: any Error) { answer { $0.resume(throwing: error) } }
    func succeed(_ branches: ChangesBranches) { answer { $0.resume(returning: branches) } }

    private func answer(_ resume: (CheckedContinuation<ChangesBranches, any Error>) -> Void) {
        guard let request = pending else { return }
        pending = nil
        resume(request)
    }
}
