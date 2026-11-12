import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit

/// What a clone for a dispatch reads out of git's progress, where it goes, and what is never sent about the origin it comes from.
@Suite("Fleet repo clone")
struct FleetRepoCloneTests {
    @Test(arguments: [
        ("Receiving objects:  37% (1234/3333), 2.5 MiB | 5.0 MiB/s", "receiving objects", 0.37),
        ("remote: Counting objects: 100% (5/5), done.", "counting objects", 1.0),
        ("Resolving deltas:   0% (0/12)", "resolving deltas", 0.0),
        ("Updating files:  54% (540/1000)", "updating files", 0.54),
        ("remote: Compressing objects:  12% (3/25)", "compressing objects", 0.12),
    ])
    func gitsProgressLinesBecomeAPhaseAndHowFarThroughIt(line: String, phase: String, fraction: Double) {
        #expect(FleetRepoClone.parse(line) == FleetRepoClone.Update(phase: phase, fraction: fraction))
    }

    @Test func aLineThatIsNotProgressIsNotAnUpdate() {
        #expect(FleetRepoClone.parse("Cloning into '/tmp/web'...") == nil)
        #expect(FleetRepoClone.parse("fatal: repository 'https://example.test/acme/web.git/' not found") == nil)
        #expect(FleetRepoClone.parse("remote: Total 12 (delta 3), reused 0 (delta 0)") == nil)
        #expect(FleetRepoClone.parse("Receiving objects: done") == FleetRepoClone.Update(phase: "receiving objects", fraction: nil))
    }

    @Test func aFolderIsNamedFromTheRepoAndNeverFromSomethingThatEscapes() {
        #expect(FleetRepoClone.folderName(repoKey: "github.com/acme/acme-web") == "acme-web")
        #expect(FleetRepoClone.folderName(repoKey: "git.example.test/team/we ird/../name") == "name")
        #expect(FleetRepoClone.folderName(repoKey: "github.com/acme/..") == "repo")
        #expect(FleetRepoClone.folderName(repoKey: "") == "repo")
    }

    @Test func aCloneMakesItsOwnFolderAndNeverUsesOneThatExists() throws {
        let base = try makeScratchDirectory("claim")
        let developer = base.appendingPathComponent("Developer", isDirectory: true)
        let repos = base.appendingPathComponent("support/repos", isDirectory: true)
        let id = UUID()
        // No developer folder: under the fleet's own.
        let first = try #require(FleetRepoClone.claim(repoKey: "github.com/acme/web", dispatchID: id, developer: developer, repos: repos))
        #expect(first.path == repos.appendingPathComponent("github.com-acme-web").path)
        // The developer folder is there: `<developer>/<repo>`.
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: false)
        let second = try #require(FleetRepoClone.claim(repoKey: "github.com/acme/api", dispatchID: id, developer: developer, repos: repos))
        #expect(second.path == developer.appendingPathComponent("api").path)
        // A folder already at that path (with something in it) is left exactly as it was: the next place is used.
        let mine = developer.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: mine.appendingPathComponent("notes.txt"))
        let third = try #require(FleetRepoClone.claim(repoKey: "github.com/acme/web", dispatchID: id, developer: developer, repos: repos))
        #expect(third.path == repos.appendingPathComponent("github.com-acme-web-\(id.uuidString.lowercased().prefix(6))").path, "the fleet's own folder was taken too")
        #expect(try String(contentsOf: mine.appendingPathComponent("notes.txt"), encoding: .utf8) == "mine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: mine.path) == ["notes.txt"])
    }

    @Test(arguments: [
        ("https://github.com/acme/web.git", "https://github.com/acme/web.git"),
        ("https://x-access-token:ghp_made_up@github.com/acme/web.git", "https://github.com/acme/web.git"),
        ("https://octocat@github.com/acme/web.git", "https://github.com/acme/web.git"),
        ("ssh://git:secret@git.example.test:2222/acme/web.git", "ssh://git@git.example.test:2222/acme/web.git"),
        ("git@github.com:acme/web.git", "git@github.com:acme/web.git"),
        ("/Users/someone/code/web", "/Users/someone/code/web"),
    ])
    func anOriginIsSentWithoutItsPassword(url: String, sent: String) {
        #expect(FleetRepoSource.sanitized(origin: url) == sent)
    }

    @Test func anOriginThatCouldBeReadAsAnOptionOrIsNotOneIsNotSent() {
        #expect(FleetRepoSource.sanitized(origin: "--upload-pack=touch /tmp/x") == nil)
        #expect(FleetRepoSource.sanitized(origin: "  ") == nil)
        #expect(FleetRepoSource.sanitized(origin: "https://example.test/a\nb") == nil)
    }
}
