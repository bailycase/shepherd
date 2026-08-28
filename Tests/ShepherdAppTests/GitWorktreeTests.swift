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
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        // The worktree is itself a repo (a .git file) on the new branch.
        #expect(GitWorktree.isRepo(path))

        // Same branch again: git refuses (branch exists); surfaced as thrown.
        #expect(throws: (any Error).self) {
            try GitWorktree.add(repo: repo, branch: "agent/fix-thing")
        }
    }
}
