import CryptoKit
import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote

// A direct commit from review (AGENTS.md › Only these paths mutate repositories): the files the
// reviewer ticked, with the message they confirmed, then optionally a push to the branch's
// upstream (set when there is none) or a pushed branch with a pull request (gh). Each step gates
// the next, git's own stderr is reported, nothing is ever forced, and no file outside the
// selection is staged or committed. The checkout is refused on a detached HEAD, with a merge,
// rebase, cherry-pick or revert in progress, or with unmerged paths; a file that changed after
// the sheet showed it (or a HEAD that moved) stops the commit before anything runs.

/// What the review's checkout says about itself, and the reads the sheet needs.
enum ReviewCommitGit {
    typealias Runner = (String, String?) async -> LoginShell.Output

    struct Checkout: Equatable {
        var root: String
        var branch: String?
        var head: String
        /// The upstream as `remote/branch`, and its parts from the branch's config.
        var upstream: String?
        var upstreamRemote: String?
        var upstreamMerge: String?
        var remotes: [String]
        /// `refs/remotes/<remote>/HEAD`'s target per remote, and the main/master branches known.
        var remoteHeads: [String]
        var busy: [String]
        var unmerged: Bool

        /// The remote a push without an upstream goes to: the upstream's, else origin, else the
        /// only one.
        var pushRemote: String? {
            if let upstreamRemote, upstreamRemote != "." { return upstreamRemote }
            if remotes.contains("origin") { return "origin" }
            return remotes.count == 1 ? remotes[0] : nil
        }

        /// The upstream when it is a remote's branch (a local upstream is never pushed to).
        var remoteUpstream: (remote: String, merge: String)? {
            guard let upstreamRemote, upstreamRemote != ".", let upstreamMerge, !upstreamMerge.isEmpty else { return nil }
            return (upstreamRemote, upstreamMerge)
        }

        /// The branch a pull request goes into: the push remote's HEAD, else its main or master.
        var defaultBranch: String? {
            guard let remote = pushRemote else { return nil }
            let prefix = remote + "/"
            let names = remoteHeads.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            return names.first
        }

        /// Why a commit can't run here.
        var blocked: String? {
            if branch == nil { return "HEAD is detached. Check out a branch to commit from review." }
            if let state = busy.first {
                let what = switch state {
                case "MERGE_HEAD": "A merge"
                case "CHERRY_PICK_HEAD": "A cherry-pick"
                case "REVERT_HEAD": "A revert"
                default: "A rebase"
                }
                return "\(what) is in progress in this checkout. Finish or abort it first."
            }
            if unmerged { return "The checkout has unmerged paths. Resolve them first." }
            return nil
        }
    }

    /// One read of the checkout. POSIX sh, so the login shell and the tests' `sh` agree.
    static let inspectScript = """
        root=$(git rev-parse --show-toplevel) || exit 3
        cd "$root" || exit 3
        echo "root=$root"
        branch=$(git symbolic-ref -q --short HEAD)
        echo "branch=$branch"
        echo "head=$(git rev-parse -q --verify HEAD)"
        if [ -n "$branch" ]; then
          if u=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then echo "upstream=$u"; fi
          echo "upremote=$(git config --get "branch.$branch.remote")"
          echo "upmerge=$(git config --get "branch.$branch.merge")"
        fi
        for r in $(git remote); do
          echo "remote=$r"
          h=$(git symbolic-ref -q --short "refs/remotes/$r/HEAD")
          if [ -n "$h" ]; then echo "remotehead=$h"; fi
          for b in main master; do
            if git show-ref -q --verify "refs/remotes/$r/$b"; then echo "remotehead=$r/$b"; fi
          done
        done
        for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
          if [ -e "$(git rev-parse --git-path "$f")" ]; then echo "busy=$f"; fi
        done
        if [ -n "$(git ls-files -u | head -n 1)" ]; then echo "unmerged=1"; fi
        """

