import Foundation
import ShepherdCore
import ShepherdProtocol

/// The git a dispatch needs, blocking: call it off the server queue. Every command is bounded, never
/// prompts, and reads or writes only what the plan allows (`git fetch origin` and the worktree the
/// thread starts in; nothing is ever applied to the sender's checkout).
enum FleetDispatchGit {
    static func run(_ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 15) -> (status: Int32, output: String)? {
        var argv = ["/usr/bin/git"]
        if let directory { argv += ["-C", directory] }
        argv += arguments
        let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        guard let result = try? BoundedCommand.run(argv, environment: environment, timeout: timeout) else { return nil }
        return (result.status, String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the sending checkout is at: the commit to pin and the folder under the repo's root.
    struct Pin: Equatable, Sendable {
        var sha: String
        var subdir: String?
    }

    enum PinFailure: Error, Equatable {
        case notARepository
        /// Edits, untracked files or commits origin doesn't have: only a snapshot carries them (slice 4c).
        case needsBundle
    }

    /// The commit `cwd`'s checkout is at, when a fresh worktree of it on another Mac would be the same
    /// tree: no edits, no untracked files (ignored files don't hold it back, they travel with 4c) and
    /// a HEAD that some remote already has.
    static func pin(cwd: String) -> Result<Pin, PinFailure> {
        guard let top = run(["rev-parse", "--show-toplevel"], in: cwd), top.status == 0, !top.output.isEmpty,
              let head = run(["rev-parse", "HEAD"], in: cwd), head.status == 0, isCommit(head.output) else { return .failure(.notARepository) }
        // Edits and untracked files, with ignored ones left out.
        guard let status = run(["status", "--porcelain", "--untracked-files=normal"], in: cwd, timeout: 60), status.status == 0 else {
            return .failure(.notARepository)
        }
        if !status.output.isEmpty { return .failure(.needsBundle) }
        // A commit no remote-tracking ref holds is one origin may not have.
        guard let unpushed = run(["rev-list", "-n", "1", "HEAD", "--not", "--remotes"], in: cwd), unpushed.status == 0 else {
            return .failure(.notARepository)
        }
        if !unpushed.output.isEmpty { return .failure(.needsBundle) }
        let root = URL(fileURLWithPath: top.output).resolvingSymlinksInPath().path
        let here = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        var subdir: String?
        if here != root, here.hasPrefix(root + "/") { subdir = String(here.dropFirst(root.count + 1)) }
        return .success(Pin(sha: head.output, subdir: subdir))
    }

    /// A full commit id: 40 (SHA-1) or 64 (SHA-256) hex digits.
    static func isCommit(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// A folder under a repo's root, written relative: no `..`, no leading `/`, nothing under `.git`.
    static func isSafeSubdirectory(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("/"), !text.contains("\0"), text.utf8.count <= 1024 else { return false }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == ".." || $0 == "." || $0 == ".git" }
    }

    /// Fetches origin (a failed fetch leaves what the repo has) and says whether `sha` is a commit here.
    static func hasCommit(_ sha: String, in repo: String, fetching: Bool = true) -> Bool {
        guard isCommit(sha) else { return false }
        if fetching { _ = run(["fetch", "--quiet", "origin"], in: repo, timeout: 90) }
        return run(["cat-file", "-e", "\(sha)^{commit}"], in: repo)?.status == 0
    }

    /// `fleet/<slug of the title>`, with a short suffix of `dispatchID` only when that branch or its
    /// folder already exists, so retries and repeat tasks never collide.
    static func branchName(title: String, requested: String?, dispatchID: UUID, repo: String) -> String {
        var base = requested.flatMap { $0.hasPrefix("fleet/") && isValidBranch($0, repo: repo) ? $0 : nil }
            ?? "fleet/" + slug(title)
        if !isValidBranch(base, repo: repo) { base = "fleet/dispatch" }
        func taken(_ name: String) -> Bool {
            run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repo)?.status == 0
                || FileManager.default.fileExists(atPath: GitWorktree.destination(repo: repo, branch: name))
        }
        guard taken(base) else { return base }
        return base + "-" + String(dispatchID.uuidString.lowercased().prefix(6))
    }

    private static func isValidBranch(_ name: String, repo: String) -> Bool {
        !name.hasPrefix("-") && run(["check-ref-format", "--branch", name], in: repo)?.status == 0
    }

    /// A title as a short branch-safe word run.
    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar))) ? Character(scalar) : "-"
        }
        let words = String(lowered).split(separator: "-", omittingEmptySubsequences: true).prefix(6).joined(separator: "-")
        let cut = String(words.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "dispatch" : cut
    }

    /// What the finished thread left on its branch, as the host reads it: the head, the commits beyond
    /// the start, whether origin has the head, and the diffstat against the start. Facts only.
    static func branchFacts(worktree: String, branch: String, start: String?) -> FleetBranchFacts {
        var facts = FleetBranchFacts(branch: branch)
        if let head = run(["rev-parse", "HEAD"], in: worktree), head.status == 0, isCommit(head.output) { facts.head = head.output }
        guard let head = facts.head else { return facts }
        if let start, isCommit(start) {
            if let ahead = run(["rev-list", "--count", "\(start)..HEAD"], in: worktree), ahead.status == 0 { facts.ahead = Int(ahead.output) ?? 0 }
            if let stat = run(["diff", "--shortstat", "\(start)..HEAD"], in: worktree), stat.status == 0 {
                (facts.filesChanged, facts.insertions, facts.deletions) = parseShortstat(stat.output)
            }
        }
        // Pushed: origin has the branch, at this head (asked of origin now, so a push made since the last fetch counts).
        _ = run(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: worktree, timeout: 30)
        if let remote = run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: worktree), remote.status == 0 {
            facts.pushed = remote.output == head
        }
        return facts
    }

    /// "3 files changed, 10 insertions(+), 2 deletions(-)".
    static func parseShortstat(_ text: String) -> (files: Int, insertions: Int, deletions: Int) {
        func number(before word: String) -> Int {
            guard let range = text.range(of: word) else { return 0 }
            let digits = text[..<range.lowerBound].reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(String(digits.reversed())) ?? 0
        }
        return (number(before: "file"), number(before: "insertion"), number(before: "deletion"))
    }
}
