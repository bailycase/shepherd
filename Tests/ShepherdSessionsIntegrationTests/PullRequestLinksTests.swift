import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport

/// Close threads when their pull request merges, kept by the server with no app
/// (`headlessPullRequestHosting`), on real scratch repositories. gh is stood in for: the lookup by
/// the hosting's `lookup`, GitHub's branch deletion by the forge runner.
@Suite("Pull request links hosted by the server", .mainActorExclusive)
@MainActor
struct PullRequestLinksTests {
    nonisolated static let branch = "agent/refund-events"
    nonisolated static let ref = ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31)

    @MainActor final class Setup {
        let h: ScratchServer
        let root: URL
        let repo: URL
        let path: String
        let agentID: AgentID
        let commands = Locked<[[String]]>([])
        var pullState: PullRequestState = .open
        var headRefOid = ""
        var closeOnMerge = true

        init(status: AgentStatus = .idle) async throws {
            let commands = commands
            h = try ScratchServer(forgeRunner: { command in
                commands.withValue { $0.append(command.arguments) }
                if command.arguments.starts(with: ["gh", "pr", "view"]) {
                    let json = #"{"state":"MERGED","headRefName":"\#(PullRequestLinksTests.branch)","isCrossRepository":false}"#
                    return ForgeOutput(output: Data(json.utf8))
                }
                return ForgeOutput()
            })
            root = try makeScratchDirectory("pr")
            repo = root.appendingPathComponent("payments")
            let origin = root.appendingPathComponent("origin.git")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try "# payments\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Shepherd Tests"],
                         ["config", "user.email", "tests@example.com"], ["add", "."], ["commit", "-qm", "initial"]] {
                _ = try git(args, in: repo)
            }
            _ = try git(["init", "-q", "--bare", "--initial-branch=main", origin.path], in: root)
            _ = try git(["remote", "add", "origin", origin.path], in: repo)
            _ = try git(["push", "-q", "-u", "origin", "main"], in: repo)
            path = try GitWorktree.add(repo: repo.path, branch: PullRequestLinksTests.branch)
            let checkout = URL(fileURLWithPath: path)
            try "refunds\n".write(to: checkout.appendingPathComponent("refunds.txt"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], in: checkout)
            _ = try git(["commit", "-qm", "Add refund events"], in: checkout)
            _ = try git(["push", "-q", "-u", "origin", PullRequestLinksTests.branch], in: checkout)
            headRefOid = try git(["rev-parse", "HEAD"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)

            let space = Space(name: "payments", path: repo.path)
            try await h.server.addSpace(space)
            let id = AgentID()
            let pane = LeafPane(cwd: path, agentID: id)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            var agent = Agent(id: id, name: "Add refund events", spaceID: space.id, tabID: tab.id, paneID: pane.id,
                              worktreeBranch: PullRequestLinksTests.branch)
            agent.worktreePath = path
            agent.status = status
            try await h.server.addAgent(agent, withTab: tab)
            agentID = id
        }

        var deletedOnGitHub: Bool { commands.withValue { $0 }.contains { $0.starts(with: ["gh", "api", "--method=DELETE"]) } }

        func branches() throws -> [String] {
            try git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init)
        }

        func stop() {
            h.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Serves the links with gh stood in for by `setup`'s pull request state.
    private func serve(_ setup: Setup) -> PullRequestLinks {
        var hosting = setup.h.server.headlessPullRequestHosting(closeOnMerge: { [unowned setup] in setup.closeOnMerge })
        hosting.lookup = { [unowned setup] _ in
            ThreadPullRequest(ref: Self.ref, state: setup.pullState, headRefName: Self.branch, headRefOid: setup.headRefOid)
        }
        return setup.h.server.servePullRequestLinks(hosting)
    }

    /// Seen open, then merged: what the poll or a turn's end would read.
    private func merge(_ setup: Setup, _ links: PullRequestLinks) async {
        setup.pullState = .open
        await links.refresh(setup.agentID)
        setup.pullState = .merged
        await links.refresh(setup.agentID)
    }

    @Test func aMergeClosesTheThreadItsWorktreeAndBothBranchesWithNoApp() async throws {
        let setup = try await Setup()
        defer { setup.stop() }
        let links = serve(setup)

        await merge(setup, links)

        #expect(!setup.h.server.state.agents.contains { $0.id == setup.agentID })
        #expect(!FileManager.default.fileExists(atPath: setup.path))
        #expect(try setup.branches() == ["main"])
        let delete = setup.commands.withValue { $0 }.first { $0.starts(with: ["gh", "api", "--method=DELETE"]) }
        #expect(delete?.last == "repos/acme/payments/git/refs/heads/agent/refund-events")
        #expect(links.links.isEmpty && links.closeNotes.isEmpty)
    }

    enum Kept: String, CaseIterable { case running, unpushed, switchOff }

    @Test(arguments: Kept.allCases)
    func aThreadThatMightLoseWorkStays(_ kept: Kept) async throws {
        let setup = try await Setup(status: kept == .running ? .working : .idle)
        defer { setup.stop() }
        let links = serve(setup)
        switch kept {
        case .unpushed:
            let checkout = URL(fileURLWithPath: setup.path)
            try "more".write(to: checkout.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
            _ = try git(["add", "."], in: checkout)
            _ = try git(["commit", "-qm", "Not pushed"], in: checkout)
        case .switchOff: setup.closeOnMerge = false
        case .running: break
        }

        await merge(setup, links)

        #expect(setup.h.server.state.agents.map(\.id) == [setup.agentID])
        #expect(FileManager.default.fileExists(atPath: setup.path))
        #expect(try setup.branches().contains(Self.branch))
        #expect(!setup.deletedOnGitHub)
        #expect(links.links[setup.agentID]?.state == .merged)
        switch kept {
        case .running: #expect(links.closeNotes[setup.agentID] == "it's running")
        case .unpushed: #expect(links.closeNotes[setup.agentID] == "1 unpushed commit")
        case .switchOff: #expect(links.closeNotes[setup.agentID] == nil)
        }
    }

    /// The headless host's poll looks every thread up once, then only open pull requests.
    @Test func thePollLooksUpOpenPullRequestsAgain() async throws {
        let setup = try await Setup()
        defer { setup.stop() }
        let asked = Locked(0)
        var hosting = setup.h.server.headlessPullRequestHosting(closeOnMerge: { true })
        hosting.lookup = { _ in
            asked.withValue { $0 += 1 }
            return ThreadPullRequest(ref: Self.ref, state: .closed, headRefName: Self.branch)
        }
        let links = setup.h.server.servePullRequestLinks(hosting)

        await links.poll()
        await links.poll()

        #expect(asked.current == 1, "a closed pull request isn't looked up again")
        #expect(links.links[setup.agentID]?.state == .closed)
    }
}
