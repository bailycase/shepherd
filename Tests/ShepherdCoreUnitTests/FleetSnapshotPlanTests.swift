import Foundation
import Testing
@testable import ShepherdCore

/// The snapshot a dispatch carries (slice 4c): what differs from the pinned commit, the status digest, the path and link rules and the cap.
@Suite("Fleet snapshot plan")
struct FleetSnapshotPlanTests {
    static func hash(_ text: String) -> FleetHash { FleetHash(of: Data(text.utf8)) }
    static func gitID(_ text: String) -> FleetGitBlobID { FleetGitBlobID.of(Data(text.utf8)) }

    static func entry(_ content: String, kind: FleetEntryKind = .file, state: FleetGitClass = .tracked) -> FleetIndexEntry {
        FleetIndexEntry(kind: kind, size: UInt64(content.utf8.count), modified: 1, hash: hash(content), gitID: gitID(content), state: state)
    }

    static func tracked(_ content: String, kind: FleetEntryKind = .file) -> FleetTreeEntry { FleetTreeEntry(kind: kind, gitID: gitID(content)) }

    /// A checkout and its tree: `index` is the working files, `commit` the pinned tree (path to content).
    static func plan(commit: [String: String], executables: Set<String> = [], links: Set<String> = [], index: [String: String], extraKinds: [String: FleetEntryKind] = [:],
                     target: FleetManifest? = nil, gone: Set<String> = []) -> FleetSnapshotPlan {
        var tree = FleetMerkleTree()
        var entries: [String: FleetIndexEntry] = [:]
        for (path, content) in index {
            let kind = extraKinds[path] ?? .file
            entries[path] = entry(content, kind: kind, state: commit[path] == nil ? .untracked : .tracked)
            tree.set(path, kind: kind, hash: hash(content))
        }
        tree.commit()
        var tracked: [String: FleetTreeEntry] = [:]
        for (path, content) in commit { tracked[path] = Self.tracked(content, kind: executables.contains(path) ? .executable : links.contains(path) ? .symlink : .file) }
        return FleetSnapshotPlan.make(commit: String(repeating: "a", count: 40), tracked: tracked, entries: entries, tree: tree, target: target,
                                      goneFromDisk: { gone.contains($0) }, unindexedHash: { _ in hash("?") })
    }

    // MARK: What is dirty

    @Test func aCleanCheckoutHasNoFilesNoDirectoriesAndNoDeletions() {
        let plan = Self.plan(commit: ["a.txt": "A", "src/b.txt": "B"], index: ["a.txt": "A", "src/b.txt": "B"])
        #expect(plan.manifest.files.isEmpty && plan.manifest.directories.isEmpty && plan.manifest.deletions.isEmpty)
        #expect(plan.missing.isEmpty && plan.bytes == 0 && plan.manifest.problem == nil)
    }

