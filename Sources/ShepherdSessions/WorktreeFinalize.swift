import Foundation
import Observation
import ShepherdProtocol

/// Async login-shell runner for worktree setup probes and the finalize
/// pipeline. `zsh -l` resolves the user's PATH (gh, brew-installed git)
/// exactly like Shepherd's pi launch path. Prompting is disabled so a
/// missing credential fails fast instead of hanging a non-TTY child.
public enum LoginShell {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func set(stdout: Data) {
            lock.lock()
            self.stdout = stdout
            lock.unlock()
        }

        func set(stderr: Data) {
            lock.lock()
            self.stderr = stderr
            lock.unlock()
        }

        func output(status: Int32) -> Output {
            lock.lock()
            defer { lock.unlock() }
            return Output(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
    }

    public static func run(
        _ script: String,
        cwd: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Startup files can cd elsewhere; reselect the requested checkout before any command.
            let directory = cwd.map { "cd -- \(shellQuoted($0)) || exit\n" } ?? ""
            process.arguments = ["-l", "-c", directory + script]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GH_PROMPT_DISABLED"] = "1"
            process.environment = env
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let state = CompletionState()
            let captured = CapturedData()
            let reads = DispatchGroup()

            @Sendable func finish(_ output: Output) {
                guard state.claim() else { return }
                continuation.resume(returning: output)
            }

            // Register before launch so a fast exit cannot race completion setup.
            reads.enter()
            reads.enter()
            process.terminationHandler = { process in
                reads.notify(queue: .global(qos: .userInitiated)) {
                    finish(captured.output(status: process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                finish(Output(status: 127, stdout: "", stderr: error.localizedDescription))
                return
            }

            DispatchQueue.global().async {
                captured.set(stdout: out.fileHandleForReading.readDataToEndOfFile())
                reads.leave()
            }
            DispatchQueue.global().async {
                captured.set(stderr: err.fileHandleForReading.readDataToEndOfFile())
                reads.leave()
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard state.claim() else { return }
                    process.terminate()
                    continuation.resume(returning: Output(status: 124, stdout: "", stderr: "timed out"))
                }
            }
        }
    }
}

/// Single-quote a string for safe interpolation into a zsh script.
public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Setup checks (the finalize wizard's substance)

/// The prerequisites for a fully in-app finalize, probed in order. Each has
/// a user-facing remedy in `WorktreeSetupChecklist`.
public enum WorktreeSetupCheck: String, CaseIterable, Identifiable, Sendable {
    case git        // git resolvable (and Command Line Tools present for /usr/bin/git)
    case identity   // user.name + user.email
    case remote     // origin exists and is reachable with current credentials
    case gh         // GitHub CLI installed
    case ghAuth     // GitHub CLI authenticated

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .git: return "Git installed"
        case .identity: return "Git identity"
        case .remote: return "Origin reachable"
        case .gh: return "GitHub CLI"
        case .ghAuth: return "GitHub CLI signed in"
        }
    }
}

/// Recommended per-repo GitHub settings surfaced (never gated) by the
/// finalize setup view. Repo state, not app preferences — a Settings toggle
/// could neither read nor change 45 repositories truthfully.
public enum WorktreeRepoSetting: String, CaseIterable, Identifiable, Sendable {
    case deleteBranchOnMerge, allowAutoMerge

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .deleteBranchOnMerge: return "Auto-delete merged branches"
        case .allowAutoMerge: return "Allow auto-merge"
        }
    }

    public var explanation: String {
        switch self {
        case .deleteBranchOnMerge:
            return "GitHub deletes the remote branch after its PR merges (restorable from the PR). Recommended — Shepherd never deletes remote branches itself."
        case .allowAutoMerge:
            return "Lets “Merge PR Automatically” wait for branch protection and checks instead of merging immediately. Only useful with required checks or reviews."
        }
    }

    public var enableFlag: String {
        switch self {
        case .deleteBranchOnMerge: return "--delete-branch-on-merge"
        case .allowAutoMerge: return "--enable-auto-merge"
        }
    }
}

public typealias WorktreeRepoSettingState = RemoteWorktreeRepoSettingState
public typealias WorktreeCheckState = RemoteWorktreeCheckState

