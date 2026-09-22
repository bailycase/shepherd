import Foundation
import Testing
@testable import ShepherdApp

@Suite("Git worktrees")
struct GitWorktreeTests {
    /// End to end against a real scratch repo: detection, creation beside the
    /// checkout on the requested branch, and the duplicate-directory guard.
    @Test func addsAWorktreeBesideTheRepo() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-worktree-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            try #require(p.terminationStatus == 0)
        }

        #expect(!GitWorktree.isRepo(repo))
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        #expect(GitWorktree.isRepo(repo))

        let path = try GitWorktree.add(repo: repo, branch: "agent/fix-thing")
        #expect(path == base.appendingPathComponent("proj-agent-fix-thing").path)
        #expect(path == GitWorktree.destination(repo: repo, branch: "agent/fix-thing"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        // The worktree is itself a repo (a .git file) on the new branch.
        #expect(GitWorktree.isRepo(path))

        // Same branch again: git refuses (branch exists); surfaced as thrown.
        #expect(throws: (any Error).self) {
            try GitWorktree.add(repo: repo, branch: "agent/fix-thing")
        }

        func gitInWorktree(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            try #require(p.terminationStatus == 0)
        }

        // Fresh worktree: clean and fully reconciled — nothing to warn about.
        #expect(GitWorktree.unreconciledWork(worktree: path, branch: "agent/fix-thing") == nil)

        // Dirty file → uncommitted-change warning; committing it moves the
        // warning to branch-only commits (nothing else reaches them).
        try "x".write(toFile: path + "/f.txt", atomically: true, encoding: .utf8)
        #expect(
            GitWorktree.unreconciledWork(worktree: path, branch: "agent/fix-thing")
                == "1 uncommitted change"
        )
        try gitInWorktree(["add", "f.txt"])
        try gitInWorktree(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "wip"])
        #expect(
            GitWorktree.unreconciledWork(worktree: path, branch: "agent/fix-thing")
                == "1 commit only on this branch"
        )

        // Remove tears down both the checkout and the branch — proven by the
        // same add succeeding again afterwards.
        try GitWorktree.remove(repo: repo, branch: "agent/fix-thing")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try GitWorktree.add(repo: repo, branch: "agent/fix-thing") == path)
    }

    @Test func importDirectoryUsesTheReposRegisteredWorktreeFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-browse-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo").path
        let worktrees = base.appendingPathComponent("linked", isDirectory: true)
        let linked = worktrees.appendingPathComponent("feature").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/feature", linked])

        #expect(GitWorktree.importDirectory(repo: repo) == worktrees.resolvingSymlinksInPath().path)
    }

    @Test func identifiesAnExistingLinkedWorktree() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-import-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo").path
        let imported = base.appendingPathComponent("migrated-any-name").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }

        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/imported", imported])

        let identity = try GitWorktree.identity(at: imported)
        #expect(identity.repo == URL(fileURLWithPath: repo).resolvingSymlinksInPath().path)
        #expect(identity.path == URL(fileURLWithPath: imported).resolvingSymlinksInPath().path)
        #expect(identity.branch == "worktree/imported")
        #expect(throws: (any Error).self) { try GitWorktree.identity(at: repo) }
    }

    /// The incident class this exists to prevent: the primary checkout sits
    /// on a feature branch, but a worktree created from an explicit
    /// `origin/<default>` base carries none of that work — and gets no
    /// upstream tracking (a bare `git push` must not aim at the default
    /// branch).
    @Test func branchesFromExplicitBaseWithoutTracking() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        /// Returns (status, stdout); asserts nothing — callers decide.
        func gitRaw(_ args: [String], in dir: String) throws -> (status: Int32, stdout: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func git(_ args: [String], in dir: String) throws -> String {
            let result = try gitRaw(args, in: dir)
            try #require(result.status == 0)
            return result.stdout
        }

        // Bare origin + clone with master pushed. The bare repo's HEAD is
        // pinned to master explicitly: Apple git and nix git disagree on
        // init.defaultBranch, and a dangling remote HEAD would (correctly)
        // make defaultBranch unresolvable.
        let origin = base.appendingPathComponent("origin.git").path
        _ = try git(["init", "-q", "--bare", "--initial-branch=master", origin], in: base.path)
        let repo = base.appendingPathComponent("clone").path
        _ = try git(["clone", "-q", origin, repo], in: base.path)
        _ = try git(["checkout", "-qb", "master"], in: repo)
        _ = try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"], in: repo)
        _ = try git(["push", "-qu", "origin", "master"], in: repo)

        // The checkout wanders onto a feature branch with unrelated commits.
        _ = try git(["checkout", "-qb", "feat/other"], in: repo)
        _ = try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "unrelated"], in: repo)

        #expect(GitWorktree.defaultBranch(repo: repo) == "master")
        #expect(GitWorktree.currentBranch(repo: repo) == "feat/other")

        let path = try GitWorktree.add(repo: repo, branch: "wt/clean", from: "origin/master")
        // Zero unrelated commits: the base is the remote default, not HEAD.
        #expect(try git(["rev-list", "--count", "origin/master..wt/clean"], in: repo) == "0")
        // --no-track: no upstream pointing at master (config --get exits 1
        // when the key is unset — exactly what we want).
        let track = try gitRaw(["config", "--get", "branch.wt/clean.merge"], in: repo)
        #expect(track.status != 0)
        #expect(track.stdout.isEmpty)
        #expect(GitWorktree.isRepo(path))

        // resolveBase(.fresh) resolves the same start point (fetch off: no
        // network dependency in tests).
        let resolution = GitWorktree.resolveBase(repo: repo, mode: .fresh, fetchFirst: false)
        #expect(resolution.startPoint == "origin/master")
        #expect(resolution.note == "cached — fetch disabled in settings")
        // .head resolves to the current branch with no explicit start point.
        let head = GitWorktree.resolveBase(repo: repo, mode: .head, fetchFirst: false)
        #expect(head.startPoint == nil)
        #expect(head.display == "feat/other")
    }

    /// The New Worktree sheet's generated branch: `worktree/word-word-NNNN`,
    /// and its destination preview matches what `add` would create.
    @Test func generatesDisposableBranchNames() throws {
        let branch = GitWorktree.generatedBranch()
        #expect(branch.wholeMatch(of: /worktree\/[a-z]+-[a-z]+-\d{4}/) != nil)
        #expect(
            GitWorktree.destination(repo: "/tmp/x/proj", branch: branch)
                == "/tmp/x/proj-" + branch.replacingOccurrences(of: "/", with: "-")
        )
    }
}
