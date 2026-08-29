import Foundation

/// Async login-shell runner for worktree setup probes and the finalize
/// pipeline. `zsh -l` resolves the user's PATH (gh, brew-installed git)
/// exactly like Shepherd's pi launch path. Prompting is disabled so a
/// missing credential fails fast instead of hanging a non-TTY child.
enum LoginShell {
    struct Output: Equatable, Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ script: String, cwd: String? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", script]
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GH_PROMPT_DISABLED"] = "1"
                process.environment = env
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: 127, stdout: "", stderr: error.localizedDescription))
                    return
                }
                // ponytail: sequential pipe drains can deadlock past 64KB of
                // stderr; git/gh diagnostics are far smaller. Stream if that
                // ever changes.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}

/// Single-quote a string for safe interpolation into a zsh script.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Setup checks (the finalize wizard's substance)

/// The prerequisites for a fully in-app finalize, probed in order. Each has
/// a user-facing remedy in `WorktreeSetupChecklist`.
enum WorktreeSetupCheck: String, CaseIterable, Identifiable {
    case git        // git resolvable (and Command Line Tools present for /usr/bin/git)
    case identity   // user.name + user.email
    case remote     // origin exists and is reachable with current credentials
    case gh         // GitHub CLI installed
    case ghAuth     // GitHub CLI authenticated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .git: return "git installed"
        case .identity: return "git identity"
        case .remote: return "origin reachable"
        case .gh: return "GitHub CLI"
        case .ghAuth: return "gh authenticated"
        }
    }
}

/// Recommended per-repo GitHub settings surfaced (never gated) by the
/// finalize setup view. Repo state, not app preferences — a Settings toggle
/// could neither read nor change 45 repositories truthfully.
enum WorktreeRepoSetting: String, CaseIterable, Identifiable {
    case deleteBranchOnMerge, allowAutoMerge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deleteBranchOnMerge: return "auto-delete merged branches"
        case .allowAutoMerge: return "allow auto-merge"
        }
    }

    var explanation: String {
        switch self {
        case .deleteBranchOnMerge:
            return "GitHub deletes the remote branch after its PR merges (restorable from the PR). Recommended — Shepherd never deletes remote branches itself."
        case .allowAutoMerge:
            return "Lets “Merge PR Automatically” wait for branch protection and checks instead of merging immediately. Only useful with required checks or reviews."
        }
    }

    var enableFlag: String {
        switch self {
        case .deleteBranchOnMerge: return "--delete-branch-on-merge"
        case .allowAutoMerge: return "--enable-auto-merge"
        }
    }
}

enum WorktreeRepoSettingState: Equatable {
    case unknown
    case checking
    case enabled
    case disabled
    case unavailable(String)
}

enum WorktreeCheckState: Equatable {
    case pending
    case checking
    case pass(String)
    case fail(String)

    var passed: Bool {
        if case .pass = self { return true }
        return false
    }
}