    @Test func editsNewFilesDeletionsBinaryEmptyFilesLinksAndTheExecBitAreEachOneEntry() {
        let plan = Self.plan(
            commit: ["edit.txt": "old", "gone.txt": "bye", "same.txt": "same", "run.sh": "#!/bin/sh", "dir/keep.txt": "k"], executables: ["run.sh"],
            index: ["edit.txt": "new", "same.txt": "same", "run.sh": "#!/bin/sh", "dir/keep.txt": "k", "new.txt": "fresh", "empty.txt": "",
                    "blob.bin": String(decoding: [0, 255, 7, 0], as: UTF8.self), "link": "target/file", ".env": "KEY=1"],
            extraKinds: ["link": .symlink], gone: ["gone.txt"])
        let files = Dictionary(uniqueKeysWithValues: plan.manifest.files.map { ($0.path, $0) })
        #expect(Set(files.keys) == ["edit.txt", "new.txt", "empty.txt", "blob.bin", "link", ".env", "run.sh"])
        #expect(files["link"]?.kind == .symlink && files["empty.txt"]?.size == 0 && files["edit.txt"]?.hash == Self.hash("new"))
        // The exec bit dropped on a file whose content is the commit's is still a difference.
        #expect(files["run.sh"]?.kind == .file)
        #expect(plan.manifest.deletions == ["gone.txt"])
        #expect(plan.manifest.files.map(\.path) == plan.manifest.files.map(\.path).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }

    @Test func aRenamedFileIsADeletionAndANewFileOfContentTheTargetAlreadyHolds() {
        let held = FleetManifest([Self.hash("shared content").prefix])
        let plan = Self.plan(commit: ["old.txt": "shared content"], index: ["new.txt": "shared content"], target: held, gone: ["old.txt"])
        #expect(plan.manifest.deletions == ["old.txt"] && plan.manifest.files.map(\.path) == ["new.txt"])
        #expect(plan.missing.isEmpty && plan.bytes == 0, "the content is held, so nothing is sent for the new name")
    }

    @Test func aDirectoryNoTrackedFileIsInAndTheTargetHoldsIsNamedByHashAndOneItLacksIsExpanded() {
        let tree = ["node_modules/a/index.js": "A", "node_modules/b/index.js": "B", "src/x.ts": "X"]
        var merkle = FleetMerkleTree()
        for (path, content) in tree { merkle.set(path, kind: .file, hash: Self.hash(content)) }
        merkle.commit()
        let modules = merkle.hash(ofDirectory: "node_modules")!
        let held = Self.plan(commit: ["src/x.ts": "X"], index: tree, target: FleetManifest([modules.prefix]))
        #expect(held.manifest.directories.map(\.path) == ["node_modules"] && held.manifest.directories[0].files == 2 && held.manifest.files.isEmpty)
        #expect(held.missing.isEmpty && held.fileCount == 2)
        let lacking = Self.plan(commit: ["src/x.ts": "X"], index: tree, target: FleetManifest())
        #expect(lacking.manifest.directories.isEmpty && lacking.manifest.files.map(\.path) == ["node_modules/a/index.js", "node_modules/b/index.js"])
        // Either way the target ends with the same tree, so the root agrees.
        #expect(held.manifest.rootHash == lacking.manifest.rootHash)
        #expect(held.manifest.rootHash == merkle.root)
    }

    @Test func aDirectoryHoldingATrackedFileIsNeverNamedByHash() {
        var merkle = FleetMerkleTree()
        merkle.set("app/tracked.ts", kind: .file, hash: Self.hash("T"))
        merkle.set("app/generated.ts", kind: .file, hash: Self.hash("G"))
        merkle.commit()
        let plan = Self.plan(commit: ["app/tracked.ts": "T"], index: ["app/tracked.ts": "T", "app/generated.ts": "G"], target: FleetManifest([merkle.hash(ofDirectory: "app")!.prefix]))
        #expect(plan.manifest.directories.isEmpty && plan.manifest.files.map(\.path) == ["app/generated.ts"])
    }

    // MARK: Digest and root

    @Test func theDigestChangesWithAnyEntryTheCommitTheDeletionsAndTheRoot() {
        let base = Self.plan(commit: ["a": "A"], index: ["a": "A2", "b": "B"]).manifest
        func digest(_ change: (inout FleetSnapshotManifest) -> Void) -> FleetHash { var copy = base; change(&copy); return copy.digest }
        let original = base.digest
        #expect(digest { _ in } == original)
        #expect(digest { $0.files[0].hash = Self.hash("other") } != original)
        #expect(digest { $0.files[0].kind = .executable } != original)
        #expect(digest { $0.files[1].path = "c" } != original)
        #expect(digest { $0.commit = String(repeating: "b", count: 40) } != original)
        #expect(digest { $0.deletions = ["z"] } != original)
        #expect(digest { $0.rootHash = Self.hash("another tree") } != original)
        #expect(digest { $0.files.reverse() } == original, "order of the entries doesn't matter")
    }

    @Test func theRootIsWhatTheTargetBuildsFromTheCommitsTreeAndTheSnapshot() {
        let plan = Self.plan(commit: ["a": "A", "dir/b": "B", "gone": "G"], index: ["a": "A", "dir/b": "B2", "new": "N"], gone: ["gone"])
        let base: [String: (kind: FleetEntryKind, hash: FleetHash)] = ["a": (.file, Self.hash("A")), "dir/b": (.file, Self.hash("B")), "gone": (.file, Self.hash("G"))]
        let root = FleetSnapshotManifest.root(base: base, files: plan.manifest.files, directories: plan.manifest.directories, deletions: plan.manifest.deletions)
        #expect(root == plan.manifest.rootHash)
        var expected = FleetMerkleTree()
        for (path, content) in ["a": "A", "dir/b": "B2", "new": "N"] { expected.set(path, kind: .file, hash: Self.hash(content)) }
        expected.commit()
        #expect(root == expected.root)
    }

    // MARK: Cap and bytes sent

    @Test func theCapCountsBytesActuallySentAfterDedupe() {
        let held = FleetManifest([Self.hash("held content").prefix])
        let plan = Self.plan(commit: [:], index: ["one": "twelve bytes", "two": "twelve bytes", "held": "held content", "three": "other"], target: held)
        // "twelve bytes" once (12) and "other" (5); the held content costs nothing.
        #expect(plan.bytes == 17 && plan.missing.count == 2)
    }

    @Test func theCapRefusesAboveFourGiBWarnsAboveOneAndNeverRefusesBelow() {
        let gib: UInt64 = 1 << 30
        #expect(FleetSnapshotCap.verdict(bytes: 0) == .send)
        #expect(FleetSnapshotCap.verdict(bytes: gib) == .send, "exactly 1 GiB is not above the warning size")
        #expect(FleetSnapshotCap.verdict(bytes: gib + 1) == .warn)
        #expect(FleetSnapshotCap.verdict(bytes: 4 * gib) == .warn, "exactly 4 GiB is not above the cap")
        #expect(FleetSnapshotCap.verdict(bytes: 4 * gib + 1) == .refuse)
    }

    @Test func theBiggestContentsAreNamedForARefusal() {
        let plan = Self.plan(commit: [:], index: ["small": "s", "big/a.bin": String(repeating: "x", count: 900), "big/b.bin": String(repeating: "y", count: 500), "mid": String(repeating: "z", count: 100), "tiny": "t"])
        #expect(plan.biggest.map(\.path) == ["big/a.bin", "big/b.bin", "mid"] && plan.biggest.first?.bytes == 900)
    }

    // MARK: Paths and links

    @Test func pathsThatEscapeOrReachGitAreRefused() {
        for bad in ["", "/etc/passwd", "../outside", "a/../../b", "a//b", "./a", "a/./b", ".git/config", "a/.git/hooks/pre-commit", ".GIT/config", ".Git", "a\u{0}b", "a\nb"] {
            #expect(FleetSnapshotPaths.problem(bad) != nil, "\(bad.debugDescription) was accepted")
        }
        for good in ["a", "src/app.ts", ".env", ".gitignore", ".github/workflows/ci.yml", "node_modules/.bin/tool", "dir with space/é.txt"] {
            #expect(FleetSnapshotPaths.problem(good) == nil, "\(good) was refused")
        }
    }

    @Test func aLinkThatLeavesTheWorktreeIsRefused() {
        #expect(FleetSnapshotPaths.linkStaysInside(path: "node_modules/.bin/tool", target: "../pkg/bin/tool.sh"))
        #expect(FleetSnapshotPaths.linkStaysInside(path: "a", target: "b/c"))
        #expect(FleetSnapshotPaths.linkStaysInside(path: "a/b", target: "../c"))
        #expect(!FleetSnapshotPaths.linkStaysInside(path: "a", target: "../outside"))
        #expect(!FleetSnapshotPaths.linkStaysInside(path: "a/b", target: "../../outside"))
        #expect(!FleetSnapshotPaths.linkStaysInside(path: "a", target: "/etc/passwd"))
        #expect(!FleetSnapshotPaths.linkStaysInside(path: "a", target: ""))
    }

    @Test func aManifestIsRefusedForABadPathADuplicateOrAnEntryInsideAnother() {
        func manifest(files: [String] = [], directories: [String] = [], deletions: [String] = []) -> FleetSnapshotManifest {
            FleetSnapshotManifest(commit: String(repeating: "a", count: 40),
                                  files: files.map { FleetSnapshotFile(path: $0, kind: .file, hash: Self.hash($0), size: 1) },
                                  directories: directories.map { FleetSnapshotDirectory(path: $0, hash: Self.hash($0), files: 1, bytes: 1) },
                                  deletions: deletions, rootHash: Self.hash("root"))
        }
        #expect(manifest(files: ["a", "b/c"], directories: ["d"], deletions: ["e"]).problem == nil)
        #expect(manifest(files: ["../x"]).problem != nil)
        #expect(manifest(files: ["a/.git/config"]).problem != nil)
        #expect(manifest(files: ["a", "A"]).problem != nil, "a case-insensitive volume would make one of them the other")
        #expect(manifest(files: ["a"], deletions: ["a"]).problem != nil)
        #expect(manifest(files: ["link/inside"], directories: [], deletions: []).problem == nil)
        #expect(manifest(files: ["a", "a/b"]).problem != nil, "nothing may be written inside a file the manifest names")
        #expect(manifest(files: ["node_modules/x"], directories: ["node_modules"]).problem != nil)
        var bad = manifest(files: ["a"])
        bad.commit = "not a commit"
        #expect(bad.problem != nil)
    }

    @Test func aDirectoryNamedByHashIsTheSameTreeAsItsFiles() {
        var tree = FleetMerkleTree()
        tree.set("src/a.ts", kind: .file, hash: Self.hash("A"))
        var expanded = tree
        expanded.set("node_modules/p/i.js", kind: .file, hash: Self.hash("I"))
        expanded.set("node_modules/q/j.js", kind: .executable, hash: Self.hash("J"))
        expanded.commit()
        tree.setDirectory("node_modules", hash: expanded.hash(ofDirectory: "node_modules")!)
        tree.commit()
        #expect(tree.root == expanded.root)
        // And it moves with the directory's hash.
        tree.setDirectory("node_modules", hash: Self.hash("different"))
        tree.commit()
        #expect(tree.root != expanded.root)
    }
}
