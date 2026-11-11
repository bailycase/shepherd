import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The side pane's Pull request tab (PRPane): it shows while the thread's branch has a pull
/// request, which the host looks up, read in a store of its own, and goes when the branch has none.
@Suite("Pull request pane", .mainActorExclusive)
@MainActor
struct PullRequestPaneTests {
    @Test func theTabFollowsTheBranchsPullRequest() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("Add refund events", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let id = agent.agent.id
        let ref = ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31)
        var asked: [String] = []
        var found: ForgeItemRef? = ref
        app.host?.pullRequestLookup = { cwd in asked.append(cwd); return found.map { ThreadPullRequest(ref: $0, state: .open) } }
        // The page's reads go through the forge; this one stands in for gh.
        var requests: [RemoteForgeRequest] = []
        let store = ForgeStore { request in
            requests.append(request)
            return .failure(ForgeError(.notFound, "stub"))
        }
        vm.branchPullRequests[id] = store

        vm.refreshBranchPullRequest(id)
        try await eventuallyOnMain("the pull request read") { store.selection == ref && !requests.isEmpty }
        #expect(asked == [app.dir.path], "the host looked it up in the thread's checkout")
        #expect(vm.sidePaneTabs(for: .local(id)).contains(.pullRequest))
        #expect(requests.first == .pullRequest(ref: ref))
        try await eventuallyOnMain("the host's link pushed to the sidebar") { vm.pullRequestLinks[id]?.ref == ref }

        found = nil
        vm.refreshBranchPullRequest(id)
        try await eventuallyOnMain("the tab gone") { vm.branchPullRequests[id] == nil }
        try await eventuallyOnMain("the badge gone") { vm.pullRequestLinks[id] == nil }
        #expect(!vm.sidePaneTabs(for: .local(id)).contains(.pullRequest))
    }
}
