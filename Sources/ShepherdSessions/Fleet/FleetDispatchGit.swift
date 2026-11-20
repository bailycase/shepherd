import Foundation
import os
import ShepherdCore
import ShepherdProtocol

/// The git a dispatch needs, blocking: call it off the server queue. Every command is bounded, never
/// prompts, and reads or writes only what the plan allows (`git fetch origin` and the worktree the
/// thread starts in; nothing is ever applied to the sender's checkout).
enum FleetDispatchGit {
    static func run(_ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 15, environment extra: [String: String] = [:]) -> (status: Int32, output: String)? {
        var argv = ["/usr/bin/git"]
        if let directory { argv += ["-C", directory] }
        argv += arguments
        let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }.merging(extra) { $1 }
        guard let result = try? BoundedCommand.run(argv, environment: environment, timeout: timeout) else { return nil }
        return (result.status, String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the sending checkout is at: the commit to pin, the folder under the repo's root, the checkout's top, and whether HEAD
    /// has commits no remote ref holds (they travel as a bundle, slice 4c).
    struct Pin: Equatable, Sendable {
        var sha: String
        var subdir: String?
        var root: String
        var unpushed: Bool
        /// What was pinned: "HEAD", or the base or branch a thread the person started begins at (a bundle of its unpushed commits names it).
        var rev: String = "HEAD"
    }

    enum PinFailure: Error, Equatable {
        case notARepository
        /// The base or branch asked for isn't in this checkout.
        case unknownRevision
    }

    /// The commit `cwd`'s checkout is at. Edits, untracked and ignored files and unpushed commits don't hold it back: they go in the
    /// snapshot (`FleetSnapshotSender`). The checkout's top and HEAD come from one git call, and the unpushed check runs beside it;
    /// `prefetchingTree` starts listing the commit's tree the moment it is known, so the snapshot finds it when it is built.
    static func pin(cwd: String, rev: String = "HEAD", prefetchingTree: Bool = false) -> Result<Pin, PinFailure> {
        let unpushedGroup = DispatchGroup()
        let unpushedResult = OSAllocatedUnfairLock<(status: Int32, output: String)?>(initialState: nil)
        unpushedGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = run(["rev-list", "-n", "1", rev, "--not", "--remotes"], in: cwd)
            unpushedResult.withLock { $0 = found }
            unpushedGroup.leave()
        }
        // `rev-parse --show-toplevel HEAD`: the top on the lines before the last, the commit on the last.
        guard let both = run(["rev-parse", "--show-toplevel", "\(rev)^{commit}"], in: cwd), both.status == 0, let newline = both.output.lastIndex(of: "\n") else {
            unpushedGroup.wait()
            // The folder is a repository, and the revision isn't in it: two different answers.
            if rev != "HEAD", run(["rev-parse", "--show-toplevel"], in: cwd)?.status == 0 { return .failure(.unknownRevision) }
            return .failure(.notARepository)
        }
        let top = String(both.output[..<newline]), sha = String(both.output[both.output.index(after: newline)...])
        guard !top.isEmpty, isCommit(sha) else { unpushedGroup.wait(); return .failure(.notARepository) }
        let root = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        if prefetchingTree { FleetTrackedTrees.shared.prefetch(root: root, commit: sha) }
        unpushedGroup.wait()
        // A commit no remote-tracking ref holds is one origin may not have.
        guard let unpushed = unpushedResult.withLock({ $0 }), unpushed.status == 0 else { return .failure(.notARepository) }
        let here = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        var subdir: String?
        if here != root, here.hasPrefix(root + "/") { subdir = String(here.dropFirst(root.count + 1)) }
        return .success(Pin(sha: sha, subdir: subdir, root: root, unpushed: !unpushed.output.isEmpty, rev: rev))
    }

    /// The origin of the checkout at `cwd`, as another Mac may clone it: its fetch URL, with any password removed
    /// (`FleetRepoSource.sanitized`). Nil when there is no origin.
    static func origin(cwd: String) -> String? {
        guard let result = run(["remote", "get-url", "origin"], in: cwd), result.status == 0 else { return nil }
        return FleetRepoSource.sanitized(origin: result.output)
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

    /// Says whether `sha` is a commit here, fetching origin first (a failed fetch leaves what the repo has) only when it isn't.
    static func hasCommit(_ sha: String, in repo: String, fetching: Bool = true) -> Bool {
        guard isCommit(sha) else { return false }
        func has() -> Bool { run(["cat-file", "-e", "\(sha)^{commit}"], in: repo)?.status == 0 }
        if has() { return true }
        if fetching { _ = run(["fetch", "--quiet", "origin"], in: repo, timeout: 90) }
        return has()
    }

    /// `fleet/<slug of the title>`, with a short suffix of `dispatchID` only when that branch or its
    /// folder already exists or another dispatch in flight has claimed it, so retries and repeat tasks never collide.
    /// `exact` takes a requested name as it is (a thread the person started on a branch, or with a name for its new one); otherwise only a
    /// name under `fleet/` is taken.
    static func branchName(title: String, requested: String?, dispatchID: UUID, repo: String, claimed: Set<String> = [], exact: Bool = false) -> String {
        // A name made from a title is always a valid ref (`slug` is lowercase letters, digits and single hyphens), so only a requested one is asked of git.
        let base = requested.flatMap { (exact || $0.hasPrefix("fleet/")) && isValidBranch($0, repo: repo) ? $0 : nil } ?? "fleet/" + slug(title)
        func taken(_ name: String) -> Bool {
            claimed.contains(name) || run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repo)?.status == 0
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
        var slug = ""
        for word in String(lowered).split(separator: "-").prefix(6) {
            if slug.isEmpty {
                // A title whose first word alone exceeds the budget still gets a meaningful name.
                slug = String(word.prefix(40))
            } else {
                guard slug.count + 1 + word.count <= 40 else { break }
                slug += "-" + word
            }
        }
        return slug.isEmpty ? "dispatch" : slug
    }

    /// A configured origin base wins, then the sending checkout's origin upstream. A Fleet branch's
    /// push upstream is its own result, not an integration base.
    static func comparisonBranch(cwd: String, configured: [String?]) -> String? {
        for value in configured.compactMap({ $0 }) where value.hasPrefix("origin/") {
            let name = String(value.dropFirst("origin/".count))
            if !name.hasPrefix("fleet/"), run(["check-ref-format", "refs/heads/\(name)"], in: cwd)?.status == 0 { return name }
        }
        let prefix = "refs/remotes/origin/"
        if let upstream = run(["rev-parse", "--symbolic-full-name", "@{upstream}"], in: cwd),
           upstream.status == 0, upstream.output.hasPrefix(prefix) {
            let name = String(upstream.output.dropFirst(prefix.count))
            if !name.hasPrefix("fleet/") { return name }
        }
        if let branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: cwd), branch.status == 0,
           !branch.output.hasPrefix("fleet/"), run(["show-ref", "--verify", "--quiet", prefix + branch.output], in: cwd)?.status == 0 {
            return branch.output
        }
        return GitWorktree.defaultBranch(repo: cwd, network: false)
    }

