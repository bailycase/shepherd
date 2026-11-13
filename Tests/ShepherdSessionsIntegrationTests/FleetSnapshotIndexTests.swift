import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The warm content index and the manifests between real scratch hosts (slice 4b): two Macs, each its own scratch server, one
/// with a scratch git repository (made up files) that its space points at. What its index holds reaches the other Mac's copy of
/// its manifest, an edit follows through FSEvents without a rescan, a lost event is repaired by the spot check, a copy that doesn't
/// match is resent, and a restart replays from the saved event id and finds a change made while the host was down.
@Suite("Fleet snapshot index", .integrationTimeLimit)
struct FleetSnapshotIndexTests {
    typealias Mac = FleetSyncTests.Mac

    static let origin = "github.com/acme/web"
    static let files = [
        "README.md": "# acme-web\n", "package.json": "{\"name\":\"acme-web\"}\n", "src/app.ts": "export const app = 1\n", "src/lib/util.ts": "export const util = 2\n",
        "src/lib/more.ts": "export const more = 3\n", "scripts/run.sh": "#!/bin/sh\necho hi\n", ".gitignore": "node_modules/\n.env\n*.log\n",
    ]
    static let ignored = [".env": "TOKEN=made-up\n", "node_modules/left-pad/index.js": "module.exports = 1\n", "debug.log": "noise\n"]

    /// A scratch checkout with an origin, so the repository has a key every Mac gives it.
    static func checkout(files: [String: String] = files, ignored: [String: String] = ignored) throws -> URL {
        let url = try makeScratchRepo(files: files)
        try git(["remote", "add", "origin", "git@github.com:Acme/web.git"], in: url)
        for (path, content) in ignored {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        return url
    }

    /// Two paired Macs, the first with a space on `repo`. Fleet is switched on after the space exists.
    static func pair(repo: URL, files: Int = 0) async throws -> (a: Mac, b: Mac, space: Space) {
        let a = try await Mac("MacBook Pro", enable: false), b = try await Mac("Mac mini", enable: false)
        let space = Space(name: "acme-web", path: repo.path)
        try await a.server.addSpace(space)
        a.enable(); b.enable()
        try await a.pair(with: b)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        return (a, b, space)
    }
}

extension FleetSyncTests.Mac {
    var service: FleetIndexService? { server.queue.sync { server.fleet?.index } }

    func index(_ repo: URL) -> FleetContentIndex? { server.queue.sync { server.fleet?.index.index(at: repo.path) } }

    func localManifest(_ repo: String = FleetSnapshotIndexTests.origin) -> FleetManifest? { server.queue.sync { server.fleet?.index.localManifest(repo: repo) } }

    func manifest(of other: UUID, _ repo: String = FleetSnapshotIndexTests.origin) -> FleetManifest? {
        server.queue.sync { server.fleet?.index.manifest(of: other, repo: repo) }
    }

    func hostID() async throws -> UUID { try #require(try await read().hostID) }

    /// This Mac's manifest of the repository is the one its peer holds of it.
    func peerHolds(_ other: FleetSyncTests.Mac, of source: FleetSyncTests.Mac) async throws -> Bool {
        let sourceID = try await source.hostID()
        guard let theirs = other.manifest(of: sourceID), let mine = source.localManifest() else { return false }
        return theirs == mine && mine.count > 0
    }

    /// A client authenticated as the Mac `other` is, with the token `other` presents to this one.
    func connectAsPeer(_ other: FleetSyncTests.Mac) async throws -> RemoteHostClient {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: other.host.dir.appendingPathComponent("fleet/peers.json"))) as? [String: Any])
        let peers = try #require(file["peers"] as? [[String: Any]])
        let token = try #require(peers.first { $0["name"] as? String == name }?["myToken"] as? String)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: other.name, capabilities: [], expectingHostID: nil, fetchesState: false)
        return client
    }
}

