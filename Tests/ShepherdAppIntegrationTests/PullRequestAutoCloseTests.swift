import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Close threads when their pull request merges (Settings ▸ Worktrees): a worktree thread's link
/// to its branch's pull request, and the close a merge seen happening drives, on real scratch
/// repositories. gh is stood in for: the lookup by `branchPullRequestLookup`, GitHub's branch
/// deletion by the forge runner.
@Suite("Pull request auto-close", .mainActorExclusive)
@MainActor
struct PullRequestAutoCloseTests {
    nonisolated static let branch = "agent/refund-events"
    nonisolated static let ref = ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31)

    /// A worktree thread whose branch is pushed, its pull request's state read from `pullState`.
    @MainActor final class Setup {
        let app: AppHarness
        let sandbox: WorktreeSandbox
        let agent: AgentFixture
        let vm: ShepherdViewModel
        let commands = Locked<[[String]]>([])
        var pullState: PullRequestState = .open
        var headRefOid: String

        init(status: AgentStatus = .idle) async throws {
            let commands = commands
            app = try AppHarness(forgeRunner: { command in
                commands.withValue { $0.append(command.arguments) }
                if command.arguments.starts(with: ["gh", "pr", "view"]) {
                    let json = #"{"state":"MERGED","headRefName":"\#(PullRequestAutoCloseTests.branch)","isCrossRepository":false}"#
                    return ForgeOutput(output: Data(json.utf8))
                }
                return ForgeOutput()
            }, inProcess: true)
            sandbox = try WorktreeSandbox(origin: true)
            let path = try GitWorktree.add(repo: sandbox.repo.path, branch: PullRequestAutoCloseTests.branch)
            let checkout = URL(fileURLWithPath: path)
            try "refunds\n".write(to: checkout.appendingPathComponent("refunds.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: checkout)
            try git(["commit", "-qm", "Add refund events"], in: checkout)
            try git(["push", "-q", "-u", "origin", PullRequestAutoCloseTests.branch], in: checkout)
            headRefOid = try git(["rev-parse", "HEAD"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)
            let space = Fixture.space("payments", path: sandbox.repo.path)
            var agent = Fixture.agent("Add refund events", in: space, cwd: path, status: status)
            agent.agent.worktreeBranch = PullRequestAutoCloseTests.branch
            agent.agent.worktreePath = path
            self.agent = agent
            vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
            app.settings.worktreeCloseOnMerge = true
            vm.branchPullRequestLookup = { [unowned self] _ in
                ThreadPullRequest(ref: PullRequestAutoCloseTests.ref, state: pullState,
                                  headRefName: PullRequestAutoCloseTests.branch, headRefOid: headRefOid)
            }
        }

        var id: AgentID { agent.agent.id }
        var checkout: String { agent.agent.worktreePath! }
        var deletedOnGitHub: Bool { commands.withValue { $0 }.contains { $0.starts(with: ["gh", "api", "--method=DELETE"]) } }

        /// Seen open, then merged: what the poll or a turn's end would read.
        func merge() async {
            pullState = .open
            await vm.refreshPullRequestLink(id)
            pullState = .merged
            await vm.refreshPullRequestLink(id)
        }

        func stop() { app.stop(); sandbox.remove() }
    }

    @Test func theLinkShowsOnTheThreadsSidebarRow() async throws {
        let setup = try await Setup()
        defer { setup.stop() }
        let vm = setup.vm

        let link = await vm.refreshPullRequestLink(setup.id)

        #expect(link?.ref == Self.ref && link?.state == .open)
        #expect(vm.pullRequestLinks[setup.id] == link)
        let row = try #require(vm.sidebarLists.all.first { $0.id == .local(setup.id) })
        #expect(row.pullRequest?.text == "#31")
        #expect(row.help.contains("Pull request #31 open"))
    }

    @Test func aMergeClosesTheThreadItsWorktreeAndBothBranches() async throws {
        let setup = try await Setup()
        defer { setup.stop() }
        let server = setup.app.server

        await setup.merge()

        try await eventuallyOnMain("the thread, its worktree and its branch gone") {
            server.state.agents.isEmpty && !FileManager.default.fileExists(atPath: setup.checkout)
                && (try? setup.sandbox.branches()) == ["main"]
        }
        #expect(setup.deletedOnGitHub, "the branch on GitHub goes too")
        let delete = setup.commands.withValue { $0 }.first { $0.starts(with: ["gh", "api", "--method=DELETE"]) }
        #expect(delete?.last == "repos/acme/payments/git/refs/heads/agent/refund-events")
        #expect(setup.vm.pullRequestLinks.isEmpty && setup.vm.remoteActionError == nil)
    }

    enum Skip: String, CaseIterable {
        case running, asking, dirty, unpushed, closedUnmerged, settingOff, mergedBeforeSeenOpen
    }

    @Test(arguments: Skip.allCases)
    func aThreadThatMightLoseWorkStays(_ skip: Skip) async throws {
        let setup = try await Setup(status: skip == .running ? .working : skip == .asking ? .blocked : .idle)
        defer { setup.stop() }
        let vm = setup.vm
        let checkout = URL(fileURLWithPath: setup.checkout)
        switch skip {
        case .dirty:
            try "wip".write(to: checkout.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        case .unpushed:
            try "more".write(to: checkout.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: checkout)
            try git(["commit", "-qm", "Not pushed"], in: checkout)
        case .settingOff:
            setup.app.settings.worktreeCloseOnMerge = false
        default:
            break
        }

        switch skip {
        case .closedUnmerged:
            setup.pullState = .open
            await vm.refreshPullRequestLink(setup.id)
            setup.pullState = .closed
            await vm.refreshPullRequestLink(setup.id)
        case .mergedBeforeSeenOpen:
            // Found merged on the first look (a restart): never closed.
            setup.pullState = .merged
            await vm.refreshPullRequestLink(setup.id)
        default:
            await setup.merge()
        }
        await setup.app.settle()

        #expect(setup.app.server.state.agents.map(\.id) == [setup.id])
        #expect(FileManager.default.fileExists(atPath: setup.checkout))
        #expect(try setup.sandbox.branches().contains(Self.branch))
        #expect(!setup.deletedOnGitHub)
        let note = vm.pullRequestCloseNotes[setup.id]
        switch skip {
        case .running: #expect(note == "it's running")
        case .asking: #expect(note == "it's waiting on your answer")
        case .dirty: #expect(note == "1 uncommitted change")
        case .unpushed: #expect(note == "1 unpushed commit")
        case .closedUnmerged, .settingOff, .mergedBeforeSeenOpen: #expect(note == nil)
        }
        if note != nil {
            let row = try #require(vm.sidebarLists.all.first { $0.id == .local(setup.id) })
            #expect(row.help.contains("kept open: \(note!)"), "the row says why")
        }
    }
}
