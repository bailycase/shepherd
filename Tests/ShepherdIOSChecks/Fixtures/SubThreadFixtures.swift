import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Sub-threads and the branch behind the thread's ••• (SubThreadPhone, SubThreadPad, GitPhoneD,
// GitPhoneA, GitPhoneD-changes): a thread another thread started names it under the header, and
// the host answers the branch sheet's read (`branchStatus`).
extension FixtureCatalog {
    static var subThreads: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        return [
            FixtureScreen(name: "thread-started-by", hosts: SubThreadFixture.hosts(startedBy: true), routes: [.thread(ref)]),
            FixtureScreen(name: "thread-branch", hosts: SubThreadFixture.hosts(), routes: [.thread(ref)], presented: .review(.branch(ref))),
            // Settings ▸ Defaults' lower half: Threads a thread starts.
            FixtureScreen(name: "settings-defaults-lower", routes: [.settings(.defaults)], tab: .settings,
                          prepare: { _ in await TriggerFlowCheck.scrollDown(holding: nil) }),
            FixtureScreen(name: "review-branch", hosts: SubThreadFixture.hosts(review: true),
                          routes: [.thread(ref), .review(.changes(ref, file: nil))], prepare: ReviewFixture.annotate),
        ]
    }
}

enum SubThreadFixture {
    static let status = RemoteBranchStatus(
        base: "main", behind: 3, additions: 71, deletions: 8,
        pull: PullRequestSummary(ref: ForgeItemRef(kind: .pullRequest, repo: "acme/web", number: 31), title: "Live previews",
                                 author: "mara", updatedAt: Date(timeIntervalSince1970: FixtureData.start / 1000), state: .open,
                                 checks: .passed, reviewDecision: nil, headRef: "pi/swiftui-previews", baseRef: "main",
                                 additions: 71, deletions: 8))

    static func hosts(startedBy: Bool = false, review: Bool = false) -> [FixtureHostData] {
        var hosts = review ? ReviewFixture.hosts() : ThreadFixtures.hosts()
        if startedBy, let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            hosts[0].state.agents[index].startedBy = StartedBy(agentID: FixtureData.extensions, agentTitle: "Plan shepherd extensions",
                                                               at: FixtureData.start, depth: 1)
        }
        let earlier = hosts[0].reply
        hosts[0].reply = { request in
            if case .agentQuery(let id, _, .branchStatus) = request { return .agentResult(id: id, result: .branchStatus(status)) }
            return earlier?(request)
        }
        return hosts
    }
}