    static func parseCheckout(_ output: String) -> Checkout? {
        var values: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]), default: []].append(String(line[line.index(after: equals)...]))
        }
        func one(_ key: String) -> String? { values[key]?.first.flatMap { $0.isEmpty ? nil : $0 } }
        guard let root = one("root") else { return nil }
        var heads: [String] = []
        for head in values["remotehead"] ?? [] where !head.isEmpty && !heads.contains(head) { heads.append(head) }
        return Checkout(root: root, branch: one("branch"), head: one("head") ?? "", upstream: one("upstream"),
                        upstreamRemote: one("upremote"), upstreamMerge: one("upmerge"),
                        remotes: (values["remote"] ?? []).filter { !$0.isEmpty }, remoteHeads: heads,
                        busy: values["busy"] ?? [], unmerged: one("unmerged") != nil)
    }

    @MainActor static func inspect(cwd: String, runner: Runner) async throws -> Checkout {
        let output = await runner(inspectScript, cwd)
        guard output.status == 0, let checkout = parseCheckout(output.stdout) else {
            throw ReviewCommitRefusal("Not a git repository: \(WorktreeFinalizer.failureDetail(output))")
        }
        return checkout
    }

    /// What the sheet shows: the checkout, the review's files with their fingerprints, and a
    /// plain message written from the file list.
    @MainActor static func info(cwd: String, agentWorking: Bool, draftsMessage: Bool, runner: @escaping Runner) async throws -> RemoteCommitInfo {
        let checkout = try await inspect(cwd: cwd, runner: runner)
        let root = checkout.root
        let files = try await Task.detached {
            try reviewCommitFiles(GitDiff.load(cwd: root, reference: nil)) { _ in "" }.map { file in
                var file = file
                file.fingerprint = fingerprint(root: root, paths: file.paths)
                return file
            }
        }.value
        let message = reviewCommitFallbackMessage(files)
        return RemoteCommitInfo(repository: root, branch: checkout.branch, head: checkout.head, upstream: checkout.upstream,
                                pushRemote: checkout.pushRemote, defaultBranch: checkout.defaultBranch, files: files,
                                title: message.title, body: message.body, draftsMessage: draftsMessage && !files.isEmpty,
                                agentWorking: agentWorking, blocked: checkout.blocked)
    }

    /// The working tree's content at `paths`, as the host sees it: what a file is (or that it is
    /// gone) and its bytes. The commit runs only while every selected file still matches.
    static func fingerprint(root: String, paths: [String]) -> String {
        var digest = SHA256()
        func add(_ value: String) { digest.update(data: Data((value + "\0").utf8)) }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        for path in Set(paths).sorted() {
            add(path)
            let url = base.appendingPathComponent(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else { add("missing"); continue }
            add(type.rawValue)
            add(String(describing: attributes[.posixPermissions]))
            if type == .typeSymbolicLink {
                add((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
            } else if type == .typeRegular, let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                while let bytes = try? handle.read(upToCount: 256 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A path the commit may take: relative to the repository, inside it.
    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\0")
    }

    // MARK: The message

    /// The diff of `paths` for the model: each file's header, then its hunks, cut at `limit`.
    static func promptContext(_ files: [DiffFile], limit: Int = 16_000) -> String {
        var text = ""
        for file in files {
            let status = ReviewFileStatus(file).letter
            text += "\(status) \(file.displayPath) (+\(file.addedCount) -\(file.removedCount))\n"
        }
        text += "\n"
        for file in files where !file.isBinary {
            text += "--- \(file.displayPath)\n"
            for hunk in file.hunks {
                text += hunk.header + "\n"
                for line in hunk.lines {
                    text += (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text + "\n"
                }
                if text.count > limit { break }
            }
            if text.count > limit { break }
        }
        return String(text.prefix(limit))
    }

    static func prompt(context: String) -> String {
        """
        Write a git commit message for the change below.
        Line 1: a summary in the imperative mood, at most 72 characters, with no trailing period.
        Then a blank line and a body of one to three short sentences on what changed and why.
        Leave the body out for a trivial change.
        Return only the message: no quotes, labels, code fences or Markdown headings.
        State only facts the diff supports.

        \(context)
        """
    }

    /// A message drafted from the diff of `paths` by the model that drafts PR descriptions,
    /// else the plain one written from the file list.
    @MainActor static func draftMessage(root: String, paths: [String], runner: @escaping Runner) async -> (title: String, body: String, drafted: Bool) {
        let wanted = Set(paths)
        let files = (try? await Task.detached { try GitDiff.load(cwd: root, reference: nil) }.value) ?? []
        let chosen = files.filter { file in [file.oldPath, file.newPath, file.displayPath].contains { $0.map(wanted.contains) ?? false } }
        let fallback = reviewCommitFallbackMessage(reviewCommitFiles(chosen) { _ in "" })
        guard !chosen.isEmpty else { return (fallback.title, fallback.body, false) }
        let output = await runner(WorktreePRDescriptionGenerator.draftCommand(prompt: prompt(context: promptContext(chosen))), root)
        guard output.status == 0, let message = reviewCommitMessage(fromModel: output.stdout) else {
            return (fallback.title, fallback.body, false)
        }
        return (message.title, String(message.body.prefix(4_000)), true)
    }
}

/// The commit pipeline: check → (new branch) → commit → (push) → (pull request). Each step gates
/// the next and a failure stops everything after it. A failed commit takes back what it staged
/// for new files and, when it created a branch, returns to the branch it started on.
@MainActor
@Observable
final class ReviewCommitter {
    enum Step: Hashable {
        case check
        case branch(String)
        case commit(Int)
        case push(String)
        case pullRequest(String?)

        var label: String {
            switch self {
            case .check: ReviewCommitStepLabel.check
            case .branch(let name): ReviewCommitStepLabel.branch(name)
            case .commit(let count): ReviewCommitStepLabel.commit(count)
            case .push(let target): ReviewCommitStepLabel.push(target)
            case .pullRequest(let base): ReviewCommitStepLabel.pullRequest(base)
            }
        }
    }

    typealias StepState = WorktreeFinalizer.StepState
    typealias Phase = WorktreeFinalizer.Phase

    private(set) var steps: [Step] = [.check]
    private(set) var states: [Step: StepState] = [:]
    private(set) var phase: Phase = .idle
    private(set) var prURL: String?
    private(set) var commitID: String?
    /// What went wrong, and what is left as it was.
    private(set) var failure: String?

    @ObservationIgnored var runner: ReviewCommitGit.Runner = { await LoginShell.run($0, cwd: $1) }

    /// The progress lines a remote client reads (`finalizeSteps`).
    var progress: [String] {
        steps.map { step in
            let detail = switch states[step] ?? .pending {
            case .pending: "pending"
            case .running: "working…"
            case .done(let text), .skipped(let text): text
            case .failed(let text): "failed: \(text)"
            }
            return "\(step.label): \(detail)"
        }
    }

    func run(_ options: RemoteCommitOptions, cwd: String) async {
        guard phase == .idle else { return }
        phase = .running
        states[.check] = .running
        let plan: Plan
        do {
            plan = try await check(options, cwd: cwd)
        } catch {
            fail(.check, String(describing: error), summary: "Nothing was committed.")
            return
        }
        steps = plan.steps
        states[.check] = .done(plan.checkDetail)
        for step in plan.steps.dropFirst() {
            states[step] = .running
            let result = await perform(step, plan: plan)
            states[step] = result.state
            if case .failed(let text) = result.state {
                fail(step, text, summary: result.summary)
                return
            }
        }
        phase = .succeeded
    }

    private func fail(_ step: Step, _ text: String, summary: String) {
        states[step] = .failed(text)
        failure = summary
        phase = .failed
    }

    // MARK: Check

    private struct Plan {
        var root: String
        var branch: String
        var steps: [Step]
        var checkDetail: String
        var files: [RemoteCommitFile]
        var message: (title: String, body: String)
        /// Where the push goes: `remote` and the refspec, and whether it sets the upstream.
        var push: (remote: String, refspec: String, setsUpstream: Bool)?
        var pullRequest: (head: String, base: String)?
        var newBranch: String?
    }

    private func check(_ options: RemoteCommitOptions, cwd: String) async throws -> Plan {
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ReviewCommitRefusal("Write a commit message.") }
        guard !options.files.isEmpty else { throw ReviewCommitRefusal("Choose at least one file.") }
        let paths = options.files.flatMap(\.paths)
        guard paths.allSatisfy(ReviewCommitGit.isSafePath) else { throw ReviewCommitRefusal("A file's path is outside the repository.") }
        let checkout = try await ReviewCommitGit.inspect(cwd: cwd, runner: runner)
        if let blocked = checkout.blocked { throw ReviewCommitRefusal(blocked) }
        guard let branch = checkout.branch else { throw ReviewCommitRefusal("HEAD is detached.") }
        guard checkout.head == options.head else {
            throw ReviewCommitRefusal("HEAD moved since the sheet opened (now \(checkout.head.prefix(7))). Open Commit again.")
        }
        let root = checkout.root
        for file in options.files {
            let current = await Task.detached { ReviewCommitGit.fingerprint(root: root, paths: file.paths) }.value
            guard current == file.fingerprint else {
                throw ReviewCommitRefusal("\(file.path) changed since the sheet opened. Open Commit again to see it.")
            }
        }
        var steps: [Step] = [.check]
        var push: (String, String, Bool)?
        var pullRequest: (String, String)?
        var newBranch: String?
        switch options.push {
        case .none:
            steps.append(.commit(options.files.count))
        case .upstream:
            steps.append(.commit(options.files.count))
            if let upstream = checkout.remoteUpstream {
                push = (upstream.remote, "HEAD:" + upstream.merge, false)
                steps.append(.push(checkout.upstream ?? "\(upstream.remote)/\(Self.short(upstream.merge))"))
            } else if let remote = checkout.pushRemote {
                push = (remote, branch, true)
                steps.append(.push("\(remote)/\(branch)"))
            } else {
                throw ReviewCommitRefusal("This branch has no remote to push to.")
            }
        case .pullRequest:
            guard let base = checkout.defaultBranch, let remote = checkout.pushRemote else {
                throw ReviewCommitRefusal("A pull request needs a remote and its default branch.")
            }
            var head = branch
            if branch == base {
                guard let name = options.newBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw ReviewCommitRefusal("A pull request from \(base) needs a new branch.")
                }
                let valid = await runner("git check-ref-format --branch \(shellQuoted(name)) >/dev/null", root)
                guard valid.status == 0 else { throw ReviewCommitRefusal("\(name) is not a valid branch name.") }
                let exists = await runner("git show-ref -q --verify \(shellQuoted("refs/heads/" + name))", root)
                guard exists.status != 0 else { throw ReviewCommitRefusal("A branch named \(name) already exists.") }
                newBranch = name
                head = name
                steps.append(.branch(name))
            }
            steps.append(.commit(options.files.count))
            if newBranch == nil, let upstream = checkout.remoteUpstream {
                push = (upstream.remote, "HEAD:" + upstream.merge, false)
                head = Self.short(upstream.merge)
                steps.append(.push(checkout.upstream ?? "\(upstream.remote)/\(head)"))
            } else {
                push = (remote, head, true)
                steps.append(.push("\(remote)/\(head)"))
            }
            pullRequest = (head, base)
            steps.append(.pullRequest(base))
        }
        return Plan(root: root, branch: branch, steps: steps, checkDetail: "on \(branch)", files: options.files,
                    message: (title, options.body.trimmingCharacters(in: .whitespacesAndNewlines)),
                    push: push.map { (remote: $0.0, refspec: $0.1, setsUpstream: $0.2) },
                    pullRequest: pullRequest.map { (head: $0.0, base: $0.1) }, newBranch: newBranch)
    }

    private static func short(_ merge: String) -> String {
        merge.hasPrefix("refs/heads/") ? String(merge.dropFirst("refs/heads/".count)) : merge
    }

    // MARK: Steps

    private func perform(_ step: Step, plan: Plan) async -> (state: StepState, summary: String) {
        switch step {
        case .check:
            return (.done(plan.checkDetail), "")
        case .branch(let name):
            // A new branch at HEAD: the working tree and index stay exactly as they are.
            let result = await runner("git switch -q -c \(shellQuoted(name))", plan.root)
            return result.status == 0 ? (.done("created"), "") : (.failed(detail(result)), "Nothing was committed.")
        case .commit:
            return await commit(plan)
        case .push:
            guard let push = plan.push else { return (.skipped("off"), "") }
            // Never forced: a rejected push stops here with git's reason.
            let command = "git push \(push.setsUpstream ? "-u " : "")\(shellQuoted(push.remote)) \(shellQuoted(push.refspec))"
            let result = await runner(command, plan.root)
            let committed = commitID.map { "Committed \($0) on \(plan.newBranch ?? plan.branch)" } ?? "Committed"
            return result.status == 0 ? (.done("pushed"), "") : (.failed(detail(result)), "\(committed); the push failed. Nothing else changed.")
        case .pullRequest:
            guard let pr = plan.pullRequest else { return (.skipped("off"), "") }
            var command = "gh pr create --head \(shellQuoted(pr.head)) --base \(shellQuoted(pr.base)) --title \(shellQuoted(plan.message.title))"
            command += " --body \(shellQuoted(plan.message.body))"
            let result = await runner(command, plan.root)
            guard result.status == 0 else {
                return (.failed(detail(result)), "Committed and pushed \(pr.head); opening the pull request failed. Open it on GitHub.")
            }
            prURL = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("http") }
            return (.done(prURL ?? "opened"), "")
        }
    }

    private func commit(_ plan: Plan) async -> (state: StepState, summary: String) {
        let paths = plan.files.flatMap(\.paths)
        let quoted = paths.map(shellQuoted).joined(separator: " ")
        // New files join the index as intent-to-add, so `--only` can take them; nothing else
        // is staged, and anything staged for other paths stays as it was.
        let untrackedList = await runner("git --literal-pathspecs ls-files -z --others -- \(quoted)", plan.root)
        guard untrackedList.status == 0 else { return await undo(detail(untrackedList), plan: plan, added: []) }
        let untracked = untrackedList.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        if !untracked.isEmpty {
            let add = await runner("git --literal-pathspecs add -N -- \(untracked.map(shellQuoted).joined(separator: " "))", plan.root)
            guard add.status == 0 else { return await undo(detail(add), plan: plan, added: untracked) }
        }
        var message = "-m \(shellQuoted(plan.message.title))"
        if !plan.message.body.isEmpty { message += " -m \(shellQuoted(plan.message.body))" }
        let commit = await runner("git --literal-pathspecs commit -q \(message) --only -- \(quoted)", plan.root)
        guard commit.status == 0 else { return await undo(detail(commit), plan: plan, added: untracked) }
        let head = await runner("git rev-parse --short HEAD", plan.root)
        commitID = head.status == 0 ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return (.done(commitID.map { "committed \($0)" } ?? "committed"), "")
    }

    /// Takes back what a failed commit changed: intent-to-add entries for new files, and a branch
    /// it created (still at the commit it started from, so switching back loses nothing).
    private func undo(_ reason: String, plan: Plan, added: [String]) async -> (state: StepState, summary: String) {
        if !added.isEmpty {
            _ = await runner("git --literal-pathspecs reset -q -- \(added.map(shellQuoted).joined(separator: " "))", plan.root)
        }
        if let name = plan.newBranch {
            let back = await runner("git switch -q \(shellQuoted(plan.branch))", plan.root)
            if back.status == 0 { _ = await runner("git branch -d -q \(shellQuoted(name))", plan.root) }
        }
        return (.failed(reason), "Nothing was committed; the files are as they were.")
    }

    private func detail(_ output: LoginShell.Output) -> String { WorktreeFinalizer.failureDetail(output) }
}
