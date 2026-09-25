import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Commit from review on real repositories: a local bare repository is the origin, so the
/// commit and the push run for real. `gh` is either stubbed in the runner or the isolation's
/// stand-in, which refuses to run.
@Suite("Commit from review", .mainActorExclusive)
@MainActor
struct ReviewCommitTests {
    /// Runs scripts with `sh`, as the login shell would; `gh pr create` answers `prURL` when set
    /// (and is recorded), else reaches the isolation's stand-in.
    final class Runner {
        var prURL: String?
        var ghCommands: [String] = []

        func callAsFunction(_ script: String, _ cwd: String?) async -> LoginShell.Output {
            if script.hasPrefix("gh pr create"), let prURL {
                ghCommands.append(script)
                return .init(status: 0, stdout: prURL + "\n", stderr: "")
            }
            return Self.run(script, cwd: cwd)
        }

        var closure: ReviewCommitGit.Runner { { await self($0, $1) } }

        static func run(_ script: String, cwd: String?) -> LoginShell.Output {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return .init(status: 127, stdout: "", stderr: "\(error)") }
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                         stderr: String(decoding: stderr, as: UTF8.self))
        }
    }

    private func write(_ text: String, _ path: String, in sandbox: WorktreeSandbox) throws {
        let url = sandbox.repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func info(_ sandbox: WorktreeSandbox, runner: Runner, working: Bool = false) async throws -> RemoteCommitInfo {
        try await ReviewCommitGit.info(cwd: sandbox.repo.path, agentWorking: working, draftsMessage: false, runner: runner.closure)
    }

    private func options(_ info: RemoteCommitInfo, _ paths: [String], push: RemoteCommitPush, title: String = "Fix the 'thing'",
                         newBranch: String? = nil) -> RemoteCommitOptions {
        RemoteCommitOptions(head: info.head, files: info.files.filter { paths.contains($0.path) }, title: title,
                            body: "Why it changed.", push: push, newBranch: newBranch)
    }

    private func run(_ options: RemoteCommitOptions, in sandbox: WorktreeSandbox, runner: Runner) async -> ReviewCommitter {
        let committer = ReviewCommitter()
        committer.runner = runner.closure
        await committer.run(options, cwd: sandbox.repo.path)
        return committer
    }

    private func status(_ sandbox: WorktreeSandbox) throws -> String {
        try git(["status", "--porcelain"], in: sandbox.repo)
    }

    // MARK: Commit and push

    @Test func onlyTheTickedFilesAreCommittedAndPushedToTheUpstream() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        try write("new\n", "Sources/new.swift", in: sandbox)
        try write("left alone\n", "notes.txt", in: sandbox)
        try write("staged by hand\n", "staged.txt", in: sandbox)
        try git(["add", "staged.txt"], in: sandbox.repo)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)
        #expect(Set(info.files.map(\.path)) == ["README.md", "Sources/new.swift", "notes.txt", "staged.txt"])
        #expect(info.branch == "main" && info.upstream == "origin/main" && info.defaultBranch == "main" && info.blocked == nil)

        let committer = await run(options(info, ["README.md", "Sources/new.swift"], push: .upstream), in: sandbox, runner: runner)

        #expect(committer.phase == .succeeded)
        #expect(committer.progress.first == "check the checkout: on main")
        let committed = try git(["show", "--name-only", "--format=%s%n%b", "origin/main"], in: sandbox.repo)
        #expect(committed.hasPrefix("Fix the 'thing'\nWhy it changed.\n"))
        #expect(Set(committed.split(separator: "\n").suffix(2).map(String.init)) == ["README.md", "Sources/new.swift"])
        let left = try status(sandbox)
        #expect(left.contains("?? notes.txt"), "an unticked file is not touched")
        #expect(left.contains("A  staged.txt"), "what was staged for other paths stays staged")
        #expect(!left.contains("README.md") && !left.contains("new.swift"))
    }

    @Test func aBranchWithoutAnUpstreamGetsOneWhenItIsPushed() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try git(["switch", "-q", "-c", "feat/tool-rows"], in: sandbox.repo)
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)
        #expect(info.upstream == nil && info.pushRemote == "origin")
        #expect(reviewCommitPushDetail(info) == "origin/feat/tool-rows · sets upstream")

        let committer = await run(options(info, ["README.md"], push: .upstream), in: sandbox, runner: runner)

        #expect(committer.phase == .succeeded)
        #expect(try git(["rev-parse", "--abbrev-ref", "@{u}"], in: sandbox.repo).trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feat/tool-rows")
        #expect(try git(["log", "-1", "--format=%s", "feat/tool-rows"], in: sandbox.origin).hasPrefix("Fix the 'thing'"))
    }

    @Test func aCommitWithoutPushStaysLocal() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)

        let committer = await run(options(info, ["README.md"], push: .none), in: sandbox, runner: runner)

        #expect(committer.phase == .succeeded && committer.steps.count == 2)
        #expect(try git(["rev-list", "--count", "origin/main..main"], in: sandbox.repo).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    // MARK: Refused

    @Test(arguments: ["detached", "merge", "changedFile", "movedHead", "unsafePath"])
    func aCheckoutThatCanNotBeCommittedIsRefusedBeforeAnythingRuns(_ reason: String) async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        var info = try await info(sandbox, runner: runner)
        switch reason {
        case "detached":
            try git(["checkout", "-q", "--detach"], in: sandbox.repo)
            let detached = try await self.info(sandbox, runner: runner)
            #expect(detached.blocked?.contains("detached") == true)
        case "merge":
            try git(["stash", "-q"], in: sandbox.repo)
            try git(["switch", "-q", "-c", "other"], in: sandbox.repo)
            try write("theirs\n", "README.md", in: sandbox)
            try git(["commit", "-qam", "theirs"], in: sandbox.repo)
            try git(["switch", "-q", "main"], in: sandbox.repo)
            try write("ours\n", "README.md", in: sandbox)
            try git(["commit", "-qam", "ours"], in: sandbox.repo)
            _ = try? git(["merge", "-q", "other"], in: sandbox.repo)
            let merging = try await self.info(sandbox, runner: runner)
            #expect(merging.blocked?.contains("merge") == true)
            info = merging
        case "changedFile":
            try write("changed again\n", "README.md", in: sandbox)
        case "movedHead":
            try git(["commit", "-q", "--allow-empty", "-m", "someone else"], in: sandbox.repo)
        default:
            info.files[0] = RemoteCommitFile(path: "../outside.txt", status: "A", added: 1, removed: 0, fingerprint: "x")
        }
        let head = try git(["rev-parse", "HEAD"], in: sandbox.repo)
        let before = try status(sandbox)

        let committer = await run(RemoteCommitOptions(head: info.head, files: [info.files[0]], title: "t", body: "", push: .upstream),
                                  in: sandbox, runner: runner)

        #expect(committer.phase == .failed)
        guard case .failed? = committer.states[.check] else { Issue.record("the check should refuse"); return }
        #expect(committer.failure == "Nothing was committed.")
        #expect(try git(["rev-parse", "HEAD"], in: sandbox.repo) == head)
        #expect(try status(sandbox) == before)
    }

    @Test func aFailedCommitTakesBackWhatItStagedForNewFiles() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try write("new\n", "new.txt", in: sandbox)
        let hook = sandbox.repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'lint failed: new.txt' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)

        let committer = await run(options(info, ["new.txt"], push: .upstream), in: sandbox, runner: runner)

        #expect(committer.phase == .failed)
        #expect(committer.states[.commit(1)] == .failed("lint failed: new.txt"))
        #expect(committer.states[.push("origin/main")] == nil || committer.states[.push("origin/main")] == .pending)
        #expect(try status(sandbox) == "?? new.txt\n", "the new file is untracked again")
    }

    @Test func aRejectedPushKeepsTheCommitAndIsNeverForced() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        // Someone else pushed to main meanwhile.
        let other = sandbox.root.appendingPathComponent("other")
        try git(["clone", "-q", sandbox.origin.path, other.path], in: sandbox.root)
        try git(["-c", "user.name=o", "-c", "user.email=o@example.com", "commit", "-q", "--allow-empty", "-m", "theirs"], in: other)
        try git(["push", "-q"], in: other)
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)

        let committer = await run(options(info, ["README.md"], push: .upstream), in: sandbox, runner: runner)

        #expect(committer.phase == .failed)
        guard case .failed(let reason)? = committer.states[.push("origin/main")] else { Issue.record("the push should fail"); return }
        #expect(reason.hasPrefix("! [rejected]"), "git's reason leads")
        #expect(committer.failure?.contains("the push failed") == true)
        #expect(try git(["log", "-1", "--format=%s", "main"], in: sandbox.repo).hasPrefix("Fix the 'thing'"), "the commit stays")
        #expect(try git(["log", "-1", "--format=%s", "main"], in: sandbox.origin).hasPrefix("theirs"), "nothing was forced")
    }

    // MARK: Pull requests

    @Test func aPullRequestFromABranchPushesItAndOpensThePRIntoTheDefaultBranch() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try git(["switch", "-q", "-c", "feat/rows"], in: sandbox.repo)
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        runner.prURL = "https://github.com/o/r/pull/24"
        let info = try await info(sandbox, runner: runner)
        #expect(reviewCommitPullRequestDetail(info, title: "x") == "pushes feat/rows, opens a PR into main")

        let committer = await run(options(info, ["README.md"], push: .pullRequest), in: sandbox, runner: runner)

        #expect(committer.phase == .succeeded)
        #expect(committer.prURL == "https://github.com/o/r/pull/24")
        #expect(runner.ghCommands == ["gh pr create --head 'feat/rows' --base 'main' --title 'Fix the '\\''thing'\\''' --body 'Why it changed.'"])
        #expect(try git(["log", "-1", "--format=%s", "feat/rows"], in: sandbox.origin).hasPrefix("Fix the 'thing'"))
    }

    @Test func aPullRequestFromTheDefaultBranchCommitsOnANewBranch() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        runner.prURL = "https://github.com/o/r/pull/25"
        let info = try await info(sandbox, runner: runner)
        #expect(info.onDefaultBranch)
        let branch = reviewCommitBranchName(title: "Fix the 'thing'")

        let committer = await run(options(info, ["README.md"], push: .pullRequest, newBranch: branch), in: sandbox, runner: runner)

        #expect(committer.phase == .succeeded)
        #expect(committer.steps.map(\.label) == ["check the checkout", "create branch \(branch)", "commit 1 file",
                                                "push to origin/\(branch)", "open a pull request into main"])
        #expect(try git(["symbolic-ref", "--short", "HEAD"], in: sandbox.repo).trimmingCharacters(in: .whitespacesAndNewlines) == branch)
        #expect(try git(["rev-list", "--count", "origin/main..main"], in: sandbox.repo).trimmingCharacters(in: .whitespacesAndNewlines) == "0",
                "main is untouched")
    }

    @Test func withoutGhThePullRequestFailsAfterThePushAndSaysSo() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try git(["switch", "-q", "-c", "feat/no-gh"], in: sandbox.repo)
        try write("changed\n", "README.md", in: sandbox)
        let runner = Runner()
        let info = try await info(sandbox, runner: runner)

        let committer = await run(options(info, ["README.md"], push: .pullRequest), in: sandbox, runner: runner)

        #expect(committer.phase == .failed)
        guard case .failed(let reason)? = committer.states[.pullRequest("main")] else { Issue.record("gh should fail"); return }
        #expect(reason.contains("out of reach of Shepherd's tests"), "the stand-in's stderr is reported")
        #expect(committer.states[.push("origin/feat/no-gh")] == .done("pushed"))
        #expect(committer.failure?.hasPrefix("Committed and pushed feat/no-gh") == true)
    }

    // MARK: Through the host

    @Test func aRemoteClientCommitsThroughTheHostAndPollsTheOperation() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        let sandbox = try WorktreeSandbox(origin: true)
        defer { local.stop(); remote.stop(); sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        try write("new\n", "new.txt", in: sandbox)
        let space = Fixture.space("proj", path: sandbox.repo.path)
        let agent = Fixture.agent(in: space)
        remote.host.settings.worktreeGeneratePRDescription = false
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let runner = Runner()
        hostVM.reviewCommitRunner = runner.closure
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        #expect(connection.supportsReviewCommit)
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let store = ReviewCommitStore { try await local.remoteHosts.agentQuery(target, query: $0) }

        await store.begin()

        #expect(store.stage == .form && store.rows.map(\.name) == ["README.md", "new.txt"] && store.rows.allSatisfy(\.selected))
        #expect(store.title == "Update 2 files" && !store.drafted && store.push)
        guard case .commitMessage(let title, _, let drafted) = try await local.remoteHosts.agentQuery(target, query: .commitMessage(paths: ["new.txt"])) else {
            Issue.record("expected a message"); return
        }
        #expect(title == "Add new.txt" && !drafted, "with drafting off the host writes it from the file list")

        store.toggle("new.txt")
        store.title = "Update the readme"
        await store.commit()
        try await eventuallyAsync("the host to finish the commit", timeout: .seconds(20)) { await store.pollOnce() }

        #expect(store.outcome == .succeeded(prURL: nil))
        #expect(store.steps.map(\.label) == ["check the checkout", "commit 1 file", "push to origin/main"])
        #expect(try git(["log", "-1", "--format=%s", "main"], in: sandbox.origin).hasPrefix("Update the readme"))
        #expect(try status(sandbox) == "?? new.txt\n")
    }

    @Test func theHostRefusesACommitWhileItsAgentWorksUntilConfirmed() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        let sandbox = try WorktreeSandbox(origin: true)
        defer { local.stop(); remote.stop(); sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        let space = Fixture.space("proj", path: sandbox.repo.path)
        let agent = Fixture.agent("busy", in: space, status: .working)
        remote.host.settings.worktreeGeneratePRDescription = false
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        hostVM.reviewCommitRunner = Runner().closure
        // The host resets persisted statuses at start: the agent reports working again.
        let reporter = try ExtensionClient(path: remote.host.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: agent.agent.id, status: .working))
        let server = remote.host.server
        try await eventuallyOnMain("the agent to report working") { server.state.agents.first?.status == .working }
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        guard case .commitInfo(let info) = try await local.remoteHosts.agentQuery(target, query: .commitInfo) else {
            Issue.record("expected commit info"); return
        }
        #expect(info.agentWorking)
        var options = RemoteCommitOptions(head: info.head, files: info.files, title: "t", body: "", push: .none)

        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await local.remoteHosts.agentQuery(target, query: .commit(operationID: UUID(), options: options))
        }
        #expect(error?.rejectionCode == "query_failed")
        #expect(try status(sandbox).contains("README.md"), "nothing was committed")

        options.confirmedWhileWorking = true
        let id = UUID()
        _ = try await local.remoteHosts.agentQuery(target, query: .commit(operationID: id, options: options))
        try await eventuallyAsync("the confirmed commit to finish", timeout: .seconds(20)) {
            guard case .worktreeOperation(let op) = try await local.remoteHosts.agentQuery(target, query: .worktreeStatus(operationID: id)) else { return false }
            return op.finished && op.error == nil
        }
        #expect(try status(sandbox).isEmpty)
    }

    @Test func aLocalReviewCommitsTheDirectoryItsDiffCameFromAndReloads() async throws {
        let harness = try AppHarness()
        let sandbox = try WorktreeSandbox(origin: true)
        defer { harness.stop(); sandbox.remove() }
        try write("changed\n", "README.md", in: sandbox)
        let space = Fixture.space("proj", path: sandbox.repo.path)
        let agent = Fixture.agent(in: space)
        harness.settings.worktreeGeneratePRDescription = false
        let vm = try await harness.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.reviewCommitRunner = Runner().closure
        vm.selectAgent(agent.agent.id)
        vm.openUserReview()
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        #expect(vm.reviewCanCommit(session))
        let store = try #require(vm.reviewCommitStore(for: session))
        #expect(vm.reviewCommitStore(for: session) === store, "one store per review while it is open")

        await store.begin()
        store.push = false
        await store.commit()
        try await eventuallyAsync("the commit to finish", timeout: .seconds(20)) { await store.pollOnce() }
        vm.reviewCommitClosed(session)

        #expect(store.outcome == .succeeded(prURL: nil))
        try await eventuallyOnMain("the review to reload without the committed file") { !session.isLoading && session.files.isEmpty }
        #expect(vm.reviewCommitStore(for: session) !== store, "the next Commit… starts over")
    }
}
