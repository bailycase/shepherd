import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit

/// Manifests as a stream: what a Mac announces of a repository, how a peer's copy follows it, and what happens when the copy
/// and the announcement stop agreeing.
@Suite("Fleet manifests")
struct FleetManifestTests {
    static let peer = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let repo = "github.com/acme/web"

    static func hashes(_ names: some Sequence<String>) -> [FleetHash] { names.map { FleetHash(of: Data($0.utf8)) } }

    /// A local manifest holding `names`, flushed.
    static func local(_ names: [String], repo: String = repo) -> FleetLocalManifest {
        let manifest = FleetLocalManifest(repo: repo)
        manifest.add(hashes(names))
        manifest.flush()
        return manifest
    }

    // MARK: The sender's manifest

    @Test func changesPileUpAndBecomeOneDeltaWithTheNextSequenceNumber() {
        let manifest = Self.local(["a", "b", "c"])
        #expect(manifest.seq == 1 && manifest.manifest.count == 3)
        // Add and remove of one hash inside a window cancel; a hash held twice leaves when its last holder does.
        manifest.add(Self.hashes(["d", "e", "e"]))
        manifest.remove(Self.hashes(["d", "a", "e"]))
        let delta = manifest.flush()
        #expect(delta?.seq == 2)
        #expect(Set(delta?.added ?? []) == Set(Self.hashes(["e"]).map(\.prefix)) && Set(delta?.removed ?? []) == Set(Self.hashes(["a"]).map(\.prefix)))
        #expect(manifest.manifest == FleetManifest(Self.hashes(["b", "c", "e"]).map(\.prefix)))
        manifest.remove(Self.hashes(["e"]))
        #expect(manifest.manifest.contains(Self.hashes(["e"])[0]), "not yet flushed")
        manifest.flush()
        #expect(!manifest.manifest.contains(Self.hashes(["e"])[0]))
        // Nothing pending, nothing flushed, no new number.
        #expect(manifest.flush() == nil && manifest.seq == 3)
    }

    @Test func theFullSetComesInBatchesThatAddUpToTheSetAndItsDigest() {
        let names = (0..<(FleetSnapshotProtocol.maxBatchPrefixes * 2 + 100)).map { "file-\($0)" }
        let manifest = Self.local(names)
        let parts = manifest.fullUpdates()
        #expect(parts.count == 3 && parts.map(\.part) == [0, 1, 2] && parts.allSatisfy { $0.parts == 3 && $0.kind == .full && $0.isValid })
        #expect(parts.allSatisfy { $0.seq == manifest.seq && $0.digest == manifest.manifest.digest })
        let rebuilt = parts.flatMap { FleetHashPrefix.unpack($0.added) ?? [] }
        #expect(Set(rebuilt) == manifest.manifest.prefixes && rebuilt.count == names.count)
        // Even an empty set is one part.
        #expect(FleetLocalManifest(repo: "x").fullUpdates().count == 1)
    }

    @Test func aPeerBehindIsCaughtUpFromTheLogAndOneTooFarBehindGetsTheFullSet() {
        let manifest = Self.local(["a"])
        for step in 0..<5 { manifest.add(Self.hashes(["x\(step)"])); manifest.flush() }
        let generation = manifest.generation
        let deltas = manifest.updates(after: (generation, 2))
        #expect(deltas?.map(\.seq) == [3, 4, 5, 6])
        #expect(manifest.updates(after: (generation, manifest.seq))?.isEmpty == true)
        #expect(manifest.updates(after: (generation &+ 1, 2)) == nil, "another generation can't be continued")
        // More than the log keeps.
        for step in 0..<(FleetLocalManifest.keptDeltas + 5) { manifest.add(Self.hashes(["y\(step)"])); manifest.flush() }
        #expect(manifest.updates(after: (generation, 1)) == nil)
        #expect(manifest.updates(after: (generation, manifest.seq - 3))?.count == 3)
        // A delta bigger than a frame is not sent as one.
        let big = Self.local([])
        big.add(Self.hashes((0...FleetSnapshotProtocol.maxBatchPrefixes).map { "big-\($0)" }))
        big.flush()
        #expect(big.updates(after: (big.generation, 0)) == nil)
    }

    // MARK: A peer's copy

    /// What a peer does with a sender's stream, step by step.
    static func deliver(_ updates: [FleetRepoManifestUpdate], into copies: inout FleetPeerManifests) -> [FleetRepoManifestAck] {
        updates.map { copies.receive($0, from: peer) }
    }

