import Foundation
import ShepherdProtocol

public enum GitDiff {
    /// The parser lives with `DiffFile` (ShepherdProtocol), which every review client shares.
    public static func parse(_ unified: String) -> [DiffFile] {
        DiffFile.parse(unified)
    }

    /// Resolve the ref spec for "the changes sitting in this branch's PR":
    /// merge-base diff against the PR base branch (gh), falling back to the
    /// remote default branch when gh is missing or there is no PR.
    public static func pullRequestReference(cwd: String) -> String {
        // gh lives on the user's PATH, not the GUI app's — resolve through a
        // login shell like commit from review does.
        if let base = try? runLoginShell("gh pr view --json baseRefName -q .baseRefName", cwd: cwd),
           base.status == 0 {
            let name = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return "origin/\(name)...HEAD" }
        }
        if let head = try? runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], cwd: cwd),
           head.status == 0 {
            let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return "\(name)...HEAD" }
        }
        return "origin/HEAD...HEAD"
    }

    /// Discard the working-tree changes to one file (the review pane's confirmed Revert). A
    /// tracked file returns to HEAD; a new untracked file moves to the Trash rather than being
    /// deleted; a rename restores the old path and trashes the new one. Blocking.
    /// The working tree's top level (diff paths are relative to it); `cwd` if git can't say.
    public static func repositoryRoot(cwd: String) -> String {
        guard let result = try? runGit(["rev-parse", "--show-toplevel"], cwd: cwd), result.status == 0 else { return cwd }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? cwd : path
    }

    public static func revert(_ file: DiffFile, cwd: String) throws {
        let cwd = repositoryRoot(cwd: cwd)
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        func trash(_ path: String) throws {
            try FileManager.default.trashItem(at: root.appendingPathComponent(path), resultingItemURL: nil)
        }
        let tracked = { (path: String) -> Bool in
            (try? runGit(["ls-files", "--error-unmatch", "--", path], cwd: cwd))?.status == 0
        }
        if file.isNew, let path = file.newPath, !tracked(path) {
            try trash(path)
            return
        }
        var paths: [String] = []
        if file.isRenamed, let old = file.oldPath { paths.append(old) }
        if let path = file.isNew ? nil : (file.isRenamed ? nil : (file.newPath ?? file.oldPath)) { paths.append(path) }
        if file.isNew, let path = file.newPath {
            // Staged but never committed: unstage, then trash the file.
            _ = try runGit(["rm", "--cached", "-q", "--", path], cwd: cwd)
            try trash(path)
            return
        }
        if !paths.isEmpty {
            let result = try runGit(["checkout", "HEAD", "--"] + paths, cwd: cwd)
            guard result.status == 0 else {
                throw GitDiffError.commandFailed(command: commandDescription(["checkout", "HEAD", "--"] + paths), status: result.status, stderr: result.stderr)
            }
        }
        if file.isRenamed, let path = file.newPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            _ = try runGit(["rm", "--cached", "-q", "--ignore-unmatch", "--", path], cwd: cwd)
            try trash(path)
        }
    }

    public static func load(cwd: String, reference: String?) throws -> [DiffFile] {
        let reference = reference.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // A fresh repo with no commits has an unborn HEAD; `git diff HEAD`
        // exits 128 there. In local mode everything is untracked, so skip
        // the tracked diff instead of failing.
        let headExists = (try? runGit(["rev-parse", "--verify", "-q", "HEAD"], cwd: cwd))?.status == 0
        var files: [DiffFile] = []
        if headExists || reference != nil {
            let diffArguments = ["-c", "core.quotepath=off", "diff", "--no-color", reference ?? "HEAD"]
            let tracked = try runGit(diffArguments, cwd: cwd)
            guard tracked.status == 0 else {
                throw GitDiffError.commandFailed(
                    command: commandDescription(diffArguments), status: tracked.status, stderr: tracked.stderr
                )
            }
            files = parse(tracked.stdout)
        }
        guard reference == nil else { return files }

        // Root-relative like the tracked diff's paths, so every DiffFile path means the same
        // thing (revert and "open" resolve them against the repository root).
        let listArguments = ["-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard", "--full-name"]
        let untracked = try runGit(listArguments, cwd: cwd)
        guard untracked.status == 0 else {
            throw GitDiffError.commandFailed(
                command: commandDescription(listArguments), status: untracked.status, stderr: untracked.stderr
            )
        }
        let root = repositoryRoot(cwd: cwd)

        for path in untracked.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let arguments = ["-c", "core.quotepath=off", "diff", "--no-color", "--no-index", "--", "/dev/null", path]
            let result = try runGit(arguments, cwd: root)
            guard result.status == 0 || result.status == 1 else {
                throw GitDiffError.commandFailed(
                    command: commandDescription(arguments), status: result.status, stderr: result.stderr
                )
            }
            files.append(contentsOf: parse(result.stdout))
        }
        return files
    }

    /// What git says changed in one file, as the thread's file viewer shows it: the whole file, in the repository that holds it.
    public struct FileChange: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            /// The working tree against HEAD.
            case uncommitted
            /// A file git does not track yet, all of it added.
            case untracked
            /// The last commit that touched the file, against its first parent.
            case commit(shortID: String, subject: String)
        }

        public let file: DiffFile
        public let source: Source
    }

    /// `path`'s change in the repository that holds it, read-only: its uncommitted edits, or the whole file when git does not
    /// track it, else the last commit that touched it. nil when no repository holds it or git has nothing for it. Every unchanged
    /// line comes with the hunks, so folds open without asking git again. Blocking.
    public static func fileChange(path: String) -> FileChange? {
        let directory = (path as NSString).deletingLastPathComponent
        guard let realDirectory = ThreadFileSystem.canonicalRealpath(directory),
              let top = try? runGit(["rev-parse", "--show-toplevel"], cwd: realDirectory), top.status == 0 else { return nil }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let realRoot = ThreadFileSystem.canonicalRealpath(root) ?? root
        let realPath = realDirectory + "/" + (path as NSString).lastPathComponent
        guard !root.isEmpty, realPath.hasPrefix(realRoot + "/") else { return nil }
        let relative = String(realPath.dropFirst(realRoot.count + 1))
        // Context past any file the viewer reads (its 2 MB cap), small enough for git's own arithmetic.
        let whole = "--unified=1000000"
        func diff(_ arguments: [String], allowed: Set<Int32> = [0]) -> DiffFile? {
            guard let result = try? runGit(["-c", "core.quotepath=off"] + arguments, cwd: realRoot), allowed.contains(result.status) else { return nil }
            return parse(result.stdout).first
        }

        let tracked = (try? runGit(["ls-files", "--error-unmatch", "--", relative], cwd: realRoot))?.status == 0
        guard tracked else {
            guard FileManager.default.fileExists(atPath: realPath) else { return nil }
            return diff(["diff", "--no-color", "--no-ext-diff", whole, "--no-index", "--", "/dev/null", relative], allowed: [0, 1])
                .map { FileChange(file: $0, source: .untracked) }
        }
        if (try? runGit(["rev-parse", "--verify", "-q", "HEAD"], cwd: realRoot))?.status == 0,
           let file = diff(["diff", "--no-color", "--no-ext-diff", whole, "HEAD", "--", relative]) {
            return FileChange(file: file, source: .uncommitted)
        }
        guard let log = try? runGit(["log", "-1", "--format=%h%x00%s", "--", relative], cwd: realRoot), log.status == 0 else { return nil }
        let parts = log.stdout.trimmingCharacters(in: .newlines).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let shortID = parts.first, !shortID.isEmpty,
              let file = diff(["show", "--no-color", "--no-ext-diff", "--format=", "--diff-merges=first-parent", whole, shortID, "--", relative])
        else { return nil }
        return FileChange(file: file, source: .commit(shortID: shortID, subject: parts.count > 1 ? parts[1] : ""))
    }

    private enum GitDiffError: Error, CustomStringConvertible {
        case couldNotStart(String)
        case commandFailed(command: String, status: Int32, stderr: String)

        var description: String {
            switch self {
            case .couldNotStart(let message):
                return message
            case .commandFailed(let command, let status, let stderr):
                let detail = stderr.isEmpty ? "no stderr" : stderr
                return "git command failed (exit \(status)): \(command): \(detail)"
            }
        }
    }

    private struct GitResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runLoginShell(_ command: String, cwd: String) throws -> GitResult {
        try run(["/bin/zsh", "-l", "-c", "cd -- \(shellQuoted(cwd)) || exit\n" + command], cwd: cwd)
    }

    private static func runGit(_ arguments: [String], cwd: String) throws -> GitResult {
        // Review paths are filenames, never git pathspec patterns (even after `--`).
        try run(["/usr/bin/git", "--literal-pathspecs"] + arguments, cwd: cwd)
    }

    private static func run(_ argv: [String], cwd: String) throws -> GitResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GH_PROMPT_DISABLED"] = "1"
        // Reads never take the index lock to refresh it (`git diff` would otherwise write the user's index).
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        do {
            let result = try BoundedCommand.run(argv, directory: URL(fileURLWithPath: cwd), environment: environment, timeout: 600)
            return GitResult(status: result.status, stdout: String(decoding: result.output, as: UTF8.self),
                             stderr: String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { throw GitDiffError.couldNotStart("Review command stopped in \(cwd): \(error)") }
    }

    private static func commandDescription(_ arguments: [String]) -> String {
        (["git"] + arguments).joined(separator: " ")
    }
}
