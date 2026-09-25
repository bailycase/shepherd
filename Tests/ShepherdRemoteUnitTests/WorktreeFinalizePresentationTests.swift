import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Finalize as a remote client draws it: the host's checks, the form's gates, and the host's
/// progress lines read back as steps.
@Suite("Finalize presentation")
struct WorktreeFinalizePresentationTests {
    @Test func checksFollowTheHostsOrderWithUnreportedOnesPending() {
        let setup = RemoteWorktreeSetup(repoPath: "/r", checks: ["gh": .fail("not installed"), "git": .pass("2.47"), "zeta": .checking],
                                        repoSettings: [:])
        let rows = finalizeCheckRows(setup)
        #expect(rows.map(\.id) == ["git", "identity", "remote", "gh", "ghAuth", "zeta"])
        #expect(rows.map(\.state) == [.pass("2.47"), .pending, .pending, .fail("not installed"), .pending, .checking])
        #expect(rows[0].label == "Git installed")
        #expect(!finalizeChecksPass(setup))
    }

    @Test func checksPassOnlyWhenTheHostReportsAllPassing() {
        #expect(!finalizeChecksPass(RemoteWorktreeSetup(repoPath: "/r", checks: [:], repoSettings: [:])))
        #expect(finalizeChecksPass(RemoteWorktreeSetup(repoPath: "/r", checks: ["git": .pass("ok"), "gh": .pass("ok")], repoSettings: [:])))
    }

    @Test(arguments: [
        ("main", "Fix it", "squash", nil),
        (" ", "Fix it", "squash", "Choose a base branch."),
        ("main", "\n", "merge", "Give the pull request a title."),
        ("main", "Fix it", "octopus", "Choose squash, merge or rebase."),
    ] as [(String, String, String, String?)])
    func theFormNeedsABaseATitleAndAKnownMergeMethod(base: String, title: String, method: String, problem: String?) {
        let options = RemoteFinalizeOptions(base: base, title: title, body: "", autoCommit: true, deleteLocalBranch: true,
                                            autoMergePR: false, mergeMethod: method)
        #expect(finalizeFormProblem(options) == problem)
    }

    @Test func progressLinesBecomeSteps() {
        let steps = finalizeSteps([
            "commit remaining work: nothing to commit",
            "push branch to origin: pushed",
            "create pull request: working…",
            "merge pull request: pending",
            "verify nothing is left behind: failed: 2 untracked files",
            "stopping agent",
        ])
        #expect(steps.map(\.label) == ["commit remaining work", "push branch to origin", "create pull request", "merge pull request",
                                       "verify nothing is left behind", "stopping agent"])
        #expect(steps.map(\.state) == [.done("nothing to commit"), .done("pushed"), .running, .pending, .failed("2 untracked files"), .done("")])
    }

    @Test func anOperationsOutcomeFollowsItsFinishAndError() {
        let id = UUID()
        #expect(FinalizeOutcome(RemoteWorktreeOperation(id: id)) == .running)
        #expect(FinalizeOutcome(RemoteWorktreeOperation(id: id, finished: true, prURL: "https://x/pull/1")) == .succeeded(prURL: "https://x/pull/1"))
        #expect(FinalizeOutcome(RemoteWorktreeOperation(id: id, finished: true, error: "stopped")) == .failed("stopped"))
    }
}
