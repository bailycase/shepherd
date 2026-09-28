import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Login shell checkout", .integrationTimeLimit)
struct LoginShellTests {
    @Test func startupDirectoryChangesCannotRedirectGitReadsOrWrites() async throws {
        let root = try makeScratchDirectory("login")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeScratchRepo(files: ["file.txt": "original\n"])
        let repo = root.appendingPathComponent("checkout with 'quotes'")
        try FileManager.default.moveItem(at: original, to: repo)
        try "changed\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        // The isolation's .zlogin moves scripts containing this marker to /, without changing
        // process-wide environment or startup files shared with any other test.
        let marker = "# /pi/bin/pi\n"
        let startup = await LoginShell.run(marker + "pwd -P", timeout: 10)
        try #require(startup.status == 0 && startup.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/")
        let expected = try git(["rev-parse", "--show-toplevel"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await LoginShell.run(marker + """
            git rev-parse --show-toplevel
            [ "$(pwd -P)" = \(shellQuoted(expected)) ] || exit 3
            git add -- file.txt
            """, cwd: repo.path, timeout: 10)

        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        #expect(try git(["show", ":file.txt"], in: repo) == "changed\n")
        #expect(try git(["show", "HEAD:file.txt"], in: repo) == "original\n")
    }
}
