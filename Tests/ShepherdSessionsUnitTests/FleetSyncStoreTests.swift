import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The sync store: op logs per origin, who wins a unit, the vector diff that decides what a peer
/// is sent, blobs by hash, and history.
@Suite("Fleet sync store")
struct FleetSyncStoreTests {
    static let macA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let macB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let unit = "setting:host.defaultModel"

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        func tick(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }
    }

    static func store(_ dir: URL, mac: UUID, clock: Clock = Clock()) throws -> FleetStore {
        try FleetStore(directory: dir.appendingPathComponent("store-\(mac.uuidString.suffix(1))"), mac: mac, clock: { clock.now })
    }

    static func op(_ mac: UUID, _ seq: UInt64, wall: UInt64, unit: String = unit, value: String = "\"x\"", seed: Bool = false) -> FleetOp {
        FleetOp(mac: mac, seq: seq, hlc: FleetHLC(wallMs: wall), unit: unit, change: .value(value), seed: seed, macName: "Mac")
    }

    // MARK: Hybrid logical clock

    @Test func localOpsAreNumberedFromOneAndTheClockOnlyMovesForward() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = try Self.store(dir, mac: Self.macA, clock: clock)
        let first = try #require(store.appendLocal(unit: Self.unit, change: .value("1"), seed: false, name: "A"))
        let second = try #require(store.appendLocal(unit: Self.unit, change: .value("2"), seed: false, name: "A"))
        #expect((first.seq, second.seq) == (1, 2))
        #expect(second.hlc > first.hlc, "two writes in one millisecond still order")
        clock.now = Date(timeIntervalSince1970: 10)
        let skewed = try #require(store.appendLocal(unit: Self.unit, change: .value("3"), seed: false, name: "A"))
        #expect(skewed.hlc > second.hlc, "a wall clock set back doesn't reorder writes")
    }

    @Test func aReceivedOpMovesTheLocalClockPastIt() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        #expect(store.receive(Self.op(Self.macB, 1, wall: 9_000_000)) == .stored(won: true))
        let mine = try #require(store.appendLocal(unit: Self.unit, change: .value("\"mine\""), seed: false, name: "A"))
        #expect(mine.hlc > FleetHLC(wallMs: 9_000_000), "a write made after seeing another is later than it, even on a slow clock")
        #expect(store.winner(of: Self.unit)?.mac == Self.macA)
    }

    // MARK: Receiving

    @Test func opsOfOneOriginArriveInOrderWithNoGaps() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        #expect(store.receive(Self.op(Self.macB, 2, wall: 1)) == .gap, "the first one is missing")
        #expect(store.vector[Self.macB] == 0)
        #expect(store.receive(Self.op(Self.macB, 1, wall: 1)) == .stored(won: true))
        #expect(store.receive(Self.op(Self.macB, 1, wall: 1)) == .duplicate)
        #expect(store.receive(Self.op(Self.macB, 2, wall: 2)) == .stored(won: true))
        #expect(store.vector[Self.macB] == 2)
        var bad = Self.op(Self.macB, 3, wall: 3)
        bad.unit = "../escape"
        #expect(store.receive(bad) == .invalid)
        #expect(store.vector[Self.macB] == 2, "a refused op changes nothing")
    }

    // MARK: Who wins, and the loser

    @Test func theLaterWriteWinsAndTheEarlierGoesToHistoryEitherWayItArrives() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let early = Self.op(Self.macA, 1, wall: 1_000, value: "\"early\""), late = Self.op(Self.macB, 1, wall: 2_000, value: "\"late\"")
        for order in [[early, late], [late, early]] {
            let store = try Self.store(dir.appendingPathComponent(UUID().uuidString), mac: UUID())
            for op in order { _ = store.receive(op) }
            #expect(store.winner(of: Self.unit)?.change == .value("\"late\""), "both orders agree")
            let history = store.history(of: Self.unit)
            #expect(history.map(\.change) == [.value("\"early\"")], "the loser stays recoverable")
            #expect(history.first?.reason == (order[0] == early ? "superseded" : "lost"))
        }
    }

    @Test func aWinnerIsDecidedAgainAfterARestart() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        _ = store.receive(Self.op(Self.macB, 1, wall: 5_000, value: "\"b\""))
        let mine = try #require(store.appendLocal(unit: Self.unit, change: .value("\"a\""), seed: false, name: "A"))
        let again = try Self.store(dir, mac: Self.macA)
        #expect(again.vector == store.vector)
        #expect(again.winner(of: Self.unit) == mine)
        let next = try #require(again.appendLocal(unit: Self.unit, change: .value("\"a2\""), seed: false, name: "A"))
        #expect(next.seq == 2 && next.hlc > mine.hlc, "the log and the clock continue")
    }

    @Test func aTornLastLineFromACrashIsDroppedAndTheLogContinues() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        store.appendLocal(unit: Self.unit, change: .value("1"), seed: false, name: "A")
        let log = store.directory.appendingPathComponent("ops-\(Self.macA.uuidString).ndjson")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"mac\":".utf8))
        try handle.close()
        let again = try Self.store(dir, mac: Self.macA)
        #expect(again.vector[Self.macA] == 1)
        #expect(again.appendLocal(unit: Self.unit, change: .value("2"), seed: false, name: "A")?.seq == 2)
        #expect(try Self.store(dir, mac: Self.macA).vector[Self.macA] == 2, "the new op is not glued to the torn bytes")
    }

    // MARK: What a peer lacks

    @Test func opsAfterAVectorAreExactlyTheOnesItLacksInOrderPerOrigin() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        for seq in 1...3 { _ = store.receive(Self.op(Self.macB, UInt64(seq), wall: UInt64(seq), unit: "setting:host.u\(seq)")) }
        store.appendLocal(unit: "setting:host.mine", change: .value("1"), seed: false, name: "A")
        #expect(store.ops(after: FleetVersionVector()).map(\.seq).sorted() == [1, 1, 2, 3])
        let partial = store.ops(after: FleetVersionVector([Self.macB: 2]))
        #expect(partial.map { "\($0.mac == Self.macB ? "B" : "A")\($0.seq)" }.sorted() == ["A1", "B3"])
        #expect(store.ops(after: store.vector).isEmpty)
        #expect(store.ops(after: FleetVersionVector(), limit: 2).count == 2, "a batch is cut at its limit")
    }

    // MARK: Blobs

    @Test func aBlobIsStoredUnderItsHashAndOnlyIfTheBytesMatch() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        let data = Data("# How I work\n".utf8)
        let hash = FleetSyncProtocol.hash(data)
        #expect(!store.hasBlob(hash))
        #expect(!store.putBlob(Data("other".utf8), named: hash), "bytes that aren't the blob are refused")
        #expect(store.putBlob(data, named: hash) && store.blob(hash) == data)
        #expect(store.blobChunk(hash, offset: 2, length: 4)?.data == data.subdata(in: 2..<6))
        #expect(store.blobChunk(hash, offset: 2, length: 4)?.total == data.count)
        #expect(store.blobChunk(hash, offset: data.count + 1, length: 4) == nil)
        #expect(store.blob("../../etc/passwd") == nil, "a hash is only ever hex")
    }

    @Test func aWinnerWhoseBlobIsntHereIsMissingUntilItArrives() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        let data = Data("instructions".utf8), hash = FleetSyncProtocol.hash(data)
        var op = Self.op(Self.macB, 1, wall: 1, unit: "instruction:AGENTS.md")
        op.change = .blob(hash: hash, size: data.count)
        _ = store.receive(op)
        #expect(store.missingBlobs().map(\.hash) == [hash])
        _ = store.putBlob(data, named: hash)
        #expect(store.missingBlobs().isEmpty)
    }

    // MARK: History and files

    @Test func historyKeepsTheNewestHundredVersionsAndDropsTheBlobOfOneItLetsGo() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = try Self.store(dir, mac: Self.macA, clock: clock)
        let unit = "instruction:AGENTS.md"
        var hashes: [String] = []
        for index in 0..<(FleetStore.historyLimit + 3) {
            let data = Data("version \(index)".utf8)
            let hash = try #require(store.putBlob(data))
            hashes.append(hash)
            store.appendLocal(unit: unit, change: .blob(hash: hash, size: data.count), seed: false, name: "A")
            clock.tick()
        }
        let history = store.history(of: unit)
        #expect(history.count == FleetStore.historyLimit, "the last write is the winner, not history")
        #expect(!store.hasBlob(hashes[0]), "an old version's blob goes with its history entry")
        #expect(store.hasBlob(hashes[hashes.count - 1]) && store.hasBlob(hashes[hashes.count - 2]))
    }

    @Test func historyOlderThanAMonthIsDropped() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = try Self.store(dir, mac: Self.macA, clock: clock)
        store.appendLocal(unit: Self.unit, change: .value("1"), seed: false, name: "A")
        store.appendLocal(unit: Self.unit, change: .value("2"), seed: false, name: "A")
        #expect(store.history(of: Self.unit).count == 1)
        clock.tick(FleetStore.historyLifetime + 10)
        store.appendLocal(unit: Self.unit, change: .value("3"), seed: false, name: "A")
        #expect(store.history(of: Self.unit).map(\.change) == [.value("2")], "the month old version went when a new one was set aside")
    }

    @Test func everyFileTheStoreWritesIsPrivate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Self.store(dir, mac: Self.macA)
        let hash = try #require(store.putBlob(Data("secret".utf8)))
        store.appendLocal(unit: Self.unit, change: .value("1"), seed: false, name: "A")
        store.appendLocal(unit: Self.unit, change: .value("2"), seed: false, name: "A")
        func mode(_ url: URL) -> mode_t { var info = stat(); _ = stat(url.path, &info); return info.st_mode & 0o777 }
        #expect(mode(store.directory) == 0o700)
        #expect(mode(store.directory.appendingPathComponent("ops-\(Self.macA.uuidString).ndjson")) == 0o600)
        #expect(mode(store.directory.appendingPathComponent("blobs/\(hash)")) == 0o600)
        let folder = store.directory.appendingPathComponent("history/setting%3Ahost.defaultModel")
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(entries.count == 1 && mode(folder.appendingPathComponent(entries[0])) == 0o600)
    }
}
