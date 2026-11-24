import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite(.integrationTimeLimit)
struct PeerCheckoutTests {
    @Test func reportsUnstagedStagedAndUntrackedChangesWithoutRefreshingTheIndex() throws {
        let repo = try makeScratchRepo(files: [".gitignore": "ignored\n", "app/main.txt": "hello\n", "README.md": "hello\n"])
        let subdir = repo.appendingPathComponent("app").path
        let tracked = repo.appendingPathComponent("README.md")  // Outside the listed cwd, inside its checkout.
        let index = repo.appendingPathComponent(".git/index")
        func check(_ expected: PeerCheckoutStatus) throws {
            let indexBefore = try Data(contentsOf: index)
            let modifiedBefore = try index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            #expect(PeerCheckouts.read([subdir, subdir]) == [subdir: .init(status: expected)])
            #expect(try Data(contentsOf: index) == indexBefore)
            #expect(try index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modifiedBefore)
        }
        try "ignored".write(to: repo.appendingPathComponent("ignored"), atomically: true, encoding: .utf8)
        // Make git want to refresh its stat cache without actually changing the file.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: tracked.path)
        try check(.clean)
        try "edited\n".write(to: tracked, atomically: true, encoding: .utf8)
        try check(.dirty)
        try git(["add", "README.md"], in: repo)
        try check(.dirty)
        try git(["commit", "-qm", "staged change"], in: repo)
        try check(.clean)
        try "new".write(to: repo.appendingPathComponent("private-fixture\nname"), atomically: true, encoding: .utf8)
        try check(.dirty)
    }

    @Test func countsAgainstTheLocalTrackingRefEvenWhenItIsStale() throws {
        let repo = try makeScratchRepo()
        try configureUpstream(in: repo)
        #expect(PeerCheckouts.read([repo.path])[repo.path] == .init(status: .clean), "configured upstream has no local ref yet")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        #expect(PeerCheckouts.read([repo.path])[repo.path] == .init(status: .clean, commitsAheadOfLocalUpstream: 0))
        // The tracking ref is still at the initial commit. No connection to origin is needed.
        try git(["commit", "--allow-empty", "-qm", "new local commit"], in: repo)
        try "not a header".write(to: repo.appendingPathComponent("# branch.ab +99 -0"), atomically: true, encoding: .utf8)
        #expect(PeerCheckouts.read([repo.path])[repo.path] == .init(status: .dirty, commitsAheadOfLocalUpstream: 1))
    }

    @Test func unbornHeadHasNoComparison() throws {
        let repo = try makeScratchDirectory("unborn")
        try git(["init", "-q", "-b", "main"], in: repo)
        try configureUpstream(in: repo)
        #expect(PeerCheckouts.read([repo.path])[repo.path] == .init(status: .clean))
    }

    private func configureUpstream(in repo: URL) throws {
        try git(["remote", "add", "origin", "https://example.invalid/acme.git"], in: repo)
        try git(["config", "branch.main.remote", "origin"], in: repo)
        try git(["config", "branch.main.merge", "refs/heads/main"], in: repo)
    }

    @Test func missingNonGitAndFailedChecksAreUnknown() throws {
        let repo = try makeScratchRepo()
        try configureUpstream(in: repo)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        let nonGit = try makeScratchDirectory("not-git")
        let missing = repo.appendingPathComponent("does-not-exist")
        try Data("a broken index".utf8).write(to: repo.appendingPathComponent(".git/index"))
        let paths = [nonGit.path, missing.path, repo.path, "", "relative"]
        #expect(PeerCheckouts.read(paths) == Dictionary(uniqueKeysWithValues: paths.map { ($0, .unknown) }))
    }

    @Test func aConfiguredCleanFilterCannotRunDuringAProbe() throws {
        let repo = try makeScratchRepo(files: [".gitattributes": "README.md filter=fixture\n", "README.md": "hello\n"])
        // A mere stat change is enough for status to want to compare filtered contents.
        let tracked = repo.appendingPathComponent("README.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: tracked.path)
        try git(["config", "filter.fixture.clean", "printf ran > marker; /bin/cat"], in: repo)
        #expect(PeerCheckouts.read([repo.path])[repo.path] == .unknown)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("marker").path))
    }
}