extension FleetSnapshotIndexTests {
    func hash(_ text: String) -> FleetHash { FleetHash(of: Data(text.utf8)) }

    // MARK: Who gets indexed, and when

    @Test func nothingIsIndexedUntilAMacIsPaired() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = try await Mac("MacBook Pro", enable: false)
        defer { a.stop() }
        try await a.server.addSpace(Space(name: "acme-web", path: repo.path))
        a.enable()
        // Nobody is paired: no index, no manifest, nothing on disk, nothing reported.
        #expect(a.service?.isActive == false && a.index(repo) == nil)
        #expect(try await a.read().index == nil)
        #expect(!FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/index/roots").path))

        let b = try await Mac("Mac mini")
        defer { b.stop() }
        let paired = try await a.pair(with: b)
        try await eventually("the index to start and finish its first scan") { try await a.read().index?.repos.first?.ready == true }
        let status = try #require(try await a.read().index)
        #expect(status.indexing == false && status.repos.first?.name == "acme-web" && status.repos.first?.files == Self.files.count + Self.ignored.count)
        // The last Mac leaves the fleet: the index stops reading, and says nothing.
        _ = try await a.local.fleetAction(.remove(hostID: paired.hostID))
        try await eventually("the index to stop") { a.service?.isActive == false }
        #expect(try await a.read().index == nil)
    }

    @Test func theIndexHoldsTheRepositoryWithItsGitClassesAndLeavesNothingInTheRepository() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let before = try git(["status", "--porcelain=v1", "--ignored"], in: repo)
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("A's index to be ready") { try await a.read().index?.repos.first?.ready == true }
        let index = try #require(a.index(repo))
        let entries = index.queue.sync { index.entries }
        #expect(Set(entries.keys) == Set(Self.files.keys).union(Self.ignored.keys))
        // The classes git gives: tracked, untracked (none here), ignored (`.env`, node_modules, the log).
        #expect(entries["src/app.ts"]?.state == .tracked && entries[".env"]?.state == .ignored)
        #expect(entries["node_modules/left-pad/index.js"]?.state == .ignored && entries["debug.log"]?.state == .ignored)
        #expect(entries["scripts/run.sh"]?.kind == .file, "written without the exec bit")
        // Git's own blob id for the content, as `git hash-object` prints it.
        let id = try git(["hash-object", "src/app.ts"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(entries["src/app.ts"]?.gitID.hex == id)
        // Never written into the repository or its .git: only the fleet's own folder holds the index.
        #expect(try git(["status", "--porcelain=v1", "--ignored"], in: repo) == before)
        #expect(FileManager.default.fileExists(atPath: a.host.dir.appendingPathComponent("fleet/index/roots").path))
        // The peer holds the manifest, and every file's hash is in it.
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let theirs = try #require(b.manifest(of: try await a.hostID()))
        #expect(entries.values.allSatisfy { theirs.contains($0.hash) })
        #expect(theirs.contains(index.queue.sync { index.rootHash }))
        // A manifest names no file, only hashes: nothing of the content is in what B holds besides 16 bytes each.
        #expect(theirs.count == a.localManifest()?.count)
    }

    // MARK: An edit reaches the peer

    @Test func anEditReachesThePeersManifestThroughFSEventsWithoutARescan() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let index = try #require(a.index(repo))
        let rescans = index.queue.sync { index.rescans }
        let aID = try await a.hostID()

        // Five files edited or made and one removed, as a person's editor does it.
        let edits = ["src/app.ts": "export const app = 2\n", "src/lib/util.ts": "export const util = 22\n", "README.md": "# acme-web, edited\n",
                     "src/lib/new.ts": "export const fresh = 4\n", "notes/todo.md": "- ship it\n"]
        for (path, content) in edits {
            let file = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        try FileManager.default.removeItem(at: repo.appendingPathComponent("src/lib/more.ts"))
        let started = ContinuousClock.now
        try await eventually("A's index to follow", poll: .milliseconds(2)) {
            index.queue.sync { index.entries["notes/todo.md"]?.hash == self.hash("- ship it\n") && index.entries["src/lib/more.ts"] == nil && index.entries["src/app.ts"]?.hash == self.hash(edits["src/app.ts"]!) }
        }
        let local = ContinuousClock.now - started
        try await eventually("B's copy to follow", poll: .milliseconds(2)) {
            guard let theirs = b.manifest(of: aID) else { return false }
            return theirs.contains(self.hash("- ship it\n")) && !theirs.contains(self.hash("export const more = 3\n")) && !theirs.contains(self.hash("export const app = 1\n"))
        }
        let peer = ContinuousClock.now - started
        print("MEASURE 4b: 5 files edited and 1 removed, warm: local index reflects in \(local), the peer's manifest in \(peer)")
        // Through events, not a rescan; and the copy is exactly the sender's.
        #expect(index.queue.sync { index.rescans == rescans || index.lostEvents > 0 }, "no rescan unless the kernel said it lost events")
        try await eventually("B's copy to settle on A's manifest") { try await b.peerHolds(b, of: a) }
        let theirs = try #require(b.manifest(of: aID))
        for content in edits.values { #expect(theirs.contains(hash(content))) }
        // A touch with no change of content moves nothing: the digest stays.
        let digest = theirs.digest
        try Data("# acme-web, edited\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try await eventually("the touch to be seen") { index.queue.sync { index.entries["README.md"] != nil } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(b.manifest(of: aID)?.digest == digest)
    }

    @Test func aGitCommitOrAddReclassifiesFilesWithoutReadingThemAgain() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("A's index to be ready") { try await a.read().index?.repos.first?.ready == true }
        let index = try #require(a.index(repo))
        try Data("export const wip = 1\n".utf8).write(to: repo.appendingPathComponent("src/wip.ts"))
        // `settle()` asks the system for the events it holds: how long it takes to hand them over is not what is tested.
        try await eventually("the new file to be untracked") { index.settle(); return index.queue.sync { index.entries["src/wip.ts"]?.state == .untracked } }
        try git(["add", "src/wip.ts"], in: repo)
        try await eventually("git add to make it tracked") { index.settle(); return index.queue.sync { index.entries["src/wip.ts"]?.state == .tracked } }
        let rescans = index.queue.sync { index.rescans }
        try git(["rm", "-q", "--cached", "src/wip.ts"], in: repo)
        try await eventually("git rm --cached to untrack it") { index.settle(); return index.queue.sync { index.entries["src/wip.ts"]?.state == .untracked } }
        #expect(index.queue.sync { index.rescans == rescans || index.lostEvents > 0 })
    }

    // MARK: Drift

    @Test func aDroppedEventIsRepairedByTheSpotCheckAndReachesThePeer() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let index = try #require(a.index(repo))
        let stream = try #require(index.queue.sync { index.eventStream })
        let aID = try await a.hostID()
        // The stream loses what it is told: an edit and a new file make events nobody acts on.
        stream.isDropping = true
        try Data("export const app = 'lost'\n".utf8).write(to: repo.appendingPathComponent("src/app.ts"))
        try Data("export const quiet = true\n".utf8).write(to: repo.appendingPathComponent("src/quiet.ts"))
        try await eventually("the lost events to arrive and be dropped") { stream.droppedEvents >= 2 }
        // Every event the system holds for the folder (a directory's own change comes after its files') is dropped too, or one that
        // arrives after the stream is listening again would bring the index up to date and leave the check nothing to find.
        stream.flush()
        index.queue.sync {}
        #expect(index.queue.sync { index.entries["src/quiet.ts"] } == nil, "the index is stale")
        #expect(b.manifest(of: aID)?.contains(hash("export const app = 'lost'\n")) == false)
        // The check finds it, rescans, and the delta goes to B like any other.
        stream.isDropping = false
        let found = index.queue.sync { index.verify(sample: 1_000) }
        #expect(found)
        #expect(index.queue.sync { index.entries["src/quiet.ts"] } != nil)
        try await eventually("B to hold what the index missed") {
            b.manifest(of: aID)?.contains(self.hash("export const app = 'lost'\n")) == true && b.manifest(of: aID)?.contains(self.hash("export const quiet = true\n")) == true
        }
        try await eventually("B's copy to be A's") { try await b.peerHolds(b, of: a) }
        // Clean afterwards.
        #expect(!index.queue.sync { index.verify(sample: 1_000) })
    }

    @Test func aCopyThatNoLongerMatchesIsResentWholeAndTheSendersIndexIsCheckedAgain() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let aID = try await a.hostID()
        let head = try #require(b.server.queue.sync { b.server.fleet?.index.peerHead(of: aID, repo: Self.origin) })
        // Something replaces B's copy with another set under A's own generation and step: what a lost or garbled batch leaves.
        let wrong = FleetManifest((0..<40).map { hash("garbage \($0)").prefix })
        let asA = try await b.connectAsPeer(a)
        defer { asA.disconnect() }
        let ack = try await asA.fleetRepoManifest(FleetRepoManifestUpdate(repo: Self.origin, kind: .full, generation: head.generation, seq: head.seq,
                                                                         added: FleetHashPrefix.pack(wrong.prefixes), digest: wrong.digest))
        #expect(!ack.resend)
        #expect(b.manifest(of: aID) == wrong)
        // A's next step is a delta on top of a copy that can't produce its digest: B refuses it, and A sends the whole set.
        let index = try #require(a.index(repo))
        let rescans = index.queue.sync { index.rescans }
        try Data("export const app = 'next'\n".utf8).write(to: repo.appendingPathComponent("src/app.ts"))
        try await eventually("B's copy to be A's again") { try await b.peerHolds(b, of: a) }
        #expect(b.manifest(of: aID)?.contains(hash("export const app = 'next'\n")) == true)
        // A looked at its own index when the copy was refused (a sample of it against the disk): it found nothing wrong, so no rescan.
        #expect(index.queue.sync { index.rescans == rescans || index.lostEvents > 0 })
    }

    // MARK: Restart

    @Test func aRestartReplaysFromTheSavedEventIdAndFindsAChangeMadeWhileTheHostWasDown() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { b.stop() }
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let aID = try await a.hostID()
        let (dir, port) = (a.host.dir, a.port)
        let held = try #require(a.localManifest()).count
        a.stop(keepFiles: true)
        try await eventually("B to see A go") { try await b.read().peers.first?.link != .connected }

        // While the host is down: an edit, a new file, a removal.
        try Data("export const app = 'while down'\n".utf8).write(to: repo.appendingPathComponent("src/app.ts"))
        try Data("down\n".utf8).write(to: repo.appendingPathComponent("src/arrived-while-down.ts"))
        try FileManager.default.removeItem(at: repo.appendingPathComponent("scripts/run.sh"))

        let back = try await Mac("MacBook Pro", dir: dir, port: port)
        defer { back.stop() }
        try await eventually("the restarted index to hold the change") {
            guard let index = back.index(repo) else { return false }
            index.settle()
            return index.queue.sync { index.entries["src/arrived-while-down.ts"] != nil && index.entries["scripts/run.sh"] == nil && index.entries["src/app.ts"]?.hash == self.hash("export const app = 'while down'\n") }
        }
        // From the saved index and the journal of events, not a walk of the tree.
        let index = try #require(back.index(repo))
        #expect(index.queue.sync { index.loadedFromDisk }, "the index came from disk")
        // (A machine busy enough to overflow the kernel's event buffer is told so, and walks the tree: that is the design, not a failure.)
        #expect(index.queue.sync { index.rescans == 0 || index.lostEvents > 0 }, "and replayed events instead of walking the tree")
        try await back.waitForLink(to: b)
        try await eventually("B to hold what changed while the host was down") {
            guard let theirs = b.manifest(of: aID) else { return false }
            return theirs.contains(self.hash("down\n")) && !theirs.contains(self.hash("#!/bin/sh\necho hi\n")) && theirs.contains(self.hash("export const app = 'while down'\n"))
        }
        try await eventually("B's copy to be the restarted A's manifest") { try await b.peerHolds(b, of: back) }
        #expect(held > 0)
    }

    @Test func aReceiversCopySurvivesItsOwnRestartAndFindsTheSendersHeadStillGood() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop() }
        try await eventually("B to hold A's manifest") { try await b.peerHolds(b, of: a) }
        let aID = try await a.hostID()
        let (dir, port) = (b.host.dir, b.port)
        // No wait for the copy to reach the disk on its own (a save follows a change by a second): a host that stops leaves what it
        // holds on disk, a save already under way included, and that is what the restart below is built on.
        b.stop(keepFiles: true)
        // What the copy on disk is, as the host stopped.
        let saved = FleetPeerManifests.load(from: dir.appendingPathComponent("fleet/index/peers", isDirectory: true))
        let digest = try #require(saved.manifest(of: aID, repo: Self.origin)).digest
        let back = try await Mac("Mac mini", dir: dir, port: port)
        defer { back.stop() }
        // Known before any link is up.
        #expect(back.manifest(of: aID)?.digest == digest)
        try await a.waitForLink(to: back)
        let head = try #require(back.server.queue.sync { back.server.fleet?.index.peerHead(of: aID, repo: Self.origin) })
        try await eventually("A's head to be taken as current") { try await back.peerHolds(back, of: a) }
        #expect(back.server.queue.sync { back.server.fleet?.index.peerHead(of: aID, repo: Self.origin) }?.generation == head.generation)
    }

    // MARK: Who may send a manifest

    static let step = FleetRepoManifestUpdate(repo: origin, kind: .head, generation: 1, seq: 0, digest: .empty)

    /// The shared token is a client and a device has its own token: a manifest from either is refused, and a device is not
    /// even offered `fleet.snapshot.v1` (the shared token is, like every fleet capability, so an old client can be enrolled). Fleet is on,
    /// so it is the kind of connection that decides, not the switch.
    @Test func aClientOnTheSharedTokenOrADeviceIsNeitherOfferedNorAcceptedManifests() async throws {
        let host = try await FleetPairingTests.Mac("Mac mini")
        defer { host.stop() }
        let shared = RemoteHostClient()
        _ = try await shared.connect(host: "127.0.0.1", port: host.port, token: host.sharedToken, clientName: "iPhone")
        defer { shared.disconnect() }
        do { _ = try await shared.fleetRepoManifest(Self.step); Issue.record("the shared token sent a manifest") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }

        let phone = FleetDevicesIntegrationTests.Device()
        defer { phone.stop() }
        _ = try await phone.pair(with: host, code: try #require(try await host.local.fleetAction(.startDeviceCode).deviceCode).code)
        let client = try await phone.connect(to: host)
        #expect(!client.capabilities.contains(RemoteProtocol.fleetSnapshotCapability))
        do { _ = try await client.fleetRepoManifest(Self.step); Issue.record("a device sent a manifest") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
    }

    @Test func aMacInTheFleetMaySendAndAMalformedStepIsRefused() async throws {
        let repo = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (a, b, _) = try await Self.pair(repo: repo)
        defer { a.stop(); b.stop() }
        let asA = try await b.connectAsPeer(a)
        defer { asA.disconnect() }
        let ack = try await asA.fleetRepoManifest(Self.step)
        #expect(ack.resend, "B holds nothing under that name: send it all")
        do { _ = try await asA.fleetRepoManifest(FleetRepoManifestUpdate(repo: "", kind: .head, generation: 1, seq: 0, digest: .empty)); Issue.record("an empty repo name was accepted") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetSnapshotProtocol.Code.invalid) }
    }
}

