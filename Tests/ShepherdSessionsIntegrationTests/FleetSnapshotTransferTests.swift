import CryptoKit
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// A dispatch that carries the checkout it was sent from (slice 4c), between two real scratch hosts that share an origin: an unpushed
/// commit, an edit, an untracked file, an ignored `.env` and a `node_modules` arrive in the worktree the other Mac builds, byte for
/// byte, and the thread there doesn't start until the sender's digest has been checked.
@Suite("Fleet snapshot transfer", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct FleetSnapshotTransferTests {
    typealias Mac = FleetDispatchTests.Mac
    static let ignores = ".env\nnode_modules/\n*.log\n.build/\nsecrets.local\n"

    // MARK: Fixtures

    /// Two paired Macs whose origin ignores `.env`, `node_modules` and friends.
    static func pair(sendWork: Bool = true, extra: [String: String] = [:]) async throws -> (a: Mac, b: Mac, origin: FleetDispatchTests.Origin) {
        try await FleetDispatchTests.pair(sendWork: sendWork, originExtra: [".gitignore": ignores, "src/app.ts": "export const app = 1\n", "bin/run.sh": "#!/bin/sh\necho run\n"].merging(extra) { $1 })
    }

    /// The dispatch engine of a Mac, read on its server queue.
    static func engine<T>(_ mac: Mac, _ body: (FleetDispatch) -> T) -> T? {
        mac.server.queue.sync { mac.server.fleet.map { body($0.dispatch) } }
    }

    static func write(_ text: String, to path: String, in folder: URL, executable: Bool = false) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    static func writeBinary(_ count: Int, to path: String, in folder: URL, seed: UInt8 = 7) throws {
        var bytes = [UInt8](repeating: 0, count: count)
        var state: UInt64 = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        for index in 0..<count { state = state &* 6364136223846793005 &+ 1442695040888963407; bytes[index] = UInt8(truncatingIfNeeded: state >> 33) }
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    /// A `node_modules` of made-up packages: files, an executable, a link, a binary.
    static func nodeModules(in folder: URL, packages: Int = 3) throws {
        for index in 0..<packages {
            try write("module.exports = \(index)\n", to: "node_modules/pkg\(index)/index.js", in: folder)
            try write("{\"name\":\"pkg\(index)\"}\n", to: "node_modules/pkg\(index)/package.json", in: folder)
        }
        try write("#!/bin/sh\necho tool\n", to: "node_modules/pkg0/bin/tool.sh", in: folder, executable: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("node_modules/.bin/tool").path, withDestinationPath: "../pkg0/bin/tool.sh")
        try writeBinary(40_000, to: "node_modules/pkg1/native.bin", in: folder, seed: 3)
    }

    /// What a folder holds, by relative path: kind, content hash or link target, executable bit. `.git` is left out.
    struct Tree: Equatable {
        var entries: [String: String] = [:]
    }

    static func tree(of folder: URL, skipping skip: Set<String> = []) throws -> Tree {
        var tree = Tree()
        let manager = FileManager.default
        let root = folder.resolvingSymlinksInPath().path
        guard let walker = manager.enumerator(atPath: root) else { return tree }
        for case let relative as String in walker {
            if relative == ".git" || relative.hasPrefix(".git/") { if relative == ".git" { walker.skipDescendants() }; continue }
            if skip.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
            let path = root + "/" + relative
            let attributes = try manager.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink: tree.entries[relative] = "link:" + (try manager.destinationOfSymbolicLink(atPath: path))
            case .typeDirectory: tree.entries[relative] = "dir"
            default:
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                tree.entries[relative] = "file:\(mode & 0o100 != 0 ? "x" : "-"):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return tree
    }

    /// Sends one dispatch from `a`'s thread to the Mac mini and returns when the thread is running there.
    static func send(from a: Mac, to b: Mac, key: String = "snap", timeout: Duration = .seconds(60)) async throws -> (parent: FleetDispatchTests.Parent, thread: Agent) {
        let parent = try await a.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch("Fix the flaky payment test.", key: key, title: "Fix flaky payment test", host: "Mac mini"))
        try await FleetDispatchTests.wait("the Mac mini to run the dispatched thread", timeout: timeout) { !b.dispatched.isEmpty }
        return (parent, try #require(b.dispatched.first))
    }

    static func porcelain(_ folder: URL) throws -> [String] {
        try git(["status", "--porcelain", "--untracked-files=all"], in: folder).split(separator: "\n").map(String.init).sorted()
    }

    // MARK: Byte for byte

    @Test func aCheckoutWithAnUnpushedCommitEditsNewFilesAndIgnoredFilesArrivesByteForByteWithItsDigest() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // An unpushed commit, a tracked edit, a deletion, an untracked file, an empty file, a binary, an ignored .env and a node_modules.
        try Self.write("# The guide\n", to: "docs/guide.md", in: a.folder)
        try git(["add", "docs/guide.md"], in: a.folder)
        try git(["commit", "-qm", "guide"], in: a.folder)
        try Self.write("# acme-web\nedited after the commit\n", to: "README.md", in: a.folder)
        try FileManager.default.removeItem(at: a.folder.appendingPathComponent("apps/web/index.js"))
        try Self.write("chmod only\n", to: "bin/run.sh", in: a.folder, executable: true)
        try Self.write("take notes\n", to: "NOTES.md", in: a.folder)
        try Self.write("", to: "empty.txt", in: a.folder)
        try Self.writeBinary(300_000, to: "assets/logo.bin", in: a.folder)
        try Self.write("API_KEY=made-up-value\n", to: ".env", in: a.folder)
        try Self.nodeModules(in: a.folder)
        let expected = try Self.tree(of: a.folder)

        let (_, thread) = try await Self.send(from: a, to: b)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try Self.tree(of: worktree) == expected, "the worktree is the checkout, byte for byte")
        // Git agrees: the same commit, the same edits, the same new files, nothing else.
        #expect(try Self.head(worktree) == Self.head(a.folder))
        #expect(try Self.porcelain(worktree) == Self.porcelain(a.folder))
        #expect(try git(["status", "--porcelain", "--ignored", "--untracked-files=all"], in: worktree).contains("!! .env"))
        // The unpushed commit came as objects and one ref, nothing else; the user's checkout is as it was.
        let refs = try git(["for-each-ref", "--format=%(refname)", "refs/fleet"], in: b.folder).split(separator: "\n")
        #expect(refs.count == 1)
        #expect(try Self.porcelain(b.folder).isEmpty)
        #expect(try git(["worktree", "list", "--porcelain"], in: b.folder).components(separatedBy: "worktree ").count == 3)
        // The records: the receiver measured its file part after the digest, the sender saw the sizes.
        try await FleetDispatchTests.wait("the receiver's record to move past preparing") { b.taken().first?.state != .preparing }
        let taken = try #require(b.taken().first)
        #expect(taken.fileMillis != nil, "fileMillis: \(String(describing: taken.fileMillis))")
        #expect([.running, .delivering, .done].contains(taken.state), "state: \(taken.state) \(String(describing: taken.failure))")
        #expect(taken.snapshotBytes != nil)
        #expect(a.sent().first?.failure == nil)
    }

    static func head(_ folder: URL) throws -> String { try FleetDispatchTests.head(folder) }

    // MARK: Failing safe

    @Test func aFlippedByteFailsWithSnapshotMismatchAndLeavesNoWorktreeAndNoAgent() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.write("take notes, then lose a bit of them\n", to: "NOTES.md", in: a.folder)
        _ = Self.engine(a) { $0.wire = { chunk in
            var chunk = chunk
            if chunk.offset == 0, !chunk.data.isEmpty { chunk.data[0] ^= 0xFF }
            return chunk
        } }
        let parent = try await a.parent()
        try parent.hello()
        _ = try await parent.dispatch("Fix it.", key: "flip", host: "Mac mini")
        try await FleetDispatchTests.wait("the dispatch to fail") { a.sent().first?.state == .failed }
        #expect(a.sent().first?.failure == FleetDispatchCode.snapshotMismatch)
        #expect(b.taken().first?.failure == FleetDispatchCode.snapshotMismatch)
        // Nothing started there, and nothing is left behind: no thread, no worktree, no branch, no half received content.
        #expect(b.dispatched.isEmpty && !b.server.state.agents.contains { $0.dispatchedFrom != nil })
        #expect(try git(["worktree", "list", "--porcelain"], in: b.folder).components(separatedBy: "worktree ").count == 2)
        #expect(try git(["branch", "--list", "fleet/*"], in: b.folder).isEmpty)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: b.host.dir.appendingPathComponent("fleet/snapshot-blobs").path)
        #expect(blobs.allSatisfy { !$0.hasSuffix(".part") } && blobs.isEmpty)
    }

    @Test func aSnapshotAboveTheCapSendsNothingAndOneAboveTheWarningSizeSendsAndSaysSo() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        try Self.writeBinary(50_000, to: "big/blob.bin", in: a.folder)
        try Self.write("small\n", to: "NOTES.md", in: a.folder)
        // Past the cap: refused before anything is sent, naming the biggest path.
        _ = Self.engine(a) { $0.caps = (warn: 1_000, refuse: 20_000) }
        guard case .error(_, FleetDispatchCode.snapshotTooLarge, let message) = try await parent.dispatch("Fix it.", key: "big", host: "Mac mini") else {
            Issue.record("a dispatch over the cap was not refused"); return
        }
        #expect(message.contains("big/blob.bin") || a.sent().first?.failureDetail?.contains("big/blob.bin") == true)
        #expect(a.sent().first?.failure == FleetDispatchCode.snapshotTooLarge && a.sent().first?.failureDetail?.contains("big/blob.bin:50000") == true)
        #expect(b.taken().isEmpty && b.dispatched.isEmpty, "the other Mac was never asked")
        // Above the warning size but under the cap: it goes, and the record says it was large.
        _ = Self.engine(a) { $0.caps = (warn: 1_000, refuse: 10_000_000) }
        _ = try await parent.dispatch("Fix it.", key: "warn", host: "Mac mini")
        try await FleetDispatchTests.wait("the Mac mini to run it") { b.dispatched.count == 1 }
        let sent = try #require(a.sent().first { $0.state != .failed })
        #expect(sent.sendWarning && (sent.snapshotBytes ?? 0) > 50_000)
    }

    @Test func aManifestThatClaimsMoreThanTheTargetHoldsIsRepairedByAskingForTheContentNotFailed() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let bID = try await b.hostID()
        let repo = FleetDispatchTests.repoKey
        let contents = "a file the other Mac does not have\n"
        try Self.write(contents, to: "src/claimed.ts", in: a.folder)
        // The sender's copy of the target's manifest is made to claim the content.
        let claimed = FleetHash(of: Data(contents.utf8)).prefix
        try await FleetDispatchTests.wait("the sender to hold the target's manifest") {
            a.server.queue.sync { a.server.fleet?.index.peerHead(of: bID, repo: repo) != nil }
        }
        let accepted = a.server.queue.sync { () -> Bool in
            guard let index = a.server.fleet?.index, let head = index.peerHead(of: bID, repo: repo), let held = index.manifest(of: bID, repo: repo) else { return false }
            var prefixes = Array(held.prefixes)
            prefixes.append(claimed)
            let update = FleetRepoManifestUpdate(repo: repo, kind: .full, generation: head.generation + 100, seq: 1, added: FleetHashPrefix.pack(prefixes),
                                                 digest: FleetManifest(prefixes).digest)
            return !index.received(update, from: bID).resend
        }
        try #require(accepted, "the sender holds the target's manifest")
        let (_, thread) = try await Self.send(from: a, to: b)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try String(contentsOf: worktree.appendingPathComponent("src/claimed.ts"), encoding: .utf8) == contents)
        #expect(a.sent().first?.failure == nil && b.taken().first?.failure == nil)
    }

    @Test func aLinkThatDropsMidTransferResumesWithoutSendingWhatAlreadyArrived() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        for index in 0..<6 { try Self.writeBinary(600_000, to: "assets/part\(index).bin", in: a.folder, seed: UInt8(index + 1)) }
        let first = Locked<[FleetHash: Int]>([:])
        let cut = Locked(false)
        _ = Self.engine(a) { $0.wire = { chunk in
            if chunk.offset == 0 { first.withValue { $0[chunk.hash, default: 0] += 1 } }
            // The third content's second chunk: the link goes away once.
            if first.current.count == 3, chunk.offset > 0, !cut.current {
                cut.withValue { $0 = true }
                throw RemoteHostClientError.rejected(code: "closed", message: "The link went away.")
            }
            return chunk
        } }
        let (_, thread) = try await Self.send(from: a, to: b, timeout: .seconds(90))
        #expect(cut.current, "the link was cut")
        // Each content started once, except the one the cut interrupted.
        let counts = first.current
        #expect(counts.count == 6 && counts.values.filter { $0 > 1 }.count <= 1 && counts.values.max() ?? 0 <= 2)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try Self.tree(of: worktree) == Self.tree(of: a.folder))
    }

    // MARK: What stays home

    @Test func pathBoundCachesAndASpacesExcludesStayHomeWhileIgnoredFilesTravel() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.write("API_KEY=made-up-value\n", to: ".env", in: a.folder)
        try Self.write("kept home\n", to: "secrets.local", in: a.folder)
        try Self.write("built\n", to: ".build/debug/product.o", in: a.folder)
        try Self.write("env\n", to: ".venv/pyvenv.cfg", in: a.folder)
        try Self.write("x\n", to: ".venv/lib/mod.py", in: a.folder)
        try Self.nodeModules(in: a.folder)
        // The space lists secrets.local to keep home; the index follows once the setting reaches the host.
        a.settings.withValue { $0.apply(.fleetSnapshotExcludes(spaceID: a.space.id.rawValue, excludes: FleetSnapshotExcludes(excluded: ["secrets.local"]))) }
        a.server.fleetHostSettingsChanged(a.settings.current)
        try await FleetDispatchTests.wait("the index to take the space's exclude") {
            a.server.queue.sync { a.server.fleet?.index.index(at: a.folder.path) }.map { index in index.queue.sync { index.exclusions.overrides.excluded } } == ["secrets.local"]
        }
        let (_, thread) = try await Self.send(from: a, to: b)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        let there = try Self.tree(of: worktree).entries
        #expect(there[".env"] != nil && there["node_modules/pkg0/index.js"] != nil, "ignored files and node_modules travel")
        #expect(there["secrets.local"] == nil, "a space's exclude stays home")
        #expect(there[".build"] == nil && there[".build/debug/product.o"] == nil, "a Swift build stays home")
        #expect(there[".venv"] == nil && there[".venv/lib/mod.py"] == nil, "a virtualenv stays home")
    }

    @Test func theUncommittedChangesSettingSetToLeaveThemBehindSendsTheCommitAlone() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        a.settings.withValue { $0.apply(.fleetUncommitted(.leaveBehind)) }
        a.server.fleetHostSettingsChanged(a.settings.current)
        try Self.write("take notes\n", to: "NOTES.md", in: a.folder)
        try Self.write("API_KEY=made-up-value\n", to: ".env", in: a.folder)
        let (_, thread) = try await Self.send(from: a, to: b)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("NOTES.md").path))
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path))
        #expect(try Self.head(worktree) == Self.head(a.folder))
        #expect(b.taken().first?.snapshotBytes == nil)
    }

    // MARK: The budget

    /// A file of `megabytes`, made of one block that differs from every other file's in its first bytes (so each has its own hash).
    static func writeLarge(_ megabytes: Int, to path: String, in folder: URL, seed: Int) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = Data(repeating: UInt8(truncatingIfNeeded: seed &* 31 &+ 7), count: 1 << 20)
        withUnsafeBytes(of: seed) { block.replaceSubrange(0..<8, with: $0) }
        for _ in 0..<megabytes { try handle.write(contentsOf: block) }
    }

    /// The warm fixture of the plan: about 2,000 tracked files, a `node_modules` both Macs hold (so a dispatch names it by hash), and the
    /// target's spare built. Five files then change on the sender: three tracked edits and two new ones.
    struct Warm {
        var a: Mac
        var b: Mac
        var edited: [String]
        var editedBytes: UInt64
        var nodeModulesBytes: UInt64
    }

    static func warm(nodeModulesMegabytes: Int = 0, tracked: Int = 2_000) async throws -> Warm {
        var extra: [String: String] = [:]
        for index in 0..<tracked { extra["src/gen/f\(index).ts"] = "export const v\(index) = \(index)\n" }
        let (a, b, _) = try await Self.pair(extra: extra)
        for folder in [a.folder, b.folder] {
            try Self.nodeModules(in: folder, packages: 60)
            for index in 0..<(nodeModulesMegabytes / 5) { try Self.writeLarge(5, to: "node_modules/big/native\(index).bin", in: folder, seed: index + 1) }
        }
        let bID = try await b.hostID()
        let repo = FleetDispatchTests.repoKey
        // The sender's index has the directory, and holds the target's manifest naming it; the target has its spare.
        let hash = try await { () -> FleetHash in
            var found: FleetHash?
            try await FleetDispatchTests.wait("the sender to index node_modules", timeout: .seconds(120)) {
                found = a.server.queue.sync { a.server.fleet?.index.index(at: a.folder.path) }.flatMap { index in index.queue.sync { index.hash(ofDirectory: "node_modules") } }
                return found != nil
            }
            return try #require(found)
        }()
        try await FleetDispatchTests.wait("the sender to hold a manifest of node_modules on the target", timeout: .seconds(120)) {
            a.server.queue.sync { a.server.fleet?.index.manifest(of: bID, repo: repo)?.contains(hash) } == true
        }
        let canonical = PiHome.canonical(b.folder.path)
        try await FleetDispatchTests.wait("the target's spare", timeout: .seconds(120)) { (Self.engine(b) { $0.spares.current(repo: canonical) } ?? nil) != nil }
        // Let the sender's index settle, so what it hashes for the dispatch is only what changes now.
        try await Task.sleep(for: .seconds(3))
        var sizes: UInt64 = 0
        let edited = ["src/gen/f1.ts", "src/gen/f2.ts", "README.md", "NOTES.md", "docs/plan.md"]
        for (index, path) in edited.enumerated() {
            let text = "changed \(index) in the working tree, with enough text to make it its own content\n"
            try Self.write(text, to: path, in: a.folder)
            sizes += UInt64(text.utf8.count)
        }
        let big = UInt64(nodeModulesMegabytes) * 1_048_576
        return Warm(a: a, b: b, edited: edited, editedBytes: sizes, nodeModulesBytes: big)
    }

    @Test func aWarmDispatchHashesWalksAndSendsOnlyTheFiveEditedFilesAndClonesEverythingElse() async throws {
        let fixture = try await Self.warm()
        let (a, b) = (fixture.a, fixture.b)
        defer { a.stop(); b.stop() }
        let index = try #require(a.server.queue.sync { a.server.fleet?.index.index(at: a.folder.path) })
        let hashedBefore = index.queue.sync { index.filesHashed }
        let pushed = Locked<[FleetBlobChunk]>([])
        _ = Self.engine(a) { $0.wire = { chunk in pushed.withValue { $0.append(FleetBlobChunk(hash: chunk.hash, size: chunk.size, offset: chunk.offset, data: Data())); $0.append(chunk) }; return chunk } }
        let (_, thread) = try await Self.send(from: a, to: b)

        // The sender read only what changed: the five files (never the thousands the index already held).
        let hashed = index.queue.sync { index.filesHashed } - hashedBefore
        #expect(hashed <= fixture.edited.count * 3, "the sender hashed \(hashed) files")
        // It sent those five contents and no other: their sizes, to the byte.
        let sent = pushed.current.filter { !$0.data.isEmpty }
        #expect(sent.count == fixture.edited.count && sent.reduce(UInt64(0)) { $0 + UInt64($1.data.count) } == fixture.editedBytes)
        // The target cloned every unchanged file and directory (the spare, node_modules, the five), wrote no other content, and ran no checkout.
        let id = try #require(a.sent().first?.id)
        let stats = try #require(Self.engine(b) { $0.applyStats[id] } ?? nil)
        #expect(stats.usedSpare && stats.copies == 0 && stats.filesWritten == 0 && stats.bytesWritten == 0)
        #expect(stats.clones == 2 + fixture.edited.count, "clones: \(stats.clones)")
        #expect(stats.heldLocally == 1 && stats.receivedFiles == fixture.edited.count)
        #expect(!stats.git.contains("checkout") && !stats.git.contains("read-tree") && !stats.git.contains("update-index"), "git ran: \(stats.git)")
        // And the result is the checkout.
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try Self.tree(of: worktree) == Self.tree(of: a.folder))
        #expect(try Self.porcelain(worktree) == Self.porcelain(a.folder))
        let timing = try #require(Self.engine(a) { $0.timings[id] } ?? nil)
        let millis = try #require(b.taken().first?.fileMillis)
        print("FLEET-MEASURE warm: sender \(timing.build) ms, transfer \(timing.transfer) ms, receiver \(millis) ms")
    }

    /// Set from the spike's measurements: the file part (create received to a worktree that passed its digest) of a warm dispatch with a 200 MB
    /// `node_modules` reference measured 150 to 190 ms in this debug test binary on a Mac whose load average was 160 to 350, so the budget is
    /// twice the median. The plan's 50 ms is for an idle Mac and a release build; this constant is only ever tightened.
    static let fileMillisBudget = 300

    @Test(.timingSensitive) func theFilePartOfAWarmDispatchOnTheTargetIsUnderItsBudget() async throws {
        let fixture = try await Self.warm(nodeModulesMegabytes: 200)
        let (a, b) = (fixture.a, fixture.b)
        defer { a.stop(); b.stop() }
        _ = try await Self.send(from: a, to: b)
        try await FleetDispatchTests.wait("the receiver's record to move past preparing") { b.taken().first?.state != .preparing }
        let millis = try #require(b.taken().first?.fileMillis)
        let id = try #require(a.sent().first?.id)
        print("FLEET-MEASURE warm 200 MB node_modules: receiver \(millis) ms; \(String(describing: Self.engine(b) { $0.applyStats[id]?.phases } ?? nil))")
        #expect(millis < Self.fileMillisBudget, "the file part took \(millis) ms")
    }
}

