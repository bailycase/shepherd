import Foundation
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdApp

/// What commit from review reads from a checkout: the inspection's lines, the push remote and
/// default branch they imply, why a checkout is refused, and what the model is shown.
@Suite("Commit from review: the checkout")
struct ReviewCommitGitTests {
    private let clean = """
        root=/r
        branch=feat/rows
        head=abc123
        upstream=origin/feat/rows
        upremote=origin
        upmerge=refs/heads/feat/rows
        remote=origin
        remotehead=origin/main
        remotehead=origin/main
        remote=fork
        remotehead=fork/master
        """

    @Test func aCleanCheckoutReadsItsBranchUpstreamAndDefaultBranch() throws {
        let checkout = try #require(ReviewCommitGit.parseCheckout(clean))
        #expect(checkout.root == "/r" && checkout.branch == "feat/rows" && checkout.head == "abc123")
        #expect(checkout.upstream == "origin/feat/rows" && checkout.pushRemote == "origin")
        #expect(checkout.remoteUpstream?.remote == "origin" && checkout.remoteUpstream?.merge == "refs/heads/feat/rows")
        #expect(checkout.remoteHeads == ["origin/main", "fork/master"] && checkout.defaultBranch == "main")
        #expect(checkout.blocked == nil)
    }

    @Test(arguments: [
        ("branch=\n", "HEAD is detached. Check out a branch to commit from review."),
        ("branch=main\nbusy=MERGE_HEAD\n", "A merge is in progress in this checkout. Finish or abort it first."),
        ("branch=main\nbusy=rebase-merge\n", "A rebase is in progress in this checkout. Finish or abort it first."),
        ("branch=main\nbusy=CHERRY_PICK_HEAD\n", "A cherry-pick is in progress in this checkout. Finish or abort it first."),
        ("branch=main\nbusy=REVERT_HEAD\n", "A revert is in progress in this checkout. Finish or abort it first."),
        ("branch=main\nunmerged=1\n", "The checkout has unmerged paths. Resolve them first."),
    ])
    func aCheckoutMidOperationOrDetachedIsRefused(_ lines: String, _ reason: String) throws {
        let checkout = try #require(ReviewCommitGit.parseCheckout("root=/r\n" + lines))
        #expect(checkout.blocked == reason)
    }

    @Test func aLocalUpstreamIsNeverPushedTo() throws {
        let checkout = try #require(ReviewCommitGit.parseCheckout("root=/r\nbranch=feat\nupremote=.\nupmerge=refs/heads/main\nremote=origin\n"))
        #expect(checkout.remoteUpstream == nil && checkout.pushRemote == "origin")
    }

    @Test func anUpstreamOfAnotherNameIsNeverPushedTo() throws {
        // `git switch -c feat origin/main` tracks origin/main: a push must not land on main.
        let checkout = try #require(ReviewCommitGit.parseCheckout(
            "root=/r\nbranch=feat\nupstream=origin/main\nupremote=origin\nupmerge=refs/heads/main\nremote=origin\n"))
        #expect(checkout.remoteUpstream == nil && checkout.pushUpstream == nil && checkout.pushRemote == "origin")
    }

    @Test(arguments: [
        ("remote=upstream\n", "upstream"),
        ("remote=origin\nremote=fork\n", "origin"),
        ("remote=a\nremote=b\n", nil),
        ("", nil),
    ] as [(String, String?)])
    func aPushWithoutAnUpstreamGoesToOriginOrTheOnlyRemote(_ remotes: String, _ expected: String?) throws {
        let checkout = try #require(ReviewCommitGit.parseCheckout("root=/r\nbranch=feat\n" + remotes))
        #expect(checkout.pushRemote == expected)
    }

    @Test func outputWithoutARootIsNotACheckout() {
        #expect(ReviewCommitGit.parseCheckout("branch=main\n") == nil)
    }

    @Test(arguments: [
        ("App/iOS/FleetView.swift", true), ("a b/c'd.swift", true), ("/etc/passwd", false),
        ("../outside", false), ("a/../../b", false), ("", false),
    ])
    func onlyPathsInsideTheRepositoryAreCommitted(_ path: String, _ safe: Bool) {
        #expect(ReviewCommitGit.isSafePath(path) == safe)
    }

    @Test func theModelSeesEachFileThenItsHunksWithinTheLimit() {
        let files = DiffFile.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        """)
        let context = ReviewCommitGit.promptContext(files)
        #expect(context == "M a.swift (+1 -1)\n\n--- a.swift\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n")
        #expect(ReviewCommitGit.promptContext(files, limit: 10).count == 10)
    }

    /// A tiny scratch file: the fingerprint is of a file's bytes.
    @Test func aFingerprintChangesWithTheFileAndNotesItsAbsence() throws {
        let dir = try makeScratchDirectory("fp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = ReviewCommitGit.fingerprint(root: dir.path, paths: ["a.txt"])
        try "one".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let one = ReviewCommitGit.fingerprint(root: dir.path, paths: ["a.txt"])
        try "two".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let two = ReviewCommitGit.fingerprint(root: dir.path, paths: ["a.txt"])
        #expect(Set([missing, one, two]).count == 3)
        #expect(ReviewCommitGit.fingerprint(root: dir.path, paths: ["a.txt"]) == two)
    }
}
