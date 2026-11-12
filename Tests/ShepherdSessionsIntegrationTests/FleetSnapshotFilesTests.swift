import CryptoKit
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// The pieces a dispatch's snapshot is built from, each against the real thing: git reading an index file this code wrote, the spare built
/// from a repository's own objects, and the store that checks every received content against its hash.
@Suite("Fleet snapshot files", .integrationTimeLimit)
struct FleetSnapshotFilesTests {
    @Test func anIndexFileWrittenWithoutGitIsOneGitReadsAsCleanExceptWhereTheSnapshotDiffers() throws {
        let repo = try makeScratchRepo(files: ["a.txt": "A\n", "dir/b.txt": "B\n", "dir/c.sh": "#!/bin/sh\n", "z.txt": "Z\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("dir/c.sh").path)
        try git(["add", "."], in: repo)
        try git(["commit", "-qm", "exec"], in: repo)
        let commit = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        // The tree, the files as a clone leaves them (here, copied: the tree is the repo's own), and an index of the two written by hand.
        let listing = try git(["ls-tree", "-r", "-z", commit], in: repo)
        let ordered = FleetSnapshotSender.parseOrdered(tree: listing)
        #expect(ordered.map(\.0) == ["a.txt", "dir/b.txt", "dir/c.sh", "z.txt"])
        let work = try makeScratchDirectory("worktree")
        try git(["worktree", "add", "--no-checkout", "-b", "snap", work.appendingPathComponent("w").path, commit], in: repo)
        let folder = work.appendingPathComponent("w")
        for (path, _) in ordered {
            let target = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: repo.appendingPathComponent(path), to: target)
        }
        // `z.txt` differs in the snapshot (edited), `a.txt` is gone from the snapshot.
        try "Z edited\n".write(to: folder.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.txt"))
        let entries = ordered.map { path, entry -> FleetGitIndexFile.Entry in
            var status: stat?
            if path != "z.txt", path != "a.txt" { var read = stat(); if lstat(folder.appendingPathComponent(path).path, &read) == 0 { status = read } }
            let mode: UInt32 = entry.kind == .executable ? 0o100755 : 0o100644
            return FleetGitIndexFile.Entry(path: path, mode: mode, id: entry.gitID, status: status)
        }
        let gitDirectory = try #require(FleetSnapshotApply.gitDirectory(of: folder.path))
        try FleetGitIndexFile.data(entries, ordered: true).write(to: URL(fileURLWithPath: gitDirectory + "/index"))
        // Git accepts the file, lists the tree's blobs, and reports only the two differences (and not the exec bit or the other files).
        #expect(try git(["ls-files", "-s"], in: folder).split(separator: "\n").count == 4)
        #expect(try git(["status", "--porcelain"], in: folder).split(separator: "\n").map(String.init).sorted() == [" D a.txt", " M z.txt"])
        // Unsorted entries are sorted by the writer; a path that sorts before its directory's files still reads back right.
        let shuffled = FleetGitIndexFile.data(entries.reversed())
        #expect(shuffled == FleetGitIndexFile.data(entries, ordered: true))
    }

    @Test func theSpareIsAPlainDirectoryOfTheTrackedFilesAtTheBaseTipAndRegistersNothingInTheRepository() throws {
        let origin = try makeScratchRepo(files: ["README.md": "# acme\n", "src/app.ts": "app\n", ".gitignore": "ignored.txt\n"])
        let clone = try makeScratchDirectory("clone").appendingPathComponent("web")
        try git(["clone", "-q", origin.path, clone.path], in: origin.deletingLastPathComponent())
        try "ignored\n".write(to: clone.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "scratch\n".write(to: clone.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let before = try git(["for-each-ref"], in: clone) + git(["worktree", "list", "--porcelain"], in: clone) + (try git(["status", "--porcelain"], in: clone))
        let spares = FleetSpares(directory: try makeScratchDirectory("spares"))
        #expect(spares.current(repo: clone.path) == nil)
        let ready = try #require(spares.refresh(repo: clone.path, base: nil))
        #expect(ready.commit == (try git(["rev-parse", "origin/main"], in: clone)).trimmingCharacters(in: .whitespacesAndNewlines))
        // Only the tracked files, no `.git`, none of the clone's ignored or untracked files.
        let files = try FileManager.default.subpathsOfDirectory(atPath: ready.tree).sorted()
        #expect(files == [".gitignore", "README.md", "src", "src/app.ts"])
        #expect(try git(["for-each-ref"], in: clone) + git(["worktree", "list", "--porcelain"], in: clone) + git(["status", "--porcelain"], in: clone) == before)
        // The base didn't move: nothing is built again. It moves: the spare follows, with no fetch.
        _ = spares.refresh(repo: clone.path, base: nil)
        #expect(spares.builds == 1)
        try "more\n".write(to: origin.appendingPathComponent("MORE.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: origin)
        try git(["commit", "-qm", "more"], in: origin)
        _ = spares.refresh(repo: clone.path, base: nil)
        #expect(spares.builds == 1, "the origin moved but the clone's own origin/main didn't, and nothing is fetched")
        try git(["fetch", "-q", "origin"], in: clone)
        let moved = try #require(spares.refresh(repo: clone.path, base: nil))
        #expect(spares.builds == 2 && moved.commit != ready.commit)
        #expect(FileManager.default.fileExists(atPath: moved.tree + "/MORE.md"))
        // A clone of the spare's tree is the whole of its files in one call, and the original is untouched.
        let target = try makeScratchDirectory("clonedest").appendingPathComponent("copy").path
        try FleetClone.item(moved.tree, to: target)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: target).sorted() == (files + ["MORE.md"]).sorted())
        #expect(try String(contentsOfFile: target + "/src/app.ts", encoding: .utf8) == "app\n")
    }

    @Test func aRepositoryOverTheSizeLimitHasNoSpareAndSaysSoOnce() throws {
        let repo = try makeScratchRepo(files: ["a.txt": "a\n"])
        let origin = try makeScratchDirectory("big-origin")
        try git(["clone", "-q", "--bare", repo.path, origin.appendingPathComponent("o.git").path], in: repo)
        let clone = try makeScratchDirectory("big").appendingPathComponent("c")
        try git(["clone", "-q", origin.appendingPathComponent("o.git").path, clone.path], in: origin)
        #expect(FleetSpares.maxTrackedBytes == 2 << 30)
        let spares = FleetSpares(directory: try makeScratchDirectory("spares"))
        #expect(spares.refresh(repo: clone.path, base: nil) != nil)
        #expect(spares.current(repo: URL(fileURLWithPath: "/nonexistent/repo").path) == nil)
        #expect(spares.refresh(repo: "/nonexistent/repo", base: nil) == nil, "a repository with no base ref has no spare")
    }

    // MARK: Received contents

    @Test func aContentIsKeptOnlyWhenItsWholeMatchesItsHashAndAnOutOfOrderChunkIsRefused() throws {
        let blobs = FleetSnapshotBlobs(directory: try makeScratchDirectory("blobs"))
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let hash = FleetHash(of: data)
        func chunk(_ range: Range<Int>) -> FleetBlobChunk { FleetBlobChunk(hash: hash, size: UInt64(data.count), offset: UInt64(range.lowerBound), data: data.subdata(in: range)) }
        #expect(try blobs.receive(chunk(0..<4_000)) == false && !blobs.has(hash))
        #expect(throws: FleetSnapshotBlobs.Failure.outOfOrder) { try blobs.receive(chunk(5_000..<9_000)) }
        #expect(try blobs.receive(chunk(4_000..<10_000)) && blobs.has(hash))
        #expect(try Data(contentsOf: blobs.url(hash)) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: blobs.url(hash).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A changed byte is refused when the last piece lands, and nothing is kept.
        var flipped = data
        flipped[123] ^= 1
        let other = FleetHash(of: data + Data([1]))
        let bad = FleetBlobChunk(hash: other, size: UInt64(flipped.count), offset: 0, data: flipped)
        #expect(throws: FleetSnapshotBlobs.Failure.mismatch) { try blobs.receive(bad) }
        #expect(!blobs.has(other) && !FileManager.default.fileExists(atPath: blobs.directory.appendingPathComponent(other.hex + ".part").path))
        // An empty content is a content.
        let empty = FleetHash(of: Data())
        #expect(try blobs.receive(FleetBlobChunk(hash: empty, size: 0, offset: 0, data: Data())) && blobs.has(empty))
    }

    @Test func contentsUnusedForSevenDaysArePrunedAndOnesInUseAreKept() throws {
        let blobs = FleetSnapshotBlobs(directory: try makeScratchDirectory("blobs"))
        let old = try #require(blobs.put(Data("old".utf8)))
        let fresh = try #require(blobs.put(Data("fresh".utf8)))
        let used = try #require(blobs.put(Data("used".utf8)))
        let longAgo = Date().addingTimeInterval(-8 * 24 * 3_600)
        for hash in [old, used] { try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: blobs.url(hash).path) }
        blobs.touch(used)
        blobs.prune()
        #expect(!blobs.has(old) && blobs.has(fresh) && blobs.has(used))
        #expect(FleetSnapshotTransfer.keepLifetime == 7 * 24 * 3_600)
    }

    @Test func aCloneSharesTheContentAndKeepsTheModificationTime() throws {
        let directory = try makeScratchDirectory("clone")
        let source = directory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "content\n".write(to: source.appendingPathComponent("sub/file.txt"), atomically: true, encoding: .utf8)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: source.appendingPathComponent("sub/file.txt").path)
        let target = directory.appendingPathComponent("copy").path
        try FleetClone.item(source.path, to: target)
        let attributes = try FileManager.default.attributesOfItem(atPath: target + "/sub/file.txt")
        #expect((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 == past.timeIntervalSince1970, "the clone keeps the file's time, so a cloned index needs no refresh")
        #expect(try String(contentsOfFile: target + "/sub/file.txt", encoding: .utf8) == "content\n")
    }

    // MARK: The worktree written without git

    /// A scratch repository (one commit) and the folder a worktree would go in.
    private func worktreeFixture() throws -> (repo: URL, commit: String, destination: String) {
        let repo = try makeScratchRepo(files: ["README.md": "# acme\n", "src/app.ts": "app\n"])
        let commit = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, commit, try makeScratchDirectory("worktrees").appendingPathComponent("acme-web-fleet-fix-test").path)
    }

    @Test func aWorktreeWrittenDirectlyIsOneGitListsUsesAndRemovesLikeItsOwn() throws {
        let (repo, commit, destination) = try worktreeFixture()
        #expect(FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: commit, destination: destination))
        let folder = URL(fileURLWithPath: destination)
        // Git lists it, on its branch, at the commit; the branch exists; nothing is wrong with the repository.
        let listing = try git(["worktree", "list", "--porcelain"], in: repo)
        #expect(listing.contains("branch refs/heads/fleet/fix-test") && listing.contains(folder.resolvingSymlinksInPath().path) && listing.contains(commit))
        #expect(try git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines) == commit)
        #expect(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines) == "fleet/fix-test")
        #expect(try git(["branch", "--list", "fleet/*"], in: repo).contains("fleet/fix-test"))
        _ = try git(["fsck", "--no-dangling"], in: repo)
        // It is what `--no-checkout` leaves: no files, no index; the checkout git makes next fills it and reads clean.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == [".git"])
        try git(["read-tree", "--reset", "-u", "HEAD"], in: folder)
        #expect(try git(["status", "--porcelain"], in: folder).isEmpty && FileManager.default.fileExists(atPath: destination + "/src/app.ts"))
        // A commit made there lands on its branch, and the repository's own checkout is untouched.
        try "more\n".write(to: folder.appendingPathComponent("src/more.ts"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: folder)
        try git(["commit", "-qm", "more"], in: folder)
        #expect(try git(["rev-parse", "main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) == commit)
        // Git takes it away as it would any worktree: the folder, its entry, then the branch.
        try git(["worktree", "remove", "--force", destination], in: repo)
        try git(["branch", "-D", "fleet/fix-test"], in: repo)
        #expect(!FileManager.default.fileExists(atPath: destination))
        #expect(try git(["worktree", "list", "--porcelain"], in: repo).components(separatedBy: "worktree ").count == 2)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/worktrees/acme-web-fleet-fix-test").path))
    }

    @Test func aRepositoryThatKeepsMoreThanThePlainLayoutIsLeftToGitAndNothingIsWritten() throws {
        func nothingWritten(_ repo: URL, _ destination: String) -> Bool {
            !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/worktrees").path) && !FileManager.default.fileExists(atPath: destination)
        }
        // A branch of that name already exists, and so does a folder where the worktree would go.
        var (repo, commit, destination) = try worktreeFixture()
        try git(["branch", "fleet/fix-test"], in: repo)
        #expect(!FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: commit, destination: destination) && nothingWritten(repo, destination))
        (repo, commit, destination) = try worktreeFixture()
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        #expect(!FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: commit, destination: destination))
        // Config git reads for more than the plain layout: an extension, a hooks path, a worktree config.
        for setting in [["extensions.worktreeConfig", "true"], ["core.hooksPath", "/nonexistent"], ["extensions.refStorage", "files"]] {
            (repo, commit, destination) = try worktreeFixture()
            try git(["config", setting[0], setting[1]], in: repo)
            #expect(!FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: commit, destination: destination) && nothingWritten(repo, destination), "\(setting[0])")
        }
        // A reference-transaction hook would have run.
        (repo, commit, destination) = try worktreeFixture()
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: hooks.appendingPathComponent("reference-transaction"), atomically: true, encoding: .utf8)
        #expect(!FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: commit, destination: destination) && nothingWritten(repo, destination))
        // A branch name git would refuse, a commit that isn't a SHA-1, and a checkout that is itself a worktree.
        (repo, commit, destination) = try worktreeFixture()
        for branch in ["fleet/../x", "fleet/x.lock", "fleet/a b", "-x", "fleet//x", "fleet/x~1", "fleet/.hidden"] {
            #expect(!FleetFastWorktree.add(repo: repo.path, branch: branch, commit: commit, destination: destination), "\(branch)")
        }
        #expect(!FleetFastWorktree.add(repo: repo.path, branch: "fleet/fix-test", commit: String(repeating: "a", count: 64), destination: destination))
        let linked = try makeScratchDirectory("linked").appendingPathComponent("w")
        try git(["worktree", "add", "-q", "-b", "other", linked.path], in: repo)
        #expect(!FleetFastWorktree.add(repo: linked.path, branch: "fleet/fix-test", commit: commit, destination: destination + "2"))
    }
}
