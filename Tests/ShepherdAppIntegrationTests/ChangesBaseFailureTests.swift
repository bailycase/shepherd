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

        replies.fail(RemoteHostClientError.rejected(code: ChangesError.unavailable, message: "Couldn’t read the branches."))
        try await eventuallyOnMain("the failure") { session.branchesError != nil }
        #expect(session.branchesError == "Couldn’t read the branches.")
        #expect(session.branches == nil && vm.actionError == nil, "the menu shows it, not a sheet")

        vm.loadChangesBranches(session)
        #expect(session.branchesError == nil, "asking again reads again")
        try await replies.waitForRequests(2)
        replies.succeed(ChangesBranches(defaultBase: "main", branches: []))
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
            replies.succeed(request: 1, list)
            try await eventuallyOnMain("the new list") { session.branches != nil }
            replies.fail(request: 0, refusal)
            await settle()
            #expect(session.branches != nil && session.branchesError == nil)
        case .oldFailsBeforeNewSucceeds:
            replies.fail(request: 0, refusal)
            await settle()
            #expect(session.branches == nil && session.branchesError == nil, "still reading: the retry is pending")
            replies.succeed(request: 1, list)
            try await eventuallyOnMain("the new list") { session.branches != nil }
            #expect(session.branchesError == nil)
        case .oldSucceedsAfterNewFails:
            replies.fail(request: 1, refusal)
            try await eventuallyOnMain("the failure") { session.branchesError != nil }
            replies.succeed(request: 0, list)
            await settle()
            #expect(session.branches == nil && session.branchesError == "Couldn’t read the branches.")
        }
    }

    enum Overlap: CaseIterable, CustomTestStringConvertible {
        case oldFailsAfterNewSucceeds, oldFailsBeforeNewSucceeds, oldSucceedsAfterNewFails
        var testDescription: String { "\(self)" }
    }

    /// Lets a reply the app should drop reach the main actor, so its absence is a result.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Branch requests the test answers by hand, in any order; a request is numbered from 0 as it arrives.
@MainActor
private final class BranchReplies {
    private var pending: [Int: CheckedContinuation<ChangesBranches, any Error>] = [:]
    private var issued = 0

    func next() async throws -> ChangesBranches {
        try await withCheckedThrowingContinuation {
            pending[issued] = $0
            issued += 1
        }
    }

    func waitForRequests(_ count: Int) async throws {
        try await eventuallyOnMain("\(count) branch request(s)") { self.issued >= count }
    }

    /// Answers the request that arrived `index`th, or the oldest unanswered one.
    func fail(request index: Int? = nil, _ error: any Error) { answer(index) { $0.resume(throwing: error) } }
    func succeed(request index: Int? = nil, _ branches: ChangesBranches) { answer(index) { $0.resume(returning: branches) } }

    private func answer(_ index: Int?, _ resume: (CheckedContinuation<ChangesBranches, any Error>) -> Void) {
        guard let key = index ?? pending.keys.min(), let request = pending.removeValue(forKey: key) else { return }
        resume(request)
    }
}
