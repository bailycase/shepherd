import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// A stand-in login shell: records every script and answers from a responder. No process runs.
final class ScriptedShell: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(script: String, cwd: String?)] = []
    private let respond: @Sendable (String) -> LoginShell.Output

    init(_ respond: @escaping @Sendable (String) -> LoginShell.Output = { _ in .ok }) {
        self.respond = respond
    }

    func run(_ script: String, _ cwd: String?) -> LoginShell.Output {
        lock.withLock { calls.append((script, cwd)) }
        return respond(script)
    }

    var scripts: [String] { lock.withLock { calls.map(\.script) } }
    func cwd(ofScriptStartingWith prefix: String) -> String?? {
        lock.withLock { calls.first { $0.script.hasPrefix(prefix) }.map(\.cwd) }
    }
    func ran(_ prefix: String) -> Bool { scripts.contains { $0.hasPrefix(prefix) } }
}

extension LoginShell.Output {
    static let ok = LoginShell.Output(status: 0, stdout: "", stderr: "")
    static func out(_ stdout: String) -> Self { .init(status: 0, stdout: stdout, stderr: "") }
    static func fail(_ status: Int32 = 1, _ stderr: String = "") -> Self { .init(status: status, stdout: "", stderr: stderr) }
}

/// Finalize: commit → push → PR → (opt-in merge) → clean gate → remove worktree → delete local
/// branch. Every step gates the next, and all destruction sits after the clean gate.
@Suite("Worktree finalize pipeline")
@MainActor
struct WorktreeFinalizePipelineTests {
    private nonisolated static let prURL = "https://github.com/o/r/pull/7"
    private static let destructive = ["git worktree remove", "git branch -D"]

    private func context(_ configure: (inout WorktreeFinalizer.Context) -> Void = { _ in }) -> WorktreeFinalizer.Context {
        var context = WorktreeFinalizer.Context(repo: "/tmp/repo", worktree: "/tmp/repo-worktree-x", branch: "worktree/x",
                                                base: "main", title: "Fix the thing", body: "")
        configure(&context)
        return context
    }

    /// A dirty worktree whose PR is created; override individual scripts with `overrides`.
    private func shell(_ overrides: [String: LoginShell.Output] = [:]) -> ScriptedShell {
        ScriptedShell { script in
            if let match = overrides.first(where: { script.hasPrefix($0.key) }) { return match.value }
            if script.hasPrefix("git status") { return .out(" M file.txt\n") }
            if script.hasPrefix("gh pr create") { return .out("Creating pull request\n\(Self.prURL)\n") }
            return .ok
        }
    }

    private func run(_ context: WorktreeFinalizer.Context, shell: ScriptedShell,
                     clean: String? = nil) async -> WorktreeFinalizer {
        let finalizer = WorktreeFinalizer()
        finalizer.runner = { shell.run($0, $1) }
        finalizer.cleanCheck = { _, _ in clean }
        await finalizer.run(context)
        return finalizer
    }

