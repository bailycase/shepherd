import Foundation
import Testing
import ShepherdCore

/// One repo has one key whatever the remote's spelling; a fork, another host or another repo does not.
@Suite("Canonical repo key")
struct CanonicalRepoKeyTests {
    private func key(_ remote: String) -> String? { CanonicalRepoKey(remote: remote)?.value }

    @Test(arguments: [
        "git@github.com:acme/web.git",
        "git@github.com:acme/web",
        "ssh://git@github.com/acme/web.git",
        "ssh://git@github.com:22/acme/web",
        "ssh://git@ssh.github.com:443/acme/web.git",
        "https://github.com/acme/web.git",
        "https://github.com/acme/web/",
        "https://github.com/acme/web.git/",
        "https://user:token@github.com/acme/web.git",
        "https://GitHub.com/acme/web",
        "git://github.com/acme/web.git",
        "http://github.com/acme/web",
        "  https://github.com/acme/web.git\n",
    ])
    func oneRepoInAnySpelling(_ remote: String) {
        #expect(key(remote) == "github.com/acme/web")
    }

    @Test func caseFoldsOnlyOnTheKnownForges() {
        #expect(key("git@github.com:Acme/Web.git") == "github.com/acme/web")
        #expect(key("https://gitlab.com/Acme/Platform/Web.git") == "gitlab.com/acme/platform/web")
        #expect(key("git@bitbucket.org:Acme/Web.git") == "bitbucket.org/acme/web")
        // A host that may care about case keeps it, and the host itself is lowercase.
        #expect(key("git@Git.Example.com:Acme/Web.git") == "git.example.com/Acme/Web")
        #expect(key("ssh://git@code.example.org:2222/Team/Web.git") == "code.example.org/Team/Web")
    }

    @Test func aForkOrAnotherHostIsAnotherRepo() {
        #expect(key("git@github.com:alice/web.git") != key("git@github.com:acme/web.git"))
        #expect(key("git@github.com:acme/web.git") != key("git@gitlab.com:acme/web.git"))
        #expect(key("git@github.com:acme/web.git") != key("git@github.com:acme/web-api.git"))
    }

    @Test func aTrailingDotGitIsOnlyStrippedFromTheEnd() {
        #expect(key("https://github.com/acme/web.github.io.git") == "github.com/acme/web.github.io")
        #expect(key("https://github.com/acme/web.git.git") == "github.com/acme/web")
    }

    @Test(arguments: ["", "   ", "/Users/test/acme-web", "./web", "~/web", "file:///Users/test/web", "https://github.com", "https://github.com/acme",
                      "git@github.com:web", "web", "https://github.com/acme/../web"])
    func noKeyWithoutAnOwnerAndRepo(_ remote: String) {
        #expect(key(remote) == nil)
    }

    @Test func aSpaceDecodesWithoutAKeyAndWritesOneOnlyWhenSet() throws {
        let old = #"{"id":"s1","name":"web","path":"/Users/test/web"}"#
        let decoded = try JSONDecoder().decode(Space.self, from: Data(old.utf8))
        #expect(decoded.repoKey == nil)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("repoKey"))
        var keyed = decoded
        keyed.repoKey = "github.com/acme/web"
        let round = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(keyed))
        #expect(round.repoKey == "github.com/acme/web")
    }
}
