import Foundation
import Testing
@testable import ShepherdApp

@Suite("Worktree finalize pipeline")
@MainActor
struct WorktreeFinalizeTests {
    private static func context() -> WorktreeFinalizer.Context {
        WorktreeFinalizer.Context(
            repo: "/tmp/repo",
            worktree: "/tmp/repo-worktree-x",
            branch: "worktree/x",
            base: "main",
            title: "Fix the thing",
            body: ""
        )
    }

    /// Happy path: every step runs in order, the PR URL is captured from gh
    /// stdout, and the pipeline succeeds.
    @Test func runsStepsInOrderAndCapturesPRURL() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("git status") {
                return .init(status: 0, stdout: " M file.txt\n", stderr: "")
            }
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/7\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.prURL == "https://github.com/o/r/pull/7")
        // Order: status, commit, push, pr, remove, branch delete (clean gate
        // is the injected closure, not a script).
        #expect(scripts.count == 6)
        #expect(scripts[0].hasPrefix("git status --porcelain"))
        #expect(scripts[1].hasPrefix("git add -A && git commit -m 'Fix the thing'"))
        #expect(scripts[2] == "git push -u origin 'worktree/x'")
        #expect(scripts[3].hasPrefix("gh pr create --head 'worktree/x' --base 'main'"))
        #expect(scripts[4] == "git worktree remove '/tmp/repo-worktree-x'")
        #expect(scripts[5] == "git branch -D 'worktree/x'")
        #expect(finalizer.states[.commit] == .done("committed"))
        #expect(finalizer.states[.verifyClean] == .done("clean"))
    }

    /// A clean worktree skips the commit but still pushes (the branch may
    /// hold committed-but-unpushed work).
    @Test func cleanWorktreeSkipsCommit() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/8\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.commit] == .skipped("nothing to commit"))
        #expect(!scripts.contains { $0.hasPrefix("git add") })
        #expect(scripts.contains { $0.hasPrefix("git push") })
    }

    /// A failed push stops everything: no PR, no destruction, later steps
    /// stay pending.
    @Test func failureStopsThePipelineBeforeAnyDestruction() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("git push") {
                return .init(status: 128, stdout: "", stderr: "fatal: could not read from remote")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[.push] == .failed("fatal: could not read from remote"))
        #expect(finalizer.states[.pullRequest] == .pending)
        #expect(finalizer.states[.removeWorktree] == .pending)
        #expect(!scripts.contains { $0.hasPrefix("gh pr create") })
        #expect(!scripts.contains { $0.hasPrefix("git worktree remove") })
        #expect(!scripts.contains { $0.hasPrefix("git branch -D") })
    }

    /// The clean gate blocks all destruction when work would be lost.
    @Test func dirtyGateBlocksCleanup() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in "1 commit only on this branch" }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/9\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[.verifyClean]
            == .failed("1 commit only on this branch — aborting before any cleanup"))
        #expect(!scripts.contains { $0.hasPrefix("git worktree remove") })
        #expect(!scripts.contains { $0.hasPrefix("git branch -D") })
    }

    /// Auto-commit off (Settings ▸ Worktrees): a dirty worktree stops the
    /// pipeline with guidance instead of committing on the user's behalf.
    @Test func autoCommitOffStopsOnDirtyWorktree() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("git status") {
                return .init(status: 0, stdout: " M file.txt\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        var ctx = Self.context()
        ctx.autoCommit = false

        await finalizer.run(ctx)

        #expect(finalizer.phase == .failed)
        if case .failed(let detail)? = finalizer.states[.commit] {
            #expect(detail.contains("auto-commit is off"))
        } else {
            Issue.record("commit step should have failed")
        }
        #expect(!scripts.contains { $0.hasPrefix("git add") })
        #expect(!scripts.contains { $0.hasPrefix("git push") })
    }

    /// Delete-local-branch off: the branch survives, everything else runs.
    @Test func deleteLocalBranchOffKeepsTheBranch() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/10\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        var ctx = Self.context()
        ctx.deleteLocalBranch = false

        await finalizer.run(ctx)

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.deleteBranch] == .skipped("kept — Settings ▸ Worktrees"))
        #expect(scripts.contains { $0.hasPrefix("git worktree remove") })
        #expect(!scripts.contains { $0.hasPrefix("git branch -D") })
    }

    /// Auto-merge off (the default): no gh merge command ever runs.
    @Test func mergeIsOffByDefault() async {
        let finalizer = WorktreeFinalizer()
        var scripts: [String] = []
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/11\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.mergePR] == .skipped("off — Settings ▸ Worktrees"))
        #expect(!scripts.contains { $0.hasPrefix("gh pr merge") })
    }

    /// Auto-merge on: GitHub auto-merge first; when it is rejected (no
    /// protection requirements), the immediate merge runs; when both fail,
    /// the PR is left open and cleanup continues anyway.
    @Test func mergeTriesAutoThenDirectAndNeverBlocksCleanup() async {
        // Case 1: --auto works.
        var finalizer = WorktreeFinalizer()
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/12\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        var ctx = Self.context()
        ctx.autoMergePR = true
        await finalizer.run(ctx)
        #expect(finalizer.states[.mergePR] == .done("auto-merge enabled"))

        // Case 2: --auto rejected, direct merge lands.
        finalizer = WorktreeFinalizer()
        finalizer.cleanCheck = { _, _ in nil }
        var mergeScripts: [String] = []
        finalizer.runner = { script, _ in
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/13\n", stderr: "")
            }
            if script.hasPrefix("gh pr merge") {
                mergeScripts.append(script)
                return script.contains("--auto")
                    ? .init(status: 1, stdout: "", stderr: "clean status")
                    : .init(status: 0, stdout: "", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        await finalizer.run(ctx)
        #expect(finalizer.states[.mergePR] == .done("merged"))
        #expect(mergeScripts == [
            "gh pr merge 'worktree/x' --squash --auto",
            "gh pr merge 'worktree/x' --squash",
        ])

        // Case 3: both fail — best-effort skip, pipeline still succeeds.
        finalizer = WorktreeFinalizer()
        finalizer.cleanCheck = { _, _ in nil }
        var scripts: [String] = []
        finalizer.runner = { script, _ in
            scripts.append(script)
            if script.hasPrefix("gh pr create") {
                return .init(status: 0, stdout: "https://github.com/o/r/pull/14\n", stderr: "")
            }
            if script.hasPrefix("gh pr merge") {
                return .init(status: 1, stdout: "", stderr: "required status checks have not passed")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        await finalizer.run(ctx)
        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.states[.mergePR]
            == .skipped("not merged — PR left open (required status checks have not passed)"))
        #expect(scripts.contains { $0.hasPrefix("git worktree remove") })
    }

    @Test func descriptionGenerationHonorsOptOutAndExplicitRegeneration() {
        #expect(!WorktreePRDescriptionGenerator.shouldGenerate(enabled: false, prepared: false, force: false))
        #expect(WorktreePRDescriptionGenerator.shouldGenerate(enabled: true, prepared: false, force: false))
        #expect(!WorktreePRDescriptionGenerator.shouldGenerate(enabled: true, prepared: true, force: false))
        #expect(WorktreePRDescriptionGenerator.shouldGenerate(enabled: true, prepared: true, force: true))
    }

    @Test func descriptionGenerationUsesPiOutput() async {
        var generator = WorktreePRDescriptionGenerator()
        var scripts: [String] = []
        generator.runner = { script, _, _ in
            scripts.append(script)
            if script.contains("git log --format='- %s'") {
                return .init(status: 0, stdout: "- Add descriptions\n", stderr: "")
            }
            if script.contains("WORKTREE STATUS") {
                return .init(status: 0, stdout: "COMMITS\nAdd descriptions\n\nDIFF STAT\n 2 files changed", stderr: "")
            }
            return .init(status: 0, stdout: "## Summary\n\nAdds generated PR descriptions.", stderr: "")
        }

        let result = await generator.generate(base: "main", title: "Add descriptions", worktree: "/tmp/worktree")

        #expect(result == .init(body: "## Summary\n\nAdds generated PR descriptions.", generated: true))
        #expect(scripts.count == 3)
        #expect(scripts[2].contains("pi --print"))
        #expect(scripts[2].contains("--model 'anthropic/claude-haiku-4-5'"))
    }

    @Test func descriptionGenerationFallsBackWhenPiFails() async {
        var generator = WorktreePRDescriptionGenerator()
        var piCalls = 0
        generator.runner = { script, _, timeout in
            if script.contains("git log --format='- %s'") {
                return .init(status: 0, stdout: "- First change\n- Second change\n", stderr: "")
            }
            if script.contains("WORKTREE STATUS") {
                return .init(status: 0, stdout: "context", stderr: "")
            }
            piCalls += 1
            #expect(timeout == 30)
            return .init(status: 124, stdout: "", stderr: "timed out")
        }

        let result = await generator.generate(base: "main", title: "Fallback", worktree: "/tmp/worktree")

        #expect(result == .init(body: "- First change\n- Second change", generated: false))
        #expect(piCalls == 1)
    }

    @Test func descriptionGenerationDoesNotOverwriteUserEdits() {
        #expect(WorktreePRDescriptionGenerator.applying(
            "generated", replacing: "", current: "user edit"
        ) == "user edit")
        #expect(WorktreePRDescriptionGenerator.applying(
            "generated", replacing: "old generated", current: "old generated"
        ) == "generated")
    }

    @Test func emptyDescriptionLetsGitHubUseTheRepositoryTemplate() async {
        let finalizer = WorktreeFinalizer()
        var createScript = ""
        finalizer.cleanCheck = { _, _ in nil }
        finalizer.runner = { script, _ in
            if script.hasPrefix("gh pr create") {
                createScript = script
                return .init(status: 0, stdout: "https://github.com/o/r/pull/15\n", stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }

        await finalizer.run(Self.context())

        #expect(!createScript.contains("--body"))
    }

    /// Titles with quotes must not break (or worse, escape) the shell script.
    @Test func shellQuotingSurvivesSingleQuotes() {
        #expect(shellQuoted("fix 'the' thing") == "'fix '\\''the'\\'' thing'")
        #expect(shellQuoted("plain") == "'plain'")
    }
}