/// Probes the finalize prerequisites and applies the fixable remedies.
/// Repo-scoped: the `remote` check runs against the space's checkout.
@MainActor
@Observable
public final class WorktreeSetupModel {
    public private(set) var states: [WorktreeSetupCheck: WorktreeCheckState]
    /// Recommended GitHub repo settings — informational, never gate `allPassed`.
    public private(set) var repoSettings: [WorktreeRepoSetting: WorktreeRepoSettingState]
    public private(set) var running = false
    public private(set) var repoPath: String
    @ObservationIgnored public var remoteAction: ((RemoteWorktreeSetupAction) async throws -> RemoteWorktreeSetup)?
    public private(set) var actionError: String?
    @ObservationIgnored public var runner: (String, String?) async -> LoginShell.Output = { await LoginShell.run($0, cwd: $1, timeout: 20) }

    public var snapshot: RemoteWorktreeSetup {
        .init(repoPath: repoPath,
              checks: Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }),
              repoSettings: Dictionary(uniqueKeysWithValues: repoSettings.map { ($0.key.rawValue, $0.value) }))
    }

    private func performRemote(_ action: RemoteWorktreeSetupAction) async {
        guard let remoteAction else { return }
        running = true
        actionError = nil
        defer { running = false }
        do {
            let result = try await remoteAction(action)
            repoPath = result.repoPath
            states = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0, result.checks[$0.rawValue] ?? .pending) })
            repoSettings = Dictionary(uniqueKeysWithValues: WorktreeRepoSetting.allCases.map { ($0, result.repoSettings[$0.rawValue] ?? .unknown) })
        } catch {
            actionError = String(describing: error)
            if action == .check { states = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0, .pending) }) }
        }
    }

    public init(repoPath: String) {
        self.repoPath = repoPath
        states = Dictionary(uniqueKeysWithValues: WorktreeSetupCheck.allCases.map { ($0, .pending) })
        repoSettings = Dictionary(uniqueKeysWithValues: WorktreeRepoSetting.allCases.map { ($0, .unknown) })
    }

    public var allPassed: Bool {
        WorktreeSetupCheck.allCases.allSatisfy { states[$0]?.passed == true }
    }

    public func runAll() async {
        guard !running else { return }
        if remoteAction != nil { await performRemote(.check); return }
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
    public func probeRepoSettings() async {
        if remoteAction != nil { await performRemote(.check); return }
        for setting in WorktreeRepoSetting.allCases {
            repoSettings[setting] = .checking
        }
        let r = await runner(
            "gh api 'repos/{owner}/{repo}' --jq '[.delete_branch_on_merge, .allow_auto_merge] | @json'",
            repoPath
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
    public func enableRepoSetting(_ setting: WorktreeRepoSetting) async {
        if remoteAction != nil {
            await performRemote(setting == .deleteBranchOnMerge ? .enableDeleteBranchOnMerge : .enableAutoMerge)
            return
        }
        repoSettings[setting] = .checking
        let r = await runner("gh repo edit \(setting.enableFlag)", repoPath)
        guard r.status == 0 else {
            repoSettings[setting] = .unavailable("failed — repo admin required")
            return
        }
        await probeRepoSettings()
    }

    /// `git config --global` the identity, then re-probe that row.
    public func applyIdentity(name: String, email: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else { return }
        if remoteAction != nil { await performRemote(.applyIdentity(name: trimmedName, email: trimmedEmail)); return }
        let output = await runner(
            "git config --global user.name \(shellQuoted(trimmedName)) && "
            + "git config --global user.email \(shellQuoted(trimmedEmail))", nil
        )
        actionError = output.status == 0 ? nil : output.stderr
        states[.identity] = await probe(.identity)
    }

    /// Kick off Apple's Command Line Tools installer (its own GUI takes over).
    public func installCommandLineTools() {
        Task { await installTools() }
    }

    public func installTools() async {
        if remoteAction != nil { await performRemote(.installCommandLineTools); return }
        let output = await runner("xcode-select --install", nil)
        actionError = output.status == 0 ? nil : output.stderr
    }

    private func probe(_ check: WorktreeSetupCheck) async -> WorktreeCheckState {
        switch check {
        case .git:
            let r = await runner("""
                command -v git >/dev/null 2>&1 || exit 1
                if [ "$(command -v git)" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then exit 2; fi
                git --version
                """, nil)
            if r.status == 0 {
                return .pass(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .fail(r.status == 2
                ? "Apple's Command Line Tools are not installed"
                : "git not found on PATH")
        case .identity:
            let r = await runner(
                "git config --get user.name && git config --get user.email",
                repoPath
            )
            let parts = r.stdout.split(separator: "\n").map(String.init)
            if r.status == 0, parts.count == 2 {
                return .pass("\(parts[0]) · \(parts[1])")
            }
            return .fail("git user.name / user.email are not set")
        case .remote:
            let r = await runner(
                "git ls-remote --quiet --heads origin >/dev/null",
                repoPath
            )
            if r.status == 0 { return .pass("origin reachable with your credentials") }
            return .fail(Self.remoteFailureDetail(r.stderr) ?? "origin remote missing or unreachable")
        case .gh:
            let r = await runner("command -v gh >/dev/null 2>&1 && gh --version | head -1", nil)
            if r.status == 0 {
                return .pass(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .fail("GitHub CLI not installed")
        case .ghAuth:
            // Documented contract: exit 0 = authenticated, 1 = auth issues,
            // 4 = authentication required. Never --json (always exits 0).
            let r = await runner("gh auth status --hostname github.com 2>&1", nil)
            if r.status == 0 {
                let account = r.stdout.split(separator: "\n")
                    .first { $0.contains("Logged in to") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return .pass(account ?? "authenticated")
            }
            return .fail("not authenticated — run gh auth login")
        }
    }

    /// Why `git ls-remote` failed: its last line that is not git's closing boilerplate, which
    /// follows every SSH failure and says nothing about this one. nil when nothing else is left.
    public static func remoteFailureDetail(_ stderr: String) -> String? {
        stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !gitRemoteBoilerplate.contains($0) }
    }

    /// git's closing advice after a failed remote operation; it never names the problem.
    nonisolated public static let gitRemoteBoilerplate: Set<String> = [
        "fatal: Could not read from remote repository.",
        "Please make sure you have the correct access rights",
        "and the repository exists.",
    ]
}

public enum WorktreeCommitCount {
    public static func load(base: String, worktree: String) async -> Int? {
        let name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let result = await LoginShell.run(
            "git rev-list --count \(shellQuoted("origin/" + name))..HEAD 2>/dev/null "
                + "|| git rev-list --count \(shellQuoted(name))..HEAD 2>/dev/null",
            cwd: worktree, timeout: 20
        )
        guard result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Pull-request descriptions

public struct WorktreePRDescriptionGenerator {
    public struct Result: Equatable, Sendable {
        public var body: String
        public var generated: Bool

        public init(body: String, generated: Bool) {
            self.body = body
            self.generated = generated
        }
    }

    private static let defaultModels = [
        "anthropic/claude-haiku-4-5",
        "openai/gpt-5.1-codex-mini",
        "google/gemini-2.5-flash",
    ]

    /// Shepherd's pi, which drafts.
    public var pi: PiSetup
    public var runner: (String, String?, TimeInterval?) async -> LoginShell.Output = {
        await LoginShell.run($0, cwd: $1, timeout: $2)
    }
    /// Readies the pi home before a draft; false when no pi may start there.
    public var prepare: (PiSetup) async -> Bool = { pi in await Task.detached(priority: .userInitiated) { pi.prepare() == nil }.value }

    public init(pi: PiSetup) {
        self.pi = pi
    }

    public static func shouldGenerate(enabled: Bool, prepared: Bool, force: Bool) -> Bool {
        enabled && (force || !prepared)
    }

    public func generate(base: String, title: String, worktree: String) async -> Result {
        let localBase = shellQuoted(base)
        let remoteBase = shellQuoted("origin/" + base)
        let resolveBase = "base=\(remoteBase); git rev-parse --verify \"$base\" >/dev/null 2>&1 || base=\(localBase)"
        let commits = await runner(
            "\(resolveBase); git log --format='- %s' \"$base\"..HEAD | head -c 8000",
            worktree,
            20
        )
        let fallback = commits.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBody = fallback.isEmpty ? "- \(title)" : fallback

        let context = await runner(
            """
            \(resolveBase)
            printf 'COMMITS\\n'
            git log --format='%s%n%b' "$base"..HEAD | head -c 8000
            printf '\\n\\nWORKTREE STATUS\\n'
            git status --short | head -c 4000
            printf '\\n\\nDIFF STAT\\n'
            git diff --stat "$base" | head -c 4000
            printf '\\n\\nPATCH EXCERPT\\n'
            git diff --no-ext-diff --unified=2 "$base" | head -c 16000
            """,
            worktree,
            20
        )
        guard context.status == 0 else { return Result(body: fallbackBody, generated: false) }

        let prompt = """
            Write a concise Markdown pull request description from the repository context below.
            Return only the description. Use these headings when they add useful information:
            ## Summary
            ## Behavior
            ## Implementation
            ## Testing
            Omit empty sections. State only facts supported by the context. Do not include a title.

            PR title: \(title)

            \(context.stdout.prefix(32_000))
            """
        guard await prepare(pi) else { return Result(body: fallbackBody, generated: false) }
        let output = await runner(Self.draftCommand(prompt: prompt, home: pi.files), worktree, 30)
        let body = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !body.isEmpty else {
            return Result(body: fallbackBody, generated: false)
        }
        return Result(body: String(body.prefix(12_000)), generated: true)
    }

    /// `pi --print` with the prompt alone, on the drafting model (`SHEPHERD_PR_DESCRIPTION_MODEL`,
    /// else the first default): no session, tools, extensions or context files. PR descriptions
    /// and commit messages from review are drafted this way.
    public static func draftCommand(prompt: String, home: PiHome) -> String {
        let model = ProcessInfo.processInfo.environment["SHEPHERD_PR_DESCRIPTION_MODEL"]
            .flatMap { $0.split(separator: ",").first.map(String.init) }
            ?? defaultModels[0]
        return PiLaunch.draft(home: home, model: model, prompt: prompt).script
    }

    public static func applying(_ generated: String, replacing original: String, current: String) -> String {
        current == original ? generated : current
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
@Observable
public final class WorktreeFinalizer {
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case commit, push, pullRequest, mergePR, verifyClean, removeWorktree, deleteBranch

        public var id: Int { rawValue }

        public var label: String {
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

    public enum StepState: Equatable, Sendable {
        case pending
        case running
        case done(String)
        case skipped(String)
        case failed(String)
    }

    public enum Phase: Equatable, Sendable {
        case idle, running, succeeded, failed
    }

    public struct Context: Sendable {
        public var repo: String
        public var worktree: String
        public var branch: String
        public var base: String
        public var title: String
        public var body: String
        /// Settings ▸ Worktrees: off = a dirty worktree stops the pipeline
        /// instead of being committed automatically.
        public var autoCommit = true
        /// Settings ▸ Worktrees: off = the local branch survives finalize.
        public var deleteLocalBranch = true
        /// Settings ▸ Worktrees, **off by default**: merge the PR after
        /// creating it — GitHub auto-merge first, immediate merge fallback.
        public var autoMergePR = false
        /// gh merge method flag ("squash") when autoMergePR is on.
        public var mergeMethod = "squash"
        /// The Finalize plan's ticks (BranchFinalizePlan): an unticked step is skipped. Removing
        /// covers the clean check, the worktree and the local branch.
        public var commit = true
        public var push = true
        public var pullRequest = true
        public var remove = true
        /// The commit's message; the pull request's title when nil.
        public var commitMessage: String?

        public init(repo: String, worktree: String, branch: String, base: String, title: String, body: String,
                    autoCommit: Bool = true, deleteLocalBranch: Bool = true, autoMergePR: Bool = false,
                    mergeMethod: String = "squash", commit: Bool = true, push: Bool = true,
                    pullRequest: Bool = true, remove: Bool = true, commitMessage: String? = nil) {
            self.repo = repo; self.worktree = worktree; self.branch = branch; self.base = base
            self.title = title; self.body = body; self.autoCommit = autoCommit
            self.deleteLocalBranch = deleteLocalBranch; self.autoMergePR = autoMergePR
            self.mergeMethod = mergeMethod; self.commit = commit; self.push = push
            self.pullRequest = pullRequest; self.remove = remove; self.commitMessage = commitMessage
        }
    }

    public private(set) var states: [Step: StepState]
    public private(set) var phase: Phase = .idle
    public private(set) var prURL: String?

    /// Injectable for tests; production uses the login shell.
    @ObservationIgnored public var runner: (String, String?) async -> LoginShell.Output = { await LoginShell.run($0, cwd: $1) }
    /// Injectable clean gate; production is the same probe the delete dialog uses.
    @ObservationIgnored public var cleanCheck: (String, String) -> String? = GitWorktree.unreconciledWork

    @ObservationIgnored public var beforeCleanup: (() async throws -> Void)?

    public init() {
        states = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    }

    /// A pipeline already at `steps` (unlisted steps pending), for previews; it never runs.
    public init(staged steps: [Step: StepState], prURL: String? = nil) {
        states = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, steps[$0] ?? .pending) })
        self.prURL = prURL
        let failed = steps.values.contains { if case .failed = $0 { true } else { false } }
        phase = failed ? .failed : states.values.contains { $0 == .pending || $0 == .running } ? .running : .succeeded
    }

    public func run(_ ctx: Context) async {
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
            guard ctx.commit else { return .skipped("not in the plan") }
            let status = await runner("git status --porcelain", ctx.worktree)
            guard status.status == 0 else { return .failed(detail(status)) }
            guard !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .skipped("nothing to commit")
            }
            guard ctx.autoCommit else {
                return .failed("uncommitted changes, and auto-commit is off (Settings ▸ Worktrees) — commit in the worktree, then finalize")
            }
            let commit = await runner(
                "git add -A && git commit -m \(shellQuoted(ctx.commitMessage ?? ctx.title))",
                ctx.worktree
            )
            return commit.status == 0 ? .done("committed") : .failed(detail(commit))
        case .push:
            guard ctx.push else { return .skipped("not in the plan") }
            let push = await runner(
                "git push -u origin \(shellQuoted(ctx.branch))",
                ctx.worktree
            )
            return push.status == 0 ? .done("pushed") : .failed(detail(push))
        case .pullRequest:
            guard ctx.pullRequest else { return .skipped("not in the plan") }
            let body = ctx.body.trimmingCharacters(in: .whitespacesAndNewlines)
            var command = "gh pr create --head \(shellQuoted(ctx.branch)) --base \(shellQuoted(ctx.base)) "
                + "--title \(shellQuoted(ctx.title))"
            if !body.isEmpty { command += " --body \(shellQuoted(body))" }
            let create = await runner(command, ctx.worktree)
            guard create.status == 0 else { return .failed(detail(create)) }
            let url = create.stdout.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("http") }
            prURL = url
            return .done(url ?? "created")
        case .mergePR:
            guard ctx.autoMergePR, ctx.pullRequest else { return .skipped("not in the plan") }
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
            guard ctx.remove else { return .skipped("worktree kept") }
            if let leftover = cleanCheck(ctx.worktree, ctx.branch) {
                return .failed("\(leftover) — aborting before any cleanup")
            }
            return .done("clean")
        case .removeWorktree:
            guard ctx.remove else { return .skipped("worktree kept") }
            do { try await beforeCleanup?() }
            catch { return .failed(String(describing: error)) }
            // No --force: the clean gate just proved it, and git's own
            // refusal is the last-resort safety net.
            let remove = await runner(
                "git worktree remove \(shellQuoted(ctx.worktree))",
                ctx.repo
            )
            return remove.status == 0 ? .done("removed") : .failed(detail(remove))
        case .deleteBranch:
            guard ctx.remove else { return .skipped("worktree kept") }
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

    private func detail(_ output: LoginShell.Output) -> String { Self.failureDetail(output) }

    /// A failed step's text: stderr, else stdout, else the exit status. The sheet shows only the
    /// first line (the rest is its tooltip), so the line that names the problem moves to the
    /// front: a rejected ref, else the first `fatal:`/`error:` that isn't git's closing
    /// boilerplate, ahead of the `To <remote>` header and hints.
    public static func failureDetail(_ output: LoginShell.Output) -> String {
        let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = err.isEmpty ? out : err
        guard !text.isEmpty else { return "exit \(output.status)" }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = lines.indices.filter { !WorktreeSetupModel.gitRemoteBoilerplate.contains(lines[$0]) }
        let telling = candidates.first { lines[$0].hasPrefix("! [") }
            ?? candidates.first { index in ["fatal:", "error:"].contains { lines[index].lowercased().hasPrefix($0) } }
        var reordered = lines
        if let telling, telling > 0 { reordered.insert(reordered.remove(at: telling), at: 0) }
        // git pads its ref columns ("! [rejected]        a -> a"); the one-line summary doesn't.
        reordered[0] = reordered[0].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return reordered.joined(separator: "\n")
    }
}