    /// What the finished thread left on its branch, as the receiving host reads it. Compare with
    /// its merge base against the target, falling back to the pinned start when unavailable.
    static func branchFacts(worktree: String, branch: String, start: String?, comparison: String? = nil) -> FleetBranchFacts? {
        let ref = "refs/heads/\(branch)"
        // The thread may have switched branches or detached HEAD. Pin the dispatch ref once so all
        // facts describe the same commit even if the branch moves while git is running.
        guard let start, isCommit(start),
              let tip = run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], in: worktree),
              tip.status == 0, isCommit(tip.output) else { return nil }
        let head = tip.output
        var diffBase = start
        var comparedTo: String?
        if let comparison, comparison != branch,
           run(["check-ref-format", "refs/heads/\(comparison)"], in: worktree)?.status == 0,
           let target = run(["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/remotes/origin/\(comparison)^{commit}"], in: worktree),
           target.status == 0, isCommit(target.output),
           let merge = run(["merge-base", target.output, head], in: worktree), merge.status == 0, isCommit(merge.output) {
            diffBase = merge.output
            comparedTo = "origin/\(comparison)"
        }
        let range = "\(diffBase)..\(head)"
        guard let count = run(["rev-list", "--count", range], in: worktree), count.status == 0,
              let ahead = Int(count.output),
              let stat = run(["diff", "--shortstat", range, "--"], in: worktree, environment: ["LC_ALL": "C"]), stat.status == 0
        else { return nil }
        let (files, insertions, deletions) = parseShortstat(stat.output)
        var facts = FleetBranchFacts(branch: branch, head: head, ahead: ahead, filesChanged: files, insertions: insertions, deletions: deletions)
        facts.comparedTo = comparedTo
        // Ask origin without writing refs or falling back to a possibly stale remote-tracking ref.
        let remote = run(["ls-remote", "--exit-code", "--refs", "origin", ref], in: worktree, timeout: 30)
        switch remote?.status {
        case 0: facts.pushed = remote?.output == "\(head)\t\(ref)"
        case 2: break // No matching ref.
        default: facts.originCheckFailed = true
        }
        return facts
    }

    static let buildOutputNames = [".build", "DerivedData"]

    /// Explicit Fleet close only. Require the assigned, Shepherd-managed worktree, an ignored,
    /// untracked directory, and a build-system marker. Never follow directory symlinks.
    static func cleanBuildOutput(worktree: String, branch: String, names: [String]) -> (bytes: UInt64, removed: [String]) {
        let folder = URL(fileURLWithPath: worktree).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: ShepherdPaths.supportDirectory().appendingPathComponent("worktrees").path).resolvingSymlinksInPath()
        guard folder.path.hasPrefix(root.path + "/"),
              let identity = try? GitWorktree.identity(at: folder.path), identity.branch == branch else { return (0, []) }
        let fm = FileManager.default
        var bytes: UInt64 = 0, removed: [String] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]
        for name in buildOutputNames where names.contains(name) {
            // Ignore rules and an empty index are both necessary: a tracked file can also match an ignore rule.
            guard run(["check-ignore", "-q", "--", name + "/"], in: folder.path)?.status == 0,
                  let tracked = run(["ls-files", "--", name], in: folder.path), tracked.status == 0, tracked.output.isEmpty else { continue }
            let output = folder.appendingPathComponent(name)
            guard let values = try? output.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let marker = output.appendingPathComponent(name == ".build" ? "workspace-state.json" : "info.plist")
            guard let markerValues = try? marker.resourceValues(forKeys: keys), markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
                  let files = fm.enumerator(at: output, includingPropertiesForKeys: Array(keys), options: []) else { continue }
            var size: UInt64 = 0
            for case let file as URL in files {
                guard let values = try? file.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { files.skipDescendants() }
                else if values.isRegularFile == true { size += UInt64(max(0, values.totalFileAllocatedSize ?? 0)) }
            }
            do { try fm.removeItem(at: output); bytes += size; removed.append(name) }
            catch { continue }
        }
        return (bytes, removed)
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