    @Test func theHappyPathRunsEveryStepInOrderAndCapturesThePR() async {
        let shell = shell()
        let finalizer = await run(context(), shell: shell)

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.prURL == Self.prURL)
        #expect(shell.scripts == [
            "git status --porcelain",
            "git add -A && git commit -m 'Fix the thing'",
            "git push -u origin 'worktree/x'",
            "gh pr create --head 'worktree/x' --base 'main' --title 'Fix the thing'",
            "git worktree remove '/tmp/repo-worktree-x'",
            "git branch -D 'worktree/x'",
        ])
        #expect(finalizer.states == [
            .commit: .done("committed"), .push: .done("pushed"), .pullRequest: .done(Self.prURL),
            .mergePR: .skipped("off — Settings ▸ Worktrees"), .verifyClean: .done("clean"),
            .removeWorktree: .done("removed"), .deleteBranch: .done("deleted"),
        ])
    }

    /// Work happens in the worktree; removing it and its branch happens from the repository.
    @Test func cleanupRunsFromTheRepositoryAndEverythingElseFromTheWorktree() async {
        let shell = shell()
        _ = await run(context(), shell: shell)
        #expect(shell.cwd(ofScriptStartingWith: "git push") == "/tmp/repo-worktree-x")
        #expect(shell.cwd(ofScriptStartingWith: "gh pr create") == "/tmp/repo-worktree-x")
        #expect(shell.cwd(ofScriptStartingWith: "git worktree remove") == "/tmp/repo")
        #expect(shell.cwd(ofScriptStartingWith: "git branch -D") == "/tmp/repo")
    }

    /// The branch may hold committed-but-unpushed work, so a clean worktree still pushes.
    @Test func aCleanWorktreeSkipsTheCommitButStillPushes() async {
        let shell = shell(["git status": .ok])
        let finalizer = await run(context(), shell: shell)
        #expect(finalizer.states[.commit] == .skipped("nothing to commit"))
        #expect(!shell.ran("git add"))
        #expect(shell.ran("git push"))
        #expect(finalizer.phase == .succeeded)
    }

    /// A failure anywhere before cleanup leaves the work intact and later steps pending.
    @Test(arguments: [
        ("git status", WorktreeFinalizer.Step.commit),
        ("git add", .commit),
        ("git push", .push),
        ("gh pr create", .pullRequest),
    ])
    func aFailingStepStopsThePipelineBeforeAnyDestruction(failing prefix: String, step: WorktreeFinalizer.Step) async {
        let shell = shell([prefix: .fail(128, "fatal: nope")])
        let finalizer = await run(context(), shell: shell)

        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[step] == .failed("fatal: nope"))
        for later in WorktreeFinalizer.Step.allCases where later.rawValue > step.rawValue {
            #expect(finalizer.states[later] == .pending, "\(later) ran after \(step) failed")
        }
        #expect(!Self.destructive.contains(where: shell.ran))
    }

    /// The clean gate blocks all destruction when work would be lost.
    @Test func unreconciledWorkBlocksCleanup() async {
        let shell = shell()
        let finalizer = await run(context(), shell: shell, clean: "1 commit only on this branch")
        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[.verifyClean] == .failed("1 commit only on this branch — aborting before any cleanup"))
        #expect(!Self.destructive.contains(where: shell.ran))
    }

    /// Retiring the agent (persisting state) happens before removal; if it fails nothing is removed.
    @Test func aFailedRetirementStopsFilesystemCleanup() async {
        let shell = shell()
        let finalizer = WorktreeFinalizer()
        finalizer.runner = { shell.run($0, $1) }
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.beforeCleanup = { throw GitWorktree.Failure(message: "persistence failed") }

        await finalizer.run(context())

        #expect(finalizer.phase == .failed)
        #expect(!Self.destructive.contains(where: shell.ran))
    }

    @Test func aFailedRemovalKeepsTheBranch() async {
        let shell = shell(["git worktree remove": .fail(128, "contains modified files")])
        let finalizer = await run(context(), shell: shell)
        #expect(finalizer.states[.removeWorktree] == .failed("contains modified files"))
        #expect(!shell.ran("git branch -D"))
    }

    /// Auto-commit off: a dirty worktree stops with guidance instead of committing for the user.
    @Test func autoCommitOffStopsOnADirtyWorktree() async throws {
        let shell = shell()
        let finalizer = await run(context { $0.autoCommit = false }, shell: shell)
        #expect(finalizer.phase == .failed)
        guard case .failed(let detail)? = finalizer.states[.commit] else {
            Issue.record("the commit step should fail")
            return
        }
        #expect(detail.contains("auto-commit is off"))
        #expect(!shell.ran("git add") && !shell.ran("git push"))
    }

    @Test func keepingTheLocalBranchSkipsOnlyTheBranchDelete() async {
        let shell = shell()
        let finalizer = await run(context { $0.deleteLocalBranch = false }, shell: shell)
        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.deleteBranch] == .skipped("kept — Settings ▸ Worktrees"))
        #expect(shell.ran("git worktree remove") && !shell.ran("git branch -D"))
    }

    /// The remote branch is never deleted: that would close an open PR.
    @Test func theRemoteBranchIsNeverTouched() async {
        let shell = shell()
        _ = await run(context { $0.autoMergePR = true }, shell: shell)
        #expect(!shell.scripts.contains { $0.contains("push origin --delete") || $0.contains(":worktree/x") })
        #expect(!shell.scripts.contains { $0.contains("--delete-branch") })
    }

    // MARK: Merge (opt-in, best-effort)

    @Test func autoMergeIsTriedFirstWithTheChosenMethod() async {
        let shell = shell()
        let finalizer = await run(context { $0.autoMergePR = true; $0.mergeMethod = "rebase" }, shell: shell)
        #expect(finalizer.states[.mergePR] == .done("auto-merge enabled"))
        #expect(shell.scripts.filter { $0.hasPrefix("gh pr merge") } == ["gh pr merge 'worktree/x' --rebase --auto"])
    }

    /// GitHub rejects auto-merge on an already-mergeable PR; an immediate merge is the fallback.
    @Test func aRejectedAutoMergeFallsBackToAnImmediateMerge() async {
        let shell = ScriptedShell { script in
            if script.hasSuffix("--auto") { return .fail(1, "clean status") }
            if script.hasPrefix("gh pr create") { return .out("https://github.com/o/r/pull/13\n") }
            return .ok
        }
        let finalizer = await run(context { $0.autoMergePR = true }, shell: shell)
        #expect(finalizer.states[.mergePR] == .done("merged"))
        #expect(shell.scripts.filter { $0.hasPrefix("gh pr merge") } == [
            "gh pr merge 'worktree/x' --squash --auto", "gh pr merge 'worktree/x' --squash",
        ])
    }

    /// An unmergeable PR stays open for a human; cleanup still runs.
    @Test func anUnmergeablePRNeverBlocksCleanup() async {
        let shell = shell(["gh pr merge": .fail(1, "required status checks have not passed")])
        let finalizer = await run(context { $0.autoMergePR = true }, shell: shell)
        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.mergePR] == .skipped("not merged — PR left open (required status checks have not passed)"))
        #expect(shell.ran("git worktree remove"))
    }

    // MARK: Pull request details

    /// An empty body lets GitHub apply the repository's PR template.
    @Test func anEmptyBodyOmitsTheBodyFlag() async {
        let shell = shell()
        _ = await run(context { $0.body = "  \n" }, shell: shell)
        #expect(shell.scripts.first { $0.hasPrefix("gh pr create") }?.contains("--body") == false)
    }

    @Test func titlesAndBodiesAreQuotedForTheShell() async {
        let shell = shell()
        _ = await run(context { $0.title = "Fix O'Neil's bug"; $0.body = "  ## Summary\nIt's fixed.  " }, shell: shell)
        let create = shell.scripts.first { $0.hasPrefix("gh pr create") }
        #expect(create?.hasSuffix(#"--title 'Fix O'\''Neil'\''s bug' --body '## Summary"# + "\n" + #"It'\''s fixed.'"#) == true)
        #expect(shell.scripts.contains(#"git add -A && git commit -m 'Fix O'\''Neil'\''s bug'"#))
    }

    @Test func aPRCreatedWithoutAURLStillSucceeds() async {
        let shell = shell(["gh pr create": .out("done\n")])
        let finalizer = await run(context(), shell: shell)
        #expect(finalizer.states[.pullRequest] == .done("created"))
        #expect(finalizer.prURL == nil)
    }

    /// A failure's detail is stderr, else stdout, else the exit status.
    @Test(arguments: [
        (LoginShell.Output(status: 128, stdout: "out", stderr: " err \n"), "err"),
        (LoginShell.Output(status: 128, stdout: " out \n", stderr: ""), "out"),
        (LoginShell.Output(status: 128, stdout: "", stderr: ""), "exit 128"),
    ])
    func failureDetailPrefersStderrThenStdoutThenStatus(output: LoginShell.Output, detail: String) async {
        let finalizer = await run(context(), shell: shell(["git push": output]))
        #expect(finalizer.states[.push] == .failed(detail))
    }

    /// Real git and gh failures: the first line, which is all the sheet shows before its
    /// tooltip, names the problem instead of git's `To <remote>` header.
    @Test(arguments: [
        ("""
        To github.com:ada/shepherd.git
         ! [rejected]        feat/x -> feat/x (non-fast-forward)
        error: failed to push some refs to 'github.com:ada/shepherd.git'
        hint: Updates were rejected because the tip of your current branch is behind
        """, "! [rejected] feat/x -> feat/x (non-fast-forward)"),
        ("""
        To github.com:ada/shepherd.git
         ! [remote rejected] feat/x -> feat/x (protected branch hook declined)
        error: failed to push some refs to 'github.com:ada/shepherd.git'
        """, "! [remote rejected] feat/x -> feat/x (protected branch hook declined)"),
        ("""
        ERROR: Permission to ada/shepherd.git denied to someone.
        fatal: Could not read from remote repository.
        """, "ERROR: Permission to ada/shepherd.git denied to someone."),
        ("pull request create failed: GraphQL: No commits between main and feat/x (createPullRequest)",
         "pull request create failed: GraphQL: No commits between main and feat/x (createPullRequest)"),
    ])
    func aFailureLeadsWithTheLineThatNamesTheProblem(stderr: String, first: String) {
        let detail = WorktreeFinalizer.failureDetail(.init(status: 1, stdout: "", stderr: stderr))
        #expect(detail.split(separator: "\n").first.map(String.init) == first)
        let words = { (text: Substring) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(Set(detail.split(separator: "\n").map(words)) == Set(stderr.split(separator: "\n").map(words)),
                "the tooltip keeps every line")
    }

    @Test func aFinishedPipelineDoesNotRunAgain() async {
        let shell = shell()
        let finalizer = await run(context(), shell: shell)
        let count = shell.scripts.count
        await finalizer.run(context())
        #expect(shell.scripts.count == count)
    }
}

