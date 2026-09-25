import Foundation
import ShepherdProtocol

enum GitDiff {
    /// The parser lives with `DiffFile` (ShepherdProtocol), which every review client shares.
    static func parse(_ unified: String) -> [DiffFile] {
        DiffFile.parse(unified)
    }

    /// Resolve the ref spec for "the changes sitting in this branch's PR":
    /// merge-base diff against the PR base branch (gh), falling back to the
    /// remote default branch when gh is missing or there is no PR.
    static func pullRequestReference(cwd: String) -> String {
        // gh lives on the user's PATH, not the GUI app's — resolve through a
        // login shell like the worktree-finalize prerequisites do.
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
    static func repositoryRoot(cwd: String) -> String {
        guard let result = try? runGit(["rev-parse", "--show-toplevel"], cwd: cwd), result.status == 0 else { return cwd }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? cwd : path
    }

    static func revert(_ file: DiffFile, cwd: String) throws {
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

    static func load(cwd: String, reference: String?) throws -> [DiffFile] {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitDiffError.couldNotStart("could not start shell in \(cwd): \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        return GitResult(
            status: process.terminationStatus,
            stdout: String(decoding: output, as: UTF8.self),
            stderr: String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func runGit(_ arguments: [String], cwd: String) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitDiffError.couldNotStart("could not start git in \(cwd): \(error.localizedDescription)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        return GitResult(
            status: process.terminationStatus,
            stdout: String(decoding: output, as: UTF8.self),
            stderr: String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func commandDescription(_ arguments: [String]) -> String {
        (["git"] + arguments).joined(separator: " ")
    }
}
