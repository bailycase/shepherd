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
        try await replies.waitForRequests(1)
        #expect(session.branches == nil && session.branchesError == nil, "reading while the request is in flight")

        try await replies.fail(RemoteHostClientError.rejected(code: ChangesError.unavailable, message: "Couldn’t read the branches."))
        try await eventuallyOnMain("the failure") { session.branchesError != nil }
        #expect(session.branchesError == "Couldn’t read the branches.")
        #expect(session.branches == nil && vm.actionError == nil, "the menu shows it, not a sheet")

        vm.loadChangesBranches(session)
        #expect(session.branchesError == nil, "asking again reads again")
        try await replies.waitForRequests(2)
        try await replies.succeed(ChangesBranches(defaultBase: "main", branches: []))
        try await eventuallyOnMain("the branches") { session.branches != nil }
        #expect(session.branchesError == nil)
    }

    /// Closing and reopening the menu while it loads asks again; only the newest request's reply counts.
    @Test(arguments: [Overlap.oldFailsAfterNewSucceeds, .oldFailsBeforeNewSucceeds, .oldSucceedsAfterNewFails])
    func onlyTheNewestBranchRequestsReplyCounts(_ overlap: Overlap) async throws {
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
        let refusal = RemoteHostClientError.rejected(code: ChangesError.unavailable, message: "Couldn’t read the branches.")
        let list = ChangesBranches(defaultBase: "main", branches: [])

        vm.loadChangesBranches(session)
        try await replies.waitForRequests(1)
        vm.loadChangesBranches(session)
        try await replies.waitForRequests(2)

        switch overlap {
        case .oldFailsAfterNewSucceeds:
            try await replies.succeed(request: 1, list)
            try await eventuallyOnMain("the new list") { session.branches != nil }
            try await replies.fail(request: 0, refusal)
            #expect(session.branches != nil && session.branchesError == nil)
        case .oldFailsBeforeNewSucceeds:
            try await replies.fail(request: 0, refusal)
            #expect(session.branches == nil && session.branchesError == nil, "still reading: the retry is pending")
            try await replies.succeed(request: 1, list)
            try await eventuallyOnMain("the new list") { session.branches != nil }
            #expect(session.branchesError == nil)
        case .oldSucceedsAfterNewFails:
            try await replies.fail(request: 1, refusal)
            try await eventuallyOnMain("the failure") { session.branchesError != nil }
            try await replies.succeed(request: 0, list)
            #expect(session.branches == nil && session.branchesError == "Couldn’t read the branches.")
        }
    }

    /// Retargeting the review (another worktree) starts the session over; a reply to a request
    /// from before it changes neither the old state nor the new one.
    @Test(arguments: [false, true])
    func aReplyAfterTheReviewIsRetargetedChangesNothing(succeeds: Bool) async throws {
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
        let oldCwd = session.cwd

        vm.loadChangesBranches(session)
        try await replies.waitForRequests(1)
        vm.beginReview(agentID: agent.agent.id, cwd: app.dir.appendingPathComponent("other").path, reference: nil)
        #expect(vm.reviewSessions.values.first === session && session.cwd != oldCwd, "the review moved")
        #expect(session.branches == nil && session.branchesError == nil)

        if succeeds {
            try await replies.succeed(request: 0, ChangesBranches(defaultBase: "main", branches: []))
        } else {
            try await replies.fail(request: 0, RemoteHostClientError.rejected(code: ChangesError.unavailable, message: "Couldn’t read the branches."))
        }
        #expect(session.branches == nil && session.branchesError == nil && vm.actionError == nil)
    }

    enum Overlap: CaseIterable, CustomTestStringConvertible {
        case oldFailsAfterNewSucceeds, oldFailsBeforeNewSucceeds, oldSucceedsAfterNewFails
        var testDescription: String { "\(self)" }
    }
}

/// Branch requests the test answers by hand, in any order; a request is numbered from 0 as it arrives.
@MainActor
private final class BranchReplies {
    private var pending: [Int: CheckedContinuation<ChangesBranches, any Error>] = [:]
    private var issued = 0
    private var returned = 0

    func next() async throws -> ChangesBranches {
        // The engine closure and the view model's handler both run on the main actor, so the
        // handler runs in the same job right after this returns: once `returned` is seen, it is done.
        defer { returned += 1 }
        return try await withCheckedThrowingContinuation {
            pending[issued] = $0
            issued += 1
        }
    }

    func waitForRequests(_ count: Int) async throws {
        try await eventuallyOnMain("\(count) branch request(s)") { self.issued >= count }
    }

    /// Answers the request that arrived `index`th, or the oldest unanswered one, and returns once
    /// the app has handled the reply.
    func fail(request index: Int? = nil, _ error: any Error) async throws { try await answer(index) { $0.resume(throwing: error) } }
    func succeed(request index: Int? = nil, _ branches: ChangesBranches) async throws { try await answer(index) { $0.resume(returning: branches) } }

    private func answer(_ index: Int?, _ resume: (CheckedContinuation<ChangesBranches, any Error>) -> Void) async throws {
        guard let key = index ?? pending.keys.min(), let request = pending.removeValue(forKey: key) else { return }
        let before = returned
        resume(request)
        try await eventuallyOnMain("the reply handled") { self.returned > before }
    }
}