/// The finalize sheet's setup wizard: probes prerequisites and applies the fixable remedies.
@Suite("Worktree setup checks")
@MainActor
struct WorktreeSetupTests {
    /// A host where everything is installed and signed in, except what `failing` names.
    private func host(identity: Bool = true, failing: Set<String> = [], repoSettings: String = "[true,false]") -> ScriptedShell {
        ScriptedShell { script in
            if let prefix = failing.first(where: { script.contains($0) }) {
                return prefix == "xcode-select -p" ? .fail(2) : .fail(1, "fatal: could not read from remote\nPermission denied")
            }
            if script.hasPrefix("git config --get") { return identity ? .out("Ada\nada@example.invalid\n") : .fail(1) }
            if script.hasPrefix("gh api") { return .out(repoSettings) }
            if script.hasPrefix("gh auth status") { return .out("github.com\n  ✓ Logged in to github.com account ada\n") }
            if script.contains("git --version") { return .out("git version 2.50.0\n") }
            if script.contains("gh --version") { return .out("gh version 2.70.0\n") }
            return .ok
        }
    }

    private func model(_ shell: ScriptedShell) -> WorktreeSetupModel {
        let model = WorktreeSetupModel(repoPath: "/host/repo")
        model.runner = { shell.run($0, $1) }
        return model
    }

