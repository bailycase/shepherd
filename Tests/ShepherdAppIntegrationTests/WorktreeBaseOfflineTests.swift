import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

/// With "fetch before creating" off, resolving a worktree's base must not touch the network,
/// even when origin/HEAD was never recorded locally.
@Suite("Worktree base without the network")
struct WorktreeBaseOfflineTests {
    @Test func missingOriginHeadFallsBackToALocalOriginMain() throws {
        let remote = try makeScratchRepo()
        let clone = try makeScratchDirectory("clone")
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: clone)
        }
        try git(["clone", "-q", remote.path, clone.path], in: clone.deletingLastPathComponent())
        try git(["remote", "set-head", "origin", "--delete"], in: clone)

        #expect(GitWorktree.defaultBranch(repo: clone.path, network: false) == "main")
        let base = GitWorktree.resolveBase(repo: clone.path, mode: .fresh, fetchFirst: false)
        #expect(base.startPoint == "origin/main")
        #expect(base.note == "cached — fetch disabled in settings")
    }
}
