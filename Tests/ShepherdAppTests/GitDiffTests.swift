import Foundation
import Testing
@testable import ShepherdApp

@Suite("Git diff parsing")
struct GitDiffTests {
    @Test func parsesASimpleModificationAndLineNumbers() throws {
        let files = GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,4 @@ heading
         first
        -old
        +new
        +extra
         last
        """)

        let file = try #require(files.first)
        #expect(file.oldPath == "file.txt")
        #expect(file.newPath == "file.txt")
        #expect(file.displayPath == "file.txt")
        #expect(!file.isNew)
        #expect(!file.isDeleted)
        #expect(!file.isRenamed)
        #expect(!file.isBinary)
        #expect(file.addedCount == 2)
        #expect(file.removedCount == 1)
        let lines = try #require(file.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(lines.map(\.text) == ["first", "old", "new", "extra", "last"])
        #expect(lines.map(\.oldLine) == [1, 2, nil, nil, 3])
        #expect(lines.map(\.newLine) == [1, nil, 2, 3, 4])
    }

    @Test func parsesANewFile() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..abcdef0
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        """).first)

        #expect(file.oldPath == nil)
        #expect(file.newPath == "new.txt")
        #expect(file.displayPath == "new.txt")
        #expect(file.isNew)
        #expect(!file.isDeleted)
        #expect(file.addedCount == 2)
        #expect(file.removedCount == 0)
        #expect(file.hunks.first?.lines.map(\.oldLine) == [nil, nil])
        #expect(file.hunks.first?.lines.map(\.newLine) == [1, 2])
    }

    @Test func parsesADeletedFile() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index abcdef0..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """).first)

        #expect(file.oldPath == "old.txt")
        #expect(file.newPath == nil)
        #expect(file.displayPath == "old.txt")
        #expect(!file.isNew)
        #expect(file.isDeleted)
        #expect(file.addedCount == 0)
        #expect(file.removedCount == 2)
        #expect(file.hunks.first?.lines.map(\.oldLine) == [1, 2])
        #expect(file.hunks.first?.lines.map(\.newLine) == [nil, nil])
    }

    @Test func parsesARenameWithoutAContentHunk() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/old-name.txt b/new-name.txt
        similarity index 100%
        rename from old-name.txt
        rename to new-name.txt
        """).first)

        #expect(file.oldPath == "old-name.txt")
        #expect(file.newPath == "new-name.txt")
        #expect(file.displayPath == "new-name.txt")
        #expect(file.isRenamed)
        #expect(file.hunks.isEmpty)
    }

    @Test func parsesBinaryFiles() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/image.bin b/image.bin
        index 1111111..2222222 100644
        Binary files a/image.bin and b/image.bin differ
        """).first)

        #expect(file.oldPath == "image.bin")
        #expect(file.newPath == "image.bin")
        #expect(file.isBinary)
        #expect(file.hunks.isEmpty)

        let newFile = try #require(GitDiff.parse("""
        diff --git a/new.bin b/new.bin
        new file mode 100644
        GIT binary patch
        literal 0
        """).first)
        #expect(newFile.oldPath == nil)
        #expect(newFile.newPath == "new.bin")
        #expect(newFile.isNew)
        #expect(newFile.isBinary)
    }

    @Test func parsesMultipleHunksAndKeepsLineIDsStableWithinTheFile() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -2,2 +2,2 @@ first
         one
        -two
        +two changed
        @@ -10,1 +10,2 @@ second
         ten
        +eleven
        """).first)

        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].lines.map(\.id) == [0, 1, 2])
        #expect(file.hunks[1].lines.map(\.id) == [3, 4])
        #expect(file.hunks[0].lines.map(\.oldLine) == [2, 3, nil])
        #expect(file.hunks[0].lines.map(\.newLine) == [2, nil, 3])
        #expect(file.hunks[1].lines.map(\.oldLine) == [10, nil])
        #expect(file.hunks[1].lines.map(\.newLine) == [10, 11])
    }

    @Test func loadsTrackedAndUntrackedChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-git-diff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try runGit(["init", "-q"], in: directory)
        try runGit(["config", "user.name", "Shepherd Tests"], in: directory)
        try runGit(["config", "user.email", "tests@example.com"], in: directory)
        try "before\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: directory)
        try runGit(["commit", "-q", "-m", "initial"], in: directory)
        try "after\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let files = try GitDiff.load(cwd: directory.path, reference: nil)
        #expect(files.map(\.displayPath) == ["tracked.txt", "new.txt"])
        #expect(files.first?.addedCount == 1)
        #expect(files.first?.removedCount == 1)
        #expect(files.last?.isNew == true)
        #expect(files.last?.addedCount == 1)
    }

    @Test func loadsUntrackedFilesInARepoWithNoCommits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-git-diff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try runGit(["init", "-q"], in: directory)
        try "hello\n".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        // Unborn HEAD: the tracked diff is skipped, untracked files still load.
        let files = try GitDiff.load(cwd: directory.path, reference: nil)
        #expect(files.map(\.displayPath) == ["new.txt"])
        #expect(files.first?.isNew == true)
    }

    @Test func skipsNoNewlineMarkers() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """).first)

        #expect(file.hunks.count == 1)
        #expect(file.hunks.first?.lines.count == 2)
        #expect(file.hunks.first?.lines.map(\.text) == ["old", "new"])
        #expect(file.removedCount == 1)
        #expect(file.addedCount == 1)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["HOME"] = directory.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitDiffTests", code: Int(process.terminationStatus))
        }
    }
}