/// What the index costs on a repository of about 20,000 files (a made up one: source files, and a `node_modules` that git ignores):
/// the first scan, an edit reaching the index and a peer's manifest, and what it takes on disk. The numbers are printed for the PR; the
/// bounds are loose, because the machine decides the rest (`.timingSensitive`, so CI skips it).
@Suite("Fleet snapshot index cost", .integrationTimeLimit, .timingSensitive)
struct FleetSnapshotIndexCostTests {
    @Test func aTwentyThousandFileRepositoryIndexesInTheBackgroundAndAnEditIsFastOnceWarm() async throws {
        var files: [String: String] = [".gitignore": "node_modules/\n"]
        for directory in 0..<300 { for file in 0..<40 { files["src/pkg-\(directory)/file-\(file).ts"] = "export const v\(directory)_\(file) = \(directory * file)\n// made up source, \(file)\n" } }
        let tracked = files.count
        let repo = try FleetSnapshotIndexTests.checkout(files: files, ignored: [:])
        defer { try? FileManager.default.removeItem(at: repo) }
        for package in 0..<400 {
            for file in 0..<20 {
                let url = repo.appendingPathComponent("node_modules/dep-\(package)/lib/part-\(file).js")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("module.exports = \(package + file)\n".utf8).write(to: url)
            }
        }
        let total = tracked + 400 * 20
        let (a, b, _) = try await FleetSnapshotIndexTests.pair(repo: repo)
        defer { a.stop(); b.stop() }
        try await eventually("A's first scan", timeout: .seconds(110), poll: .milliseconds(50)) { try await a.read().index?.repos.first?.ready == true }
        let index = try #require(a.index(repo))
        let (count, first, disk) = index.queue.sync { (index.entries.count, index.firstScan, index.bytesOnDisk) }
        #expect(count == total)
        let aID = try await a.hostID()
        try await eventually("B to hold the whole manifest", timeout: .seconds(60)) { try await b.peerHolds(b, of: a) }
        let peerFolder = b.host.dir.appendingPathComponent("fleet/index/peers/\(aID.uuidString)")
        try await eventually("B to have saved its copy") { FileManager.default.fileExists(atPath: peerFolder.path) }
        try await Task.sleep(for: .seconds(2))
        let peerFiles = try FileManager.default.contentsOfDirectory(atPath: peerFolder.path)
        var peerBytes = 0
        for name in peerFiles { peerBytes += (try? FileManager.default.attributesOfItem(atPath: b.host.dir.appendingPathComponent("fleet/index/peers/\(aID.uuidString)/\(name)").path)[.size] as? Int) ?? 0 }
        print("MEASURE 4b: \(count) files cold: first scan \(first.map { "\($0)" } ?? "?"); index on disk \(disk / 1024) KiB; the peer's manifest copy on disk \(peerBytes / 1024) KiB")

        let aEdits = (0..<5).map { "src/pkg-\($0)/file-\($0).ts" }
        let started = ContinuousClock.now
        for (offset, path) in aEdits.enumerated() { try Data("export const edited = \(offset)\n".utf8).write(to: repo.appendingPathComponent(path)) }
        let last = FleetHash(of: Data("export const edited = 4\n".utf8))
        try await eventually("A's index to reflect 5 edits", poll: .milliseconds(2)) { index.queue.sync { index.entries[aEdits[4]]?.hash == last } }
        let local = ContinuousClock.now - started
        try await eventually("B's manifest to reflect them", poll: .milliseconds(2)) { b.manifest(of: aID)?.contains(last) == true }
        let peer = ContinuousClock.now - started
        print("MEASURE 4b: \(count) files warm: 5 files edited, local index in \(local), the peer's manifest in \(peer)")
        #expect(local < .seconds(5) && peer < .seconds(5))
    }
}
