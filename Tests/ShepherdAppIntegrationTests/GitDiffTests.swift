import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Per-file revert", .integrationTimeLimit)
struct GitDiffRevertTests {
    @Test(arguments: ["*.txt", ":(glob)*.txt", "[ab].txt"])
    func revertingALiteralFilenameLeavesOtherFilesAndTheirStagingAlone(path: String) throws {
        let repo = try makeScratchRepo(files: [path: "original selected\n", "a.txt": "original other\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let selected = repo.appendingPathComponent(path)
        let other = repo.appendingPathComponent("a.txt")
        try "staged selected\n".write(to: selected, atomically: true, encoding: .utf8)
        try "staged other\n".write(to: other, atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try "working selected\n".write(to: selected, atomically: true, encoding: .utf8)
        try "working other\n".write(to: other, atomically: true, encoding: .utf8)
        let otherIndex = try git(["ls-files", "--stage", "--", "a.txt"], in: repo)
        let head = try git(["rev-parse", "HEAD"], in: repo)
        let file = try #require(GitDiff.load(cwd: repo.path, reference: nil).first { $0.displayPath == path })

        try GitDiff.revert(file, cwd: repo.path)

        #expect(try String(contentsOf: selected, encoding: .utf8) == "original selected\n")
        #expect(try git(["show", ":" + path], in: repo) == "original selected\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "working other\n")
        #expect(try git(["ls-files", "--stage", "--", "a.txt"], in: repo) == otherIndex)
        #expect(try git(["rev-parse", "HEAD"], in: repo) == head)
    }
}
