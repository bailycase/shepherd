import Foundation
import Testing
@testable import ShepherdCore

/// The value types under a fleet's content index: Merkle hashes, manifests, and how two Macs' manifests compare.
@Suite("Fleet snapshot values")
struct FleetSnapshotTests {
    static func hash(_ text: String) -> FleetHash { FleetHash(of: Data(text.utf8)) }

    static func entry(_ content: String, kind: FleetEntryKind = .file, modified: Int64 = 1, state: FleetGitClass = .tracked) -> FleetIndexEntry {
        FleetIndexEntry(kind: kind, size: UInt64(content.utf8.count), modified: modified, hash: hash(content), gitID: FleetGitBlobID.of(Data(content.utf8)), state: state)
    }

    // MARK: Hashes

    @Test func hashesRoundTripThroughHexAndBytes() throws {
        let hash = Self.hash("hello")
        #expect(hash.hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(FleetHash(hex: hash.hex) == hash)
        #expect(FleetHash(digest: hash.bytes) == hash)
        #expect(FleetHash(hex: "zz") == nil && FleetHash(hex: String(repeating: "g", count: 64)) == nil)
        #expect(try JSONDecoder().decode(FleetHash.self, from: JSONEncoder().encode(hash)) == hash)
        // The id git gives "hello\n": what `git hash-object` prints.
        #expect(FleetGitBlobID.of(Data("hello\n".utf8)).hex == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func prefixesPackAndUnpackWhole() {
        let prefixes = (0..<5).map { Self.hash("file \($0)").prefix }
        let packed = FleetHashPrefix.pack(prefixes)
        #expect(packed.count == 5 * FleetHashPrefix.byteCount)
        #expect(FleetHashPrefix.unpack(packed) == prefixes)
        #expect(FleetHashPrefix.unpack(packed.dropLast()) == nil)
        #expect(FleetHashPrefix(hex: prefixes[0].hex) == prefixes[0])
    }

    // MARK: Merkle tree

    static func tree(_ files: [(String, String)], kinds: [String: FleetEntryKind] = [:]) -> FleetMerkleTree {
        var tree = FleetMerkleTree()
        for (path, content) in files { tree.set(path, kind: kinds[path] ?? .file, hash: hash(content)) }
        tree.commit()
        return tree
    }

    static let files = [("README.md", "# acme-web"), ("src/app.ts", "export {}"), ("src/lib/util.ts", "util"), ("src/lib/more/deep.ts", "deep"), ("package.json", "{}")]

    @Test func merkleHashesDoNotDependOnTheOrderThingsWereAdded() {
        let forward = Self.tree(Self.files)
        let backward = Self.tree(Self.files.reversed())
        let shuffled = Self.tree([Self.files[2], Self.files[4], Self.files[0], Self.files[3], Self.files[1]])
        #expect(forward.root == backward.root && forward.root == shuffled.root)
        #expect(forward.hash(ofDirectory: "src/lib") == backward.hash(ofDirectory: "src/lib"))
        // Added in two commits, the same.
        var split = FleetMerkleTree()
        for (path, content) in Self.files.prefix(2) { split.set(path, kind: .file, hash: Self.hash(content)) }
        split.commit()
        for (path, content) in Self.files.dropFirst(2) { split.set(path, kind: .file, hash: Self.hash(content)) }
        split.commit()
        #expect(split.root == forward.root)
    }

