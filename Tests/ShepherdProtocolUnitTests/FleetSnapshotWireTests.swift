import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// The manifest messages (`fleet.snapshot.v1`): what a step must look like to be taken, what an older peer's JSON decodes to, and
/// that a snapshot from a host with no index still reads.
@Suite("Fleet snapshot wire")
struct FleetSnapshotWireTests {
    static let prefixes = (0..<3).map { FleetHash(of: Data("blob \($0)".utf8)).prefix }

    @Test func aStepIsWellFormedOnlyIfItsDataFitsItsKind() {
        let digest = FleetManifest(Self.prefixes).digest
        let data = FleetHashPrefix.pack(Self.prefixes)
        func update(_ kind: FleetRepoManifestUpdate.Kind, seq: UInt64 = 0, added: Data = Data(), removed: Data = Data(), part: Int = 0, parts: Int = 1, repo: String = "github.com/acme/web") -> FleetRepoManifestUpdate {
            FleetRepoManifestUpdate(repo: repo, kind: kind, generation: 9, seq: seq, added: added, removed: removed, part: part, parts: parts, digest: digest)
        }
        #expect(update(.full, seq: 4, added: data, part: 1, parts: 2).isValid)
        #expect(!update(.full, removed: data).isValid, "a full set removes nothing")
        #expect(!update(.full, part: 2, parts: 2).isValid && !update(.full, parts: 0).isValid && !update(.full, parts: FleetSnapshotProtocol.maxParts + 1).isValid)
        #expect(update(.delta, seq: 1, added: data, removed: data).isValid && !update(.delta, seq: 0).isValid && !update(.delta, seq: 1, parts: 2).isValid)
        #expect(update(.head, seq: 3).isValid && !update(.head, added: data).isValid)
        #expect(!update(.head, repo: "").isValid && !update(.head, repo: String(repeating: "x", count: FleetSnapshotProtocol.maxRepoNameBytes + 1)).isValid)
        #expect(!update(.delta, seq: 1, added: data.dropLast()).isValid, "a prefix is 16 bytes")
        let big = Data(count: (FleetSnapshotProtocol.maxBatchPrefixes + 1) * FleetHashPrefix.byteCount)
        #expect(!update(.full, added: big).isValid)
        #expect(update(.full, added: big.prefix(FleetSnapshotProtocol.maxBatchPrefixes * FleetHashPrefix.byteCount)).isValid)
    }