    @Test func aReadyHostPassesEveryCheck() async {
        let model = model(host())
        await model.runAll()
        #expect(model.allPassed)
        #expect(model.states[.git] == .pass("git version 2.50.0"))
        #expect(model.states[.identity] == .pass("Ada · ada@example.invalid"))
        #expect(model.states[.ghAuth] == .pass("✓ Logged in to github.com account ada"))
        #expect(!model.running)
    }

    @Test func repositoryChecksRunInTheRepository() async {
        let shell = host()
        await model(shell).runAll()
        #expect(shell.cwd(ofScriptStartingWith: "git ls-remote") == "/host/repo")
        #expect(shell.cwd(ofScriptStartingWith: "git config --get") == "/host/repo")
    }

    @Test(arguments: [
        ("xcode-select -p", WorktreeSetupCheck.git, "Apple's Command Line Tools are not installed"),
        ("git ls-remote", .remote, "Permission denied"),
        ("gh --version", .gh, "GitHub CLI not installed"),
        ("gh auth status", .ghAuth, "not authenticated — run gh auth login"),
    ])
    func aMissingPrerequisiteFailsItsCheckWithARemedy(failing: String, check: WorktreeSetupCheck, message: String) async {
        let model = model(host(failing: [failing]))
        await model.runAll()
        #expect(model.states[check] == .fail(message))
        #expect(!model.allPassed)
    }

    /// git's closing lines after an SSH failure, the same whatever went wrong.
    private nonisolated static let sshBoilerplate = """
        fatal: Could not read from remote repository.

        Please make sure you have the correct access rights
        and the repository exists.

        """