    @Test func merkleRootAndEveryAncestorChangeOnAnyDescendantEdit() {
        let before = Self.tree(Self.files)
        var edited = Self.files
        edited[3].1 = "deep, changed"
        let after = Self.tree(edited)
        #expect(before.root != after.root)
        for directory in ["src", "src/lib", "src/lib/more"] { #expect(before.hash(ofDirectory: directory) != after.hash(ofDirectory: directory), "\(directory)") }
        // A directory the edit did not touch keeps its hash: this is what lets a whole directory be referenced by one.
        var untouched = FleetMerkleTree()
        untouched.set("a/x", kind: .file, hash: Self.hash("x"))
        untouched.set("b/y", kind: .file, hash: Self.hash("y"))
        let was = untouched.commit()
        untouched.set("b/y", kind: .file, hash: Self.hash("y2"))
        let changes = untouched.commit()
        #expect(!was.isEmpty)
        #expect(Set(changes.map(\.path)) == ["b", ""])
        #expect(untouched.hash(ofDirectory: "a") == Self.tree([("a/x", "x")]).hash(ofDirectory: "a"))
    }

    @Test func merkleSeesTheExecBitAndALinkAsDifferentFromAPlainFile() {
        let plain = Self.tree([("bin/run", "echo")])
        let exec = Self.tree([("bin/run", "echo")], kinds: ["bin/run": .executable])
        let link = Self.tree([("bin/run", "echo")], kinds: ["bin/run": .symlink])
        #expect(Set([plain.root, exec.root, link.root]).count == 3)
    }

    @Test func removingDropsEmptyDirectoriesAndReportsTheHashesThatWent() {
        var tree = Self.tree(Self.files)
        let deep = tree.hash(ofDirectory: "src/lib/more")!
        tree.remove("src/lib/more/deep.ts")
        let changes = tree.commit()
        #expect(tree.hash(ofDirectory: "src/lib/more") == nil)
        #expect(changes.contains(.init(path: "src/lib/more", old: deep, new: nil)))
        #expect(tree.root == Self.tree(Self.files.filter { $0.0 != "src/lib/more/deep.ts" }).root)
        // A whole directory at once.
        tree.remove("src")
        tree.commit()
        #expect(tree.root == Self.tree([("README.md", "# acme-web"), ("package.json", "{}")]).root)
        #expect(tree.names(in: "src") == nil)
        // Everything gone is the empty tree.
        tree.remove("README.md"); tree.remove("package.json")
        tree.commit()
        #expect(tree.root == FleetMerkleTree().root)
    }

    @Test func aFileTakingTheNameOfADirectoryReplacesIt() {
        var tree = Self.tree([("a/b/c", "1"), ("a/d", "2")])
        tree.set("a/b", kind: .file, hash: Self.hash("now a file"))
        tree.commit()
        #expect(tree.root == Self.tree([("a/b", "now a file"), ("a/d", "2")]).root)
        #expect(tree.hash(ofDirectory: "a/b") == nil)
    }

    // MARK: Index diffs

    @Test func indexDiffNamesAddedRemovedChangedTouchedModeAndRenamedPaths() {
        let old: [String: FleetIndexEntry] = [
            "keep.txt": Self.entry("keep"), "gone.txt": Self.entry("gone"), "edit.txt": Self.entry("v1"), "touch.txt": Self.entry("same", modified: 1),
            "run.sh": Self.entry("#!/bin/sh"), "old-name.txt": Self.entry("moved"), "ignored.log": Self.entry("log", state: .untracked),
        ]
        let new: [String: FleetIndexEntry] = [
            "keep.txt": Self.entry("keep"), "edit.txt": Self.entry("v2"), "touch.txt": Self.entry("same", modified: 9),
            "run.sh": Self.entry("#!/bin/sh", kind: .executable), "new-name.txt": Self.entry("moved"), "fresh.txt": Self.entry("fresh"),
            "ignored.log": Self.entry("log", state: .ignored),
        ]
        let diff = FleetIndexDiff.between(old, new)
        #expect(diff.added == ["fresh.txt", "new-name.txt"])
        #expect(diff.removed == ["gone.txt", "old-name.txt"])
        // A new mode is a change (the dispatch has to carry it); a new time alone is not.
        #expect(diff.changed == ["edit.txt", "run.sh"])
        #expect(diff.touched == ["touch.txt"])
        #expect(diff.reclassified == ["ignored.log"])
        #expect(diff.renamed.map { [$0.from, $0.to] } == [["old-name.txt", "new-name.txt"]])
        #expect(FleetIndexDiff.between(new, new).isEmpty)
    }

    // MARK: Manifests

    @Test func theRunningDigestIsTheOneComputedFromScratchWhateverTheOrder() {
        let prefixes = (0..<200).map { Self.hash("blob \($0)").prefix }
        var manifest = FleetManifest()
        for prefix in prefixes { manifest.insert(prefix) }
        for prefix in prefixes.prefix(50) { manifest.remove(prefix) }
        for prefix in prefixes.prefix(20) { manifest.insert(prefix) }
        let remaining = Set(prefixes.dropFirst(50)).union(prefixes.prefix(20))
        #expect(manifest.digest == FleetManifest.digest(of: remaining.shuffled()))
        #expect(manifest.digest.count == remaining.count)
        // Adding twice or removing what is not there changes nothing.
        #expect(!manifest.insert(prefixes[100]) && !manifest.remove(prefixes[40]))
        #expect(manifest.digest == FleetManifest.digest(of: remaining))
        // A set that differs by one prefix differs in its digest.
        var other = manifest
        other.insert(Self.hash("extra").prefix)
        #expect(other.digest != manifest.digest)
    }

    @Test func missingIsDecidedByTheFirst128BitsAndOnlyErrsTowardHeld() {
        let held = [Self.hash("one"), Self.hash("two")]
        let manifest = FleetManifest(held.map(\.prefix))
        let wanted = [Self.hash("one"), Self.hash("three"), Self.hash("three"), Self.hash("four")]
        #expect(FleetManifestDiff.missing(wanted, from: manifest) == [Self.hash("three"), Self.hash("four")])
        // Two hashes that share their first 128 bits are the same to a manifest: it says held. The target repairs that
        // by asking for the blob (4c); it is never a reason to send less than the target can verify.
        let sibling = FleetHash(a: held[0].prefix.hi, b: held[0].prefix.lo, c: 1, d: 2)
        #expect(sibling != held[0] && sibling.prefix == held[0].prefix)
        #expect(FleetManifestDiff.missing([sibling], from: manifest).isEmpty)
    }

    @Test func aReceiverJudgesAStepAgainstTheCopyItHolds() {
        let digest = FleetManifest([Self.hash("a").prefix]).digest
        let held = FleetManifestHead(generation: 7, seq: 3, digest: digest)
        func head(_ generation: UInt64, _ seq: UInt64, _ digest: FleetManifestDigest = digest) -> FleetManifestHead { .init(generation: generation, seq: seq, digest: digest) }
        // A delta: the next one applies, an old one is nothing, a gap is caught up, another generation starts over.
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 4), carriesDelta: true) == .apply)
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 3), carriesDelta: true) == .inSync)
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 6), carriesDelta: true) == .catchUp)
        #expect(FleetManifestDiff.judge(held: held, announced: head(8, 4), carriesDelta: true) == .resend)
        #expect(FleetManifestDiff.judge(held: nil, announced: head(7, 4), carriesDelta: true) == .resend)
        // A head: the same place and the same digest is in sync, the same place with another digest is a mismatch (resync),
        // behind is caught up, and a sender behind its own copy can't be right.
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 3), carriesDelta: false) == .inSync)
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 3, .empty), carriesDelta: false) == .resend)
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 5), carriesDelta: false) == .catchUp)
        #expect(FleetManifestDiff.judge(held: held, announced: head(7, 2), carriesDelta: false) == .resend)
        #expect(FleetManifestDiff.verifies(FleetManifest([Self.hash("a").prefix]), against: held))
        #expect(!FleetManifestDiff.verifies(FleetManifest(), against: held))
    }
}