    @Test func aStepDecodesWithDefaultsAndWritesOnlyWhatItCarries() throws {
        let head = FleetRepoManifestUpdate(repo: "github.com/acme/web", kind: .head, generation: 9, seq: 3, digest: FleetManifest(Self.prefixes).digest)
        let text = String(decoding: try JSONEncoder().encode(head), as: UTF8.self)
        for absent in ["added", "removed", "part", "parts"] { #expect(!text.contains("\"\(absent)\""), "\(absent)") }
        // What another build wrote without the optional fields.
        let minimal = Data("""
        {"repo":"r","kind":"delta","generation":1,"seq":2,"digest":{"count":0,"xor":"00000000000000000000000000000000"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(FleetRepoManifestUpdate.self, from: minimal)
        #expect(decoded.added.isEmpty && decoded.removed.isEmpty && decoded.part == 0 && decoded.parts == 1 && decoded.digest == .empty)
        #expect(try JSONDecoder().decode(FleetRepoManifestAck.self, from: Data(#"{"repo":"r","generation":1,"seq":2}"#.utf8)).resend == false)
        #expect(try JSONDecoder().decode(FleetRepoManifestUpdate.self, from: JSONEncoder().encode(head)) == head)
    }

    @Test func aSnapshotFromAHostThatDoesNotIndexStillDecodes() throws {
        let old = Data(#"{"enabled":true,"name":"Mac mini","addresses":[],"advertising":false,"peers":[]}"#.utf8)
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: old).index == nil)
        let repo = try JSONDecoder().decode(FleetIndexStatus.Repo.self, from: Data(#"{"repo":"r","name":"n","files":3,"ready":true}"#.utf8))
        #expect(repo.tooLarge == false)
        // The wire says nothing of a flag that is off.
        let text = String(decoding: try JSONEncoder().encode(repo), as: UTF8.self)
        #expect(!text.contains("tooLarge"))
    }

    /// What a phone reads of a Mac's fleet says nothing of what its files are being indexed.
    @Test func theViewAClientIsGivenCarriesNoIndexStatus() {
        var snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "Mac mini")
        snapshot.index = FleetIndexStatus(indexing: true, repos: [.init(repo: "github.com/acme/web", name: "acme-web", files: 3, ready: false)])
        #expect(snapshot.clientView.index == nil)
    }
}

/// What a Mac without the repository is told (slice 4f): the origin and space to clone it as, and the repository itself in a bundle.
@Suite("Fleet clone wire")
struct FleetCloneWireTests {
    @Test func aCreateFromAnOlderSenderCarriesNoRepoAndANewOneWritesOnlyWhatItHas() throws {
        let old = Data("""
        {"dispatchID":"5D4F1F6E-2B0C-4C86-9E43-7F5B7E0A9C11","kind":"agentDispatch","task":"x","title":"x","repoKey":"github.com/acme/web",
         "from":{"hostID":"00000000-0000-0000-0000-0000000000F1","hostName":"MacBook Pro","agentTitle":"t"}}
        """.utf8)
        #expect(try JSONDecoder().decode(FleetDispatchCreate.self, from: old).repo == nil)
        let plain = FleetDispatchCreate(dispatchID: UUID(), task: "x", title: "x", repoKey: "github.com/acme/web",
                                        from: FleetDispatchSender(hostID: UUID(), hostName: "A", agentTitle: ""))
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("\"repo\""))
        let source = FleetRepoSource(origin: "git@github.com:acme/web.git", name: "web")
        let text = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(text.contains("origin") && text.contains("name") && !text.contains("spaceID") && !text.contains("worktreeBase"))
    }

    @Test func aSnapshotHeaderIsAWholeRepositoryOnlyWhenItSaysSoAndNamesTheBundle() throws {
        let hash = FleetHash(of: Data("x".utf8))
        func header(repoBundle: Bool, bundle: FleetBlobRef?) -> FleetSnapshotHeader {
            FleetSnapshotHeader(commit: String(repeating: "a", count: 40), rootHash: hash, digest: hash, files: 0, directories: 0, deletions: 0, parts: 0, fileCount: 0,
                                bytes: 10, bundle: bundle, repoBundle: repoBundle)
        }
        let ref = FleetBlobRef(hash: hash, size: 10)
        #expect(header(repoBundle: true, bundle: ref).isValid && header(repoBundle: false, bundle: nil).isValid)
        #expect(!header(repoBundle: true, bundle: nil).isValid, "a repository that isn't sent isn't one")
        #expect(!String(decoding: try JSONEncoder().encode(header(repoBundle: false, bundle: ref)), as: UTF8.self).contains("repoBundle"))
        #expect(try JSONDecoder().decode(FleetSnapshotHeader.self, from: JSONEncoder().encode(header(repoBundle: true, bundle: ref))).repoBundle)
    }

    @Test func aRecordFromAnOlderBuildHasNoCloneAndNothingIsWrittenForOne() throws {
        let record = FleetDispatchRecord(parentHostID: UUID(), parentHostName: "A", title: "t", task: "x", repoKey: "github.com/acme/web", createdAt: 1)
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for absent in ["clone", "origin", "spaceID"] { #expect(!text.contains("\"\(absent)\""), "\(absent)") }
        let decoded = try JSONDecoder().decode(FleetDispatchRecord.self, from: Data(text.utf8))
        #expect(decoded.clone == nil && decoded.origin == nil && decoded.spaceID == nil)
        let progress = try JSONDecoder().decode(FleetCloneProgress.self, from: Data(#"{"name":"web","source":"github.com/acme/web"}"#.utf8))
        #expect(progress.phase == nil && progress.fraction == nil && !progress.viaBundle)
    }
}