/// Probes the finalize prerequisites and applies the fixable remedies.
/// Repo-scoped: the `remote` check runs against the space's checkout.
@MainActor
final class WorktreeSetupModel: ObservableObject {
    @Published private(set) var states: [WorktreeSetupCheck: WorktreeCheckState]
    /// Recommended GitHub repo settings — informational, never gate `allPassed`.
    @Published private(set) var repoSettings: [WorktreeRepoSetting: WorktreeRepoSettingState]
    @Published private(set) var running = false
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
        states = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0, .pending) })
        repoSettings = Dictionary(uniqueKeysWithValues: WorktreeRepoSetting.allCases.map { ($0, .unknown) })
    }

    var allPassed: Bool {
        WorktreeSetupCheck.allCases.allSatisfy { states[$0]?.passed == true }
    }

    func runAll() async {
        guard !running else { return }
        running = true
        for check in WorktreeSetupCheck.allCases {
            states[check] = .checking
            states[check] = await probe(check)
        }
        running = false
    }

    /// Read both recommended settings in one REST call. gh resolves
    /// `{owner}/{repo}` from the checkout's origin remote. Needs gh auth —
    /// callers should probe only after the ghAuth check passes.
    func probeRepoSettings() async {
        for setting in WorktreeRepoSetting.allCases {
            repoSettings[setting] = .checking
        }
        let r = await LoginShell.run(
            "gh api 'repos/{owner}/{repo}' --jq '[.delete_branch_on_merge, .allow_auto_merge] | @json'",
            cwd: repoPath
        )
        guard r.status == 0,
              let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let values = try? JSONDecoder().decode([Bool?].self, from: data),
              values.count == 2 else {
            let reason = "unreadable — needs gh access to origin"
            for setting in WorktreeRepoSetting.allCases {
                repoSettings[setting] = .unavailable(reason)
            }
            return
        }
        repoSettings[.deleteBranchOnMerge] = state(for: values[0])
        repoSettings[.allowAutoMerge] = state(for: values[1])
    }

    private func state(for value: Bool?) -> WorktreeRepoSettingState {
        switch value {
        case .some(true): return .enabled
        case .some(false): return .disabled
        case .none: return .unavailable("hidden — needs push access")
        }
    }

    /// `gh repo edit <flag>` — admin-only on the repo; failure is disclosed,
    /// never retried silently.
    func enableRepoSetting(_ setting: WorktreeRepoSetting) async {
        repoSettings[setting] = .checking
        let r = await LoginShell.run("gh repo edit \(setting.enableFlag)", cwd: repoPath)
        guard r.status == 0 else {
            repoSettings[setting] = .unavailable("failed — repo admin required")
            return
        }
        await probeRepoSettings()
    }

    /// `git config --global` the identity, then re-probe that row.
    func applyIdentity(name: String, email: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else { return }
        _ = await LoginShell.run(
            "git config --global user.name \(shellQuoted(trimmedName)) && "
            + "git config --global user.email \(shellQuoted(trimmedEmail))"
        )
        states[.identity] = await probe(.identity)
    }

    /// Kick off Apple's Command Line Tools installer (its own GUI takes over).
    func installCommandLineTools() {
        Task.detached(priority: .utility) {
            _ = await LoginShell.run("xcode-select --install")
        }
    }

    private func probe(_ check: WorktreeSetupCheck) async -> WorktreeCheckState {
        switch check {
        case .git:
            let r = await LoginShell.run("""
                command -v git >/dev/null 2>&1 || exit 1
                if [ "$(command -v git)" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then exit 2; fi
                git --version
                """)
            if r.status == 0 {
                return .pass(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .fail(r.status == 2
                ? "Apple's Command Line Tools are not installed"
                : "git not found on PATH")
        case .identity:
            let r = await LoginShell.run(
                "git config --get user.name && git config --get user.email",
                cwd: repoPath
            )
            let parts = r.stdout.split(separator: "\n").map(String.init)
            if r.status == 0, parts.count == 2 {
                return .pass("\(parts[0]) · \(parts[1])")
            }
            return .fail("git user.name / user.email are not set")
        case .remote:
            let r = await LoginShell.run(
                "git ls-remote --quiet --heads origin >/dev/null",
                cwd: repoPath
            )
            if r.status == 0 { return .pass("origin reachable with your credentials") }
            let detail = r.stderr.split(separator: "\n").last.map(String.init)
            return .fail(detail ?? "origin remote missing or unreachable")
        case .gh:
            let r = await LoginShell.run("command -v gh >/dev/null 2>&1 && gh --version | head -1")
            if r.status == 0 {
                return .pass(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .fail("GitHub CLI not installed")
        case .ghAuth:
            // Documented contract: exit 0 = authenticated, 1 = auth issues,
            // 4 = authentication required. Never --json (always exits 0).
            let r = await LoginShell.run("gh auth status --hostname github.com 2>&1")
            if r.status == 0 {
                let account = r.stdout.split(separator: "\n")
                    .first { $0.contains("Logged in to") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return .pass(account ?? "authenticated")
            }
            return .fail("not authenticated — run gh auth login")
        }
    }
}

// MARK: - Finalize pipeline

/// The verified finalize pipeline: commit → push → PR (gh) → clean gate →
/// remove worktree → delete local branch. Every step gates the next; all
/// destruction sits after the clean gate, so a failure anywhere leaves the
/// work intact. The remote branch is never touched (deleting an open PR's
/// head branch closes the PR); GitHub's auto-delete-on-merge is the remote
/// cleanup. The Shepherd agent retires when the user closes the success
/// dialog, not mid-pipeline.
@MainActor
final class WorktreeFinalizer: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case commit, push, pullRequest, mergePR, verifyClean, removeWorktree, deleteBranch

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .commit: return "commit remaining work"
            case .push: return "push branch to origin"
            case .pullRequest: return "create pull request"
            case .mergePR: return "merge pull request"
            case .verifyClean: return "verify nothing is left behind"
            case .removeWorktree: return "remove worktree"
            case .deleteBranch: return "delete local branch"
            }
        }
    }

    enum StepState: Equatable {
        case pending
        case running
        case done(String)
        case skipped(String)
        case failed(String)
    }

    enum Phase: Equatable {
        case idle, running, succeeded, failed
    }

    struct Context {
        var repo: String
        var worktree: String
        var branch: String
        var base: String
        var title: String
        var body: String
        /// Settings ▸ Worktrees: off = a dirty worktree stops the pipeline
        /// instead of being committed automatically.
        var autoCommit = true
        /// Settings ▸ Worktrees: off = the local branch survives finalize.
        var deleteLocalBranch = true
        /// Settings ▸ Worktrees, **off by default**: merge the PR after
        /// creating it — GitHub auto-merge first, immediate merge fallback.
        var autoMergePR = false
        /// gh merge method flag ("squash") when autoMergePR is on.
        var mergeMethod = "squash"
    }

    @Published private(set) var states: [Step: StepState]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var prURL: String?

    /// Injectable for tests; production uses the login shell.
    var runner: (String, String?) async -> LoginShell.Output = { await LoginShell.run($0, cwd: $1) }
    /// Injectable clean gate; production is the same probe the delete dialog uses.
    var cleanCheck: (String, String) -> String? = GitWorktree.unreconciledWork

    init() {
        states = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    }

    func run(_ ctx: Context) async {
        guard phase == .idle else { return }
        phase = .running
        for step in Step.allCases {
            states[step] = .running
            let state = await perform(step, ctx: ctx)
            states[step] = state
            if case .failed = state {
                phase = .failed
                return
            }
        }
        phase = .succeeded
    }

    private func perform(_ step: Step, ctx: Context) async -> StepState {
        switch step {
        case .commit:
            let status = await runner("git status --porcelain", ctx.worktree)
            guard status.status == 0 else { return .failed(detail(status)) }
            guard !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .skipped("nothing to commit")
            }
            guard ctx.autoCommit else {
                return .failed("uncommitted changes, and auto-commit is off (Settings ▸ Worktrees) — commit in the worktree, then finalize")
            }
            let commit = await runner(
                "git add -A && git commit -m \(shellQuoted(ctx.title))",
                ctx.worktree
            )
            return commit.status == 0 ? .done("committed") : .failed(detail(commit))
        case .push:
            let push = await runner(
                "git push -u origin \(shellQuoted(ctx.branch))",
                ctx.worktree
            )
            return push.status == 0 ? .done("pushed") : .failed(detail(push))
        case .pullRequest:
            let body = ctx.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let create = await runner(
                "gh pr create --head \(shellQuoted(ctx.branch)) --base \(shellQuoted(ctx.base)) "
                + "--title \(shellQuoted(ctx.title)) --body \(shellQuoted(body.isEmpty ? ctx.title : body))",
                ctx.worktree
            )
            guard create.status == 0 else { return .failed(detail(create)) }
            let url = create.stdout.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("http") }
            prURL = url
            return .done(url ?? "created")
        case .mergePR:
            guard ctx.autoMergePR else { return .skipped("off — Settings ▸ Worktrees") }
            // Auto-merge first: it respects branch protection and required
            // checks (merges when they pass). GitHub rejects enabling it on
            // a PR that is already mergeable with no requirements — then an
            // immediate merge is exactly what "automatic merge" means.
            let auto = await runner(
                "gh pr merge \(shellQuoted(ctx.branch)) --\(ctx.mergeMethod) --auto",
                ctx.worktree
            )
            if auto.status == 0 { return .done("auto-merge enabled") }
            let direct = await runner(
                "gh pr merge \(shellQuoted(ctx.branch)) --\(ctx.mergeMethod)",
                ctx.worktree
            )
            if direct.status == 0 { return .done("merged") }
            // Best-effort by design: an unmergeable PR (failing checks,
            // required review) must not block cleanup — the work is pushed
            // and the PR stays open for a human.
            return .skipped("not merged — PR left open (\(detail(direct)))")
        case .verifyClean:
            if let leftover = cleanCheck(ctx.worktree, ctx.branch) {
                return .failed("\(leftover) — aborting before any cleanup")
            }
            return .done("clean")
        case .removeWorktree:
            // No --force: the clean gate just proved it, and git's own
            // refusal is the last-resort safety net.
            let remove = await runner(
                "git worktree remove \(shellQuoted(ctx.worktree))",
                ctx.repo
            )
            return remove.status == 0 ? .done("removed") : .failed(detail(remove))
        case .deleteBranch:
            guard ctx.deleteLocalBranch else {
                return .skipped("kept — Settings ▸ Worktrees")
            }
            // -D is safe only because verifyClean proved every commit is on
            // the remote; -d would refuse until the PR merges.
            let delete = await runner(
                "git branch -D \(shellQuoted(ctx.branch))",
                ctx.repo
            )
            return delete.status == 0 ? .done("deleted") : .failed(detail(delete))
        }
    }

    private func detail(_ output: LoginShell.Output) -> String {
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "exit \(output.status)" : out
    }
}