    /// Real `git ls-remote` stderr: the check shows the line that names the problem, not git's
    /// boilerplate.
    @Test(arguments: [
        ("ssh: Could not resolve hostname github.invalid: nodename nor servname provided, or not known\n" + sshBoilerplate,
         "ssh: Could not resolve hostname github.invalid: nodename nor servname provided, or not known"),
        ("git@github.com: Permission denied (publickey).\n" + sshBoilerplate, "git@github.com: Permission denied (publickey)."),
        ("ERROR: Repository not found.\n" + sshBoilerplate, "ERROR: Repository not found."),
        ("fatal: 'origin' does not appear to be a git repository\n" + sshBoilerplate, "fatal: 'origin' does not appear to be a git repository"),
        ("fatal: unable to access 'https://github.invalid/o/r.git/': Could not resolve host: github.invalid\n",
         "fatal: unable to access 'https://github.invalid/o/r.git/': Could not resolve host: github.invalid"),
        ("remote: Invalid username or token. Password authentication is not supported for Git operations.\n"
            + "fatal: Authentication failed for 'https://github.com/o/r.git/'\n",
         "fatal: Authentication failed for 'https://github.com/o/r.git/'"),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/o/missing.git/' not found\n",
         "fatal: repository 'https://github.com/o/missing.git/' not found"),
        (sshBoilerplate, "origin remote missing or unreachable"),
        ("", "origin remote missing or unreachable"),
    ])
    func anUnreachableOriginSaysWhyWithoutGitsBoilerplate(stderr: String, detail: String) async {
        let shell = ScriptedShell { $0.hasPrefix("git ls-remote") ? .fail(128, stderr) : .ok }
        let model = model(shell)
        await model.runAll()
        #expect(model.states[.remote] == .fail(detail))
    }

    @Test func applyingAnIdentityQuotesItAndReprobes() async {
        let identitySet = LockedFlag()
        let shell = ScriptedShell { script in
            if script.hasPrefix("git config --global") {
                identitySet.set(script == "git config --global user.name 'O'\\''Neil' && git config --global user.email 'o@example.invalid'")
                return .ok
            }
            if script.hasPrefix("git config --get") { return identitySet.value ? .out("O'Neil\no@example.invalid\n") : .fail(1) }
            return .out("ready")
        }
        let model = model(shell)
        await model.runAll()
        #expect(model.states[.identity] == .fail("git user.name / user.email are not set"))

        await model.applyIdentity(name: " O'Neil ", email: " o@example.invalid ")

        #expect(model.states[.identity] == .pass("O'Neil · o@example.invalid"))
        #expect(model.actionError == nil)
    }

    @Test func aBlankIdentityIsNotApplied() async {
        let shell = host()
        await model(shell).applyIdentity(name: "  ", email: "a@b.c")
        #expect(shell.scripts.isEmpty)
    }

    @Test(arguments: [
        ("[true,false]", WorktreeRepoSettingState.enabled, WorktreeRepoSettingState.disabled),
        ("[null,true]", .unavailable("hidden — needs push access"), .enabled),
        ("not json", .unavailable("unreadable — needs gh access to origin"), .unavailable("unreadable — needs gh access to origin")),
    ])
    func recommendedRepoSettingsAreReadInOneCall(json: String, deleteBranch: WorktreeRepoSettingState,
                                                 autoMerge: WorktreeRepoSettingState) async {
        let model = model(host(repoSettings: json))
        await model.probeRepoSettings()
        #expect(model.repoSettings[.deleteBranchOnMerge] == deleteBranch)
        #expect(model.repoSettings[.allowAutoMerge] == autoMerge)
    }

    /// Repo settings are informational; they never gate finalize.
    @Test func repoSettingsNeverGateAllPassed() async {
        let model = model(host(repoSettings: "[false,false]"))
        await model.runAll()
        await model.probeRepoSettings()
        #expect(model.allPassed)
    }

    @Test func enablingASettingThatNeedsAdminIsDisclosed() async {
        let model = model(ScriptedShell { $0.hasPrefix("gh repo edit") ? .fail(1, "HTTP 403") : .out("[false,false]") })
        await model.enableRepoSetting(.allowAutoMerge)
        #expect(model.repoSettings[.allowAutoMerge] == .unavailable("failed — repo admin required"))
    }

    // MARK: Remote hosts

    /// A remote host's checks run there: nothing executes on this Mac.
    @Test func remoteSetupUsesHostActionsAndNeverRunsLocalCommands() async {
        let local = ScriptedShell()
        let model = WorktreeSetupModel(repoPath: "/client/path")
        model.runner = { local.run($0, $1) }
        let actions = LockedList<RemoteWorktreeSetupAction>()
        model.remoteAction = { action in
            actions.append(action)
            let checks = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0.rawValue, RemoteWorktreeCheckState.pass("ok")) })
            return RemoteWorktreeSetup(repoPath: "/host/repo", checks: checks, repoSettings: ["allowAutoMerge": .enabled])
        }

        await model.runAll()
        await model.applyIdentity(name: " Host User ", email: " host@example.invalid ")
        await model.enableRepoSetting(.deleteBranchOnMerge)
        await model.installTools()

        #expect(local.scripts.isEmpty)
        #expect(model.repoPath == "/host/repo")
        #expect(model.allPassed)
        #expect(model.repoSettings[.allowAutoMerge] == .enabled)
        #expect(model.repoSettings[.deleteBranchOnMerge] == .unknown)
        #expect(actions.values == [.check, .applyIdentity(name: "Host User", email: "host@example.invalid"),
                                   .enableDeleteBranchOnMerge, .installCommandLineTools])
    }

    @Test func aDisconnectedHostSurfacesTheErrorAndResetsChecks() async {
        let model = WorktreeSetupModel(repoPath: "/client/path")
        model.remoteAction = { _ in throw GitWorktree.Failure(message: "host disconnected") }
        await model.runAll()
        #expect(model.actionError?.contains("host disconnected") == true)
        #expect(model.states.values.allSatisfy { $0 == .pending })
        #expect(!model.running)
    }
}