    @Test func aFullSetThenDeltasKeepTheCopyEqualToTheSenders() throws {
        let sender = Self.local((0..<100).map { "file-\($0)" })
        var copies = FleetPeerManifests()
        #expect(copies.receive(sender.headUpdate(), from: Self.peer).resend, "nothing held: send it all")
        let acks = Self.deliver(sender.fullUpdates(), into: &copies)
        #expect(acks.allSatisfy { !$0.resend } && acks.last?.generation == sender.generation && acks.last?.seq == sender.seq)
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == sender.manifest)
        for step in 0..<5 {
            sender.add(Self.hashes(["new-\(step)"])); sender.remove(Self.hashes(["file-\(step)"]))
            sender.flush()
        }
        let followUp = try #require(sender.updates(after: (sender.generation, 1)))
        #expect(Self.deliver(followUp, into: &copies).allSatisfy { !$0.resend })
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == sender.manifest)
        #expect(copies.copy(of: Self.peer, repo: Self.repo)?.head == sender.head)
        // A head that matches is in sync; the same step with another digest is a mismatch.
        #expect(!copies.receive(sender.headUpdate(), from: Self.peer).resend)
        var liar = sender.headUpdate()
        liar.digest = .empty
        #expect(copies.receive(liar, from: Self.peer).resend)
    }

    @Test func aGapIsCaughtUpAndADigestThatDoesNotMatchDropsTheCopy() throws {
        let sender = Self.local(["a", "b"])
        var copies = FleetPeerManifests()
        _ = Self.deliver(sender.fullUpdates(), into: &copies)
        for step in 0..<3 { sender.add(Self.hashes(["n\(step)"])); sender.flush() }
        let steps = try #require(sender.updates(after: (sender.generation, 1)))
        // Step 3 first: the copy is at 1, so this is a gap. It says where it stands and does not apply it.
        let gap = copies.receive(steps[1], from: Self.peer)
        #expect(!gap.resend && gap.seq == 1)
        #expect(copies.copy(of: Self.peer, repo: Self.repo)?.head.seq == 1)
        // A delta whose digest the copy cannot reproduce is refused, and the copy is dropped rather than kept half applied.
        var wrong = steps[0]
        wrong.digest = FleetManifestDigest(count: 99, xor: FleetHashPrefix(hi: 1, lo: 1))
        #expect(copies.receive(wrong, from: Self.peer).resend)
        #expect(copies.copy(of: Self.peer, repo: Self.repo) == nil)
        // Anything for a copy that is gone is a resend, until the full set arrives again.
        #expect(copies.receive(steps[2], from: Self.peer).resend)
        _ = Self.deliver(sender.fullUpdates(), into: &copies)
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == sender.manifest)
    }

    @Test func aSendersNewGenerationReplacesTheCopyAndAStaleOneIsNotContinued() {
        let first = Self.local(["a", "b", "c"])
        var copies = FleetPeerManifests()
        _ = Self.deliver(first.fullUpdates(), into: &copies)
        // The sender restarted: another generation, another set. Its head is a mismatch; its full set replaces the copy.
        let second = Self.local(["x", "y"])
        #expect(first.generation != second.generation)
        #expect(copies.receive(second.headUpdate(), from: Self.peer).resend)
        _ = Self.deliver(second.fullUpdates(), into: &copies)
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == second.manifest)
        // A delta of the old generation, arriving late, is a resend request, not an edit.
        first.add(Self.hashes(["late"]))
        let late = first.flush()
        #expect(late != nil)
        #expect(copies.receive(first.updates(after: (first.generation, 1))!.first!, from: Self.peer).resend)
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == second.manifest)
    }

    @Test func aFullSetThatArrivesOutOfOrderOrIncompleteReplacesNothing() {
        let sender = Self.local((0..<(FleetSnapshotProtocol.maxBatchPrefixes + 10)).map { "f\($0)" })
        let parts = sender.fullUpdates()
        var copies = FleetPeerManifests()
        _ = Self.deliver(Self.local(["old"]).fullUpdates(), into: &copies)
        let oldHead = copies.copy(of: Self.peer, repo: Self.repo)?.head
        // Part 1 without part 0, and part 0 alone: the old copy stays.
        #expect(copies.receive(parts[1], from: Self.peer).resend)
        #expect(!copies.receive(parts[0], from: Self.peer).resend)
        #expect(copies.copy(of: Self.peer, repo: Self.repo)?.head == oldHead)
        // A part 0 that starts over discards the staging; the whole set then lands once.
        _ = Self.deliver(parts, into: &copies)
        #expect(copies.manifest(of: Self.peer, repo: Self.repo) == sender.manifest)
    }

    @Test func malformedStepsAndTooManyRepositoriesAreRefused() {
        var copies = FleetPeerManifests()
        var bad = Self.local(["a"]).fullUpdates()[0]
        bad.added = Data(repeating: 1, count: 17)
        #expect(!bad.isValid && copies.receive(bad, from: Self.peer).resend)
        #expect(!FleetRepoManifestUpdate(repo: "", kind: .head, generation: 1, seq: 0, digest: .empty).isValid)
        #expect(!FleetRepoManifestUpdate(repo: "r", kind: .delta, generation: 1, seq: 0, digest: .empty).isValid)
        #expect(!FleetRepoManifestUpdate(repo: "r", kind: .head, generation: 1, seq: 0, added: Data(count: 16), digest: .empty).isValid)
        for index in 0..<FleetPeerManifests.maxRepos {
            #expect(!copies.receive(Self.local(["a"], repo: "repo-\(index)").fullUpdates()[0], from: Self.peer).resend)
        }
        #expect(copies.receive(Self.local(["a"], repo: "one-too-many").fullUpdates()[0], from: Self.peer).resend)
    }

    @Test func peerCopiesSurviveARestartAndAnEditedFileIsNotTrusted() throws {
        let directory = try makeScratchDirectory("peers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = Self.local((0..<300).map { "file-\($0)" })
        var copies = FleetPeerManifests()
        _ = Self.deliver(sender.fullUpdates(), into: &copies)
        let save = copies.takeSave(to: directory)
        try #require(save != nil)
        save?()
        let again = copies.takeSave(to: directory)
        #expect(again == nil, "nothing changed since")
        let loaded = FleetPeerManifests.load(from: directory)
        #expect(loaded.manifest(of: Self.peer, repo: Self.repo) == sender.manifest)
        #expect(loaded.copy(of: Self.peer, repo: Self.repo)?.head == sender.head)
        // Mode 0600, like the rest of the fleet's files.
        let file = try #require(FileManager.default.enumerator(atPath: directory.path)?.compactMap { $0 as? String }.first { $0.hasSuffix(".manifest") })
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The peer's head finds the copy still good: no resend after a restart.
        var restarted = loaded
        #expect(!restarted.receive(sender.headUpdate(), from: Self.peer).resend)
        // A file cut short (a power loss) is not trusted: its digest no longer matches.
        let path = directory.appendingPathComponent(file)
        let data = try Data(contentsOf: path)
        try data.dropLast(16).write(to: path)
        #expect(FleetPeerManifests.load(from: directory).manifest(of: Self.peer, repo: Self.repo) == nil)
        // A peer that leaves takes its copies with it.
        FleetPeerManifests.erase(Self.peer, in: directory)
        #expect(FleetPeerManifests.load(from: directory).repos(of: Self.peer).isEmpty)
    }

    // MARK: The index on disk

    @Test func theIndexOnDiskIsASnapshotAndAJournalAndATruncatedLineEndsTheJournal() throws {
        let directory = try makeScratchDirectory("index-storage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FleetIndexStorage(directory: directory.appendingPathComponent("a", isDirectory: true))
        func entry(_ text: String, state: FleetGitClass = .tracked) -> FleetIndexEntry {
            FleetIndexEntry(kind: .file, size: UInt64(text.utf8.count), modified: 5, hash: FleetHash(of: Data(text.utf8)), gitID: FleetGitBlobID.of(Data(text.utf8)), state: state)
        }
        var entries = ["a.txt": entry("a"), "dir/b.txt": entry("b"), "weird \"name\"\n.txt": entry("c", state: .ignored)]
        try storage.writeSnapshot(entries)
        let meta = FleetIndexStorage.Meta(version: FleetIndexStorage.version, root: "/r", rules: "k", eventID: 42, volume: "V")
        try storage.writeMeta(meta)
        // Journal: one changed, one removed, one new.
        entries["a.txt"] = entry("a2")
        entries["dir/b.txt"] = nil
        entries["new.txt"] = entry("n")
        try storage.appendJournal(["a.txt", "dir/b.txt", "new.txt"], entries: entries)
        let loaded = try #require(storage.load(root: "/r", rules: "k"))
        #expect(loaded.entries == entries && loaded.meta == meta && loaded.journalLines == 3)
        // Another root or other rules: not this index.
        #expect(storage.load(root: "/other", rules: "k") == nil && storage.load(root: "/r", rules: "other") == nil)
        // A crash in the middle of a journal line loses that line and nothing before it.
        let journal = storage.directory.appendingPathComponent("journal.ndjson")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"p\":\"cut".utf8))
        try handle.close()
        #expect(storage.load(root: "/r", rules: "k")?.entries == entries)
        // A new snapshot empties the journal.
        try storage.writeSnapshot(entries)
        #expect(storage.load(root: "/r", rules: "k")?.journalLines == 0 && storage.bytesOnDisk > 0)
    }
}