/// What a dispatch costs on bigger trees, printed for the PR's table (`SHEPHERD_FLEET_MEASURE=1`). Nothing here asserts a time.
@Suite("Fleet snapshot measurements", .integrationTimeLimit, .mainActorExclusive, .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_FLEET_MEASURE"] == "1", "set SHEPHERD_FLEET_MEASURE=1"))
@MainActor
struct FleetSnapshotMeasurementTests {
    /// The first dispatch of a 20,000 file repository to a Mac with no spare for it (origin's HEAD ref removed there, so its tracked files come from git's own checkout).
    @Test func aFirstDispatchOfATwentyThousandFileRepositoryToAMacWithNoSpare() async throws {
        var extra: [String: String] = [:]
        for index in 0..<20_000 { extra["src/gen/f\(index).ts"] = "export const v\(index) = \(index)\n" }
        let (a, b, _) = try await FleetSnapshotTransferTests.pair(extra: extra)
        defer { a.stop(); b.stop() }
        for mac in [a, b] {
            try await FleetDispatchTests.wait("the first index scan of \(mac.name)", timeout: .seconds(600)) {
                mac.server.queue.sync { mac.server.fleet?.index.index(at: mac.folder.path) }?.stateNow == .ready
            }
        }
        _ = try? git(["remote", "set-head", "origin", "--delete"], in: b.folder)
        for index in 0..<5 { try FleetSnapshotTransferTests.write("changed \(index)\n", to: "src/gen/f\(index).ts", in: a.folder) }
        let (_, _) = try await FleetSnapshotTransferTests.send(from: a, to: b, timeout: .seconds(600))
        try await FleetDispatchTests.wait("the record to move on") { b.taken().first?.state != .preparing }
        let id = try #require(a.sent().first?.id)
        let timing = try #require(FleetSnapshotTransferTests.engine(a) { $0.timings[id] } ?? nil)
        let stats = try #require(FleetSnapshotTransferTests.engine(b) { $0.applyStats[id] } ?? nil)
        print("FLEET-MEASURE first dispatch, 20k tracked files, no spare: sender \(timing.build) ms, transfer \(timing.transfer) ms, receiver \(b.taken().first?.fileMillis ?? -1) ms \(stats.phases) spare=\(stats.usedSpare)")
    }

    /// A `node_modules` of about 6,000 files and 200 MB that the target holds nothing of.
    @Test func aNodeModulesHeavyDispatchTheTargetHoldsNothingOf() async throws {
        let (a, b, _) = try await FleetSnapshotTransferTests.pair()
        defer { a.stop(); b.stop() }
        try FleetSnapshotTransferTests.nodeModules(in: a.folder, packages: 2_900)
        for index in 0..<40 { try FleetSnapshotTransferTests.writeLarge(5, to: "node_modules/big/native\(index).bin", in: a.folder, seed: index + 1) }
        try await Task.sleep(for: .seconds(5))
        let (_, _) = try await FleetSnapshotTransferTests.send(from: a, to: b, timeout: .seconds(900))
        try await FleetDispatchTests.wait("the record to move on") { b.taken().first?.state != .preparing }
        let id = try #require(a.sent().first?.id)
        let timing = try #require(FleetSnapshotTransferTests.engine(a) { $0.timings[id] } ?? nil)
        let stats = try #require(FleetSnapshotTransferTests.engine(b) { $0.applyStats[id] } ?? nil)
        print("FLEET-MEASURE node_modules heavy (~6,000 files, 200 MB, nothing held): sender \(timing.build) ms, transfer \(timing.transfer) ms, receiver \(b.taken().first?.fileMillis ?? -1) ms \(stats.phases)")
    }
}