@Suite("Pull request descriptions")
struct PRDescriptionTests {
    @Test(arguments: [
        (false, false, false, false), (true, false, false, true),
        (true, true, false, false), (true, true, true, true), (false, true, true, false),
    ])
    func generationHonorsTheSettingAndExplicitRegeneration(enabled: Bool, prepared: Bool, force: Bool, generates: Bool) {
        #expect(WorktreePRDescriptionGenerator.shouldGenerate(enabled: enabled, prepared: prepared, force: force) == generates)
    }

    /// A generated description replaces only text the user hasn't edited.
    @Test func generatedTextNeverOverwritesUserEdits() {
        #expect(WorktreePRDescriptionGenerator.applying("generated", replacing: "", current: "user edit") == "user edit")
        #expect(WorktreePRDescriptionGenerator.applying("generated", replacing: "old", current: "old") == "generated")
    }

    private func generator(_ shell: ScriptedShell) -> WorktreePRDescriptionGenerator {
        var generator = WorktreePRDescriptionGenerator()
        generator.runner = { script, cwd, _ in shell.run(script, cwd) }
        return generator
    }

    @Test func piWritesTheDescriptionFromTheBranchContext() async {
        let shell = ScriptedShell { script in
            if script.contains("git log --format='- %s'") { return .out("- Add descriptions\n") }
            if script.contains("WORKTREE STATUS") { return .out("COMMITS\nAdd descriptions") }
            return .out("## Summary\n\nAdds generated PR descriptions.\n")
        }

        let result = await generator(shell).generate(base: "main", title: "Add descriptions", worktree: "/tmp/wt")

        #expect(result == .init(body: "## Summary\n\nAdds generated PR descriptions.", generated: true))
        let pi = shell.scripts.last ?? ""
        #expect(pi.hasPrefix("exec pi --print --no-session --no-tools --no-extensions"))
        #expect(pi.contains("PR title: Add descriptions"))
        #expect(shell.cwd(ofScriptStartingWith: "exec pi") == "/tmp/wt")
    }

    @Test func aFailedPiRunFallsBackToTheCommitSubjects() async {
        let shell = ScriptedShell { script in
            if script.contains("git log --format='- %s'") { return .out("- First change\n- Second change\n") }
            if script.contains("WORKTREE STATUS") { return .out("context") }
            return .fail(124, "timed out")
        }
        let result = await generator(shell).generate(base: "main", title: "Fallback", worktree: "/tmp/wt")
        #expect(result == .init(body: "- First change\n- Second change", generated: false))
    }

    @Test func withoutContextPiIsNotAskedAndTheTitleIsTheFallback() async {
        let shell = ScriptedShell { $0.contains("WORKTREE STATUS") ? .fail(128) : .ok }
        let result = await generator(shell).generate(base: "main", title: "Solo change", worktree: "/tmp/wt")
        #expect(result == .init(body: "- Solo change", generated: false))
        #expect(!shell.ran("exec pi"))
    }
}

@Suite("Shell quoting")
struct ShellQuotingTests {
    @Test(arguments: [
        ("plain", "'plain'"),
        ("fix 'the' thing", #"'fix '\''the'\'' thing'"#),
        ("", "''"),
        ("$HOME; rm -rf /", "'$HOME; rm -rf /'"),
    ])
    func valuesAreSingleQuotedWithEmbeddedQuotesEscaped(value: String, quoted: String) {
        #expect(shellQuoted(value) == quoted)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ value: Bool) { lock.withLock { flag = value } }
}

final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    var values: [Element] { lock.withLock { items } }
    func append(_ item: Element) { lock.withLock { items.append(item) } }
}
