import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// What the materializer does between a Mac's real state and the store: seeds, local edits as ops,
/// store winners written back, and never echoing its own writes.
@Suite("Fleet materializer")
struct FleetMaterializerTests {
    /// A Mac's state in memory: file-like units (blobs) and setting-like ones (inline).
    final class Source: FleetUnitSource, @unchecked Sendable {
        var values: [String: Data]
        let units: [String]
        let blobUnits: Set<String>
        var seedable: (String, Data) -> Bool = { _, value in !value.isEmpty }
        var failing: Error?
        var written: [(unit: String, value: String?, origin: String)] = []
        var asynchronous = false
        var ready = true

        init(units: [String], blobUnits: Set<String> = [], values: [String: String] = [:]) {
            self.units = units
            self.blobUnits = blobUnits
            self.values = values.mapValues { Data($0.utf8) }
        }

        var isReady: Bool { ready }
        var writesAsynchronously: Bool { asynchronous }
        func storesBlob(_ unit: String) -> Bool { blobUnits.contains(unit) }
        func read() -> [String: Data] { values }
        func isSeedable(_ unit: String, _ value: Data) -> Bool { seedable(unit, value) }
        func write(_ unit: String, _ value: Data?, origin: String) throws {
            if let failing { throw failing }
            written.append((unit, value.map { String(decoding: $0, as: UTF8.self) }, origin))
            if !asynchronous { values[unit] = value }
        }
    }

    static let file = "instruction:AGENTS.md"
    static let setting = "setting:host.defaultModel"
    static let macA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let macB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    struct Mac {
        let store: FleetStore
        let materializer: FleetMaterializer
        let source: Source
        let clock: Clock

        init(_ id: UUID, dir: URL, values: [String: String] = [:]) throws {
            let clock = Clock()
            let folder = dir.appendingPathComponent(id.uuidString.suffix(1) + "-store")
            store = try FleetStore(directory: folder, mac: id, clock: { clock.now })
            materializer = FleetMaterializer(store: store, directory: folder, clock: { clock.now })
            source = Source(units: [FleetMaterializerTests.file, FleetMaterializerTests.setting], blobUnits: [FleetMaterializerTests.file], values: values)
            materializer.add(source)
            self.clock = clock
        }

        func text(_ unit: String) -> String? { source.values[unit].map { String(decoding: $0, as: UTF8.self) } }
        @discardableResult func scan() -> [FleetOp] { materializer.scan(name: "Mac \(store.mac.uuidString.suffix(1))") }
        func apply() -> (notices: [FleetMaterializer.Notice], failed: Bool) { materializer.materialize(name: "Mac \(store.mac.uuidString.suffix(1))") }

        /// Everything `other` lacks, as a peer would send it.
        func send(to other: Mac) {
            for op in store.ops(after: other.store.vector) {
                _ = other.store.receive(op)
                if let hash = op.blobHash, let data = store.blob(hash) { _ = other.store.putBlob(data, named: hash) }
            }
        }
    }

    // MARK: Seeds

    @Test func theFirstScanSeedsOnlyWhatIsWorthSharing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try Mac(Self.macA, dir: dir, values: [Self.file: "# How I work", Self.setting: "null"])
        mac.source.seedable = { unit, value in unit == Self.file && !value.isEmpty }
        let ops = mac.scan()
        #expect(ops.map(\.unit) == [Self.file] && ops.first?.seed == true, "a default value doesn't outvote another Mac's choice")
        #expect(mac.store.blob(try #require(ops.first?.blobHash)) == Data("# How I work".utf8))
        #expect(mac.scan().isEmpty, "looking again changes nothing")
    }

    @Test func theFirstMacToSyncIsTheReferenceAndTheOthersCopyIsSetAsideNotLost() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = try Mac(Self.macA, dir: dir, values: [Self.file: "reference text"])
        let joiner = try Mac(Self.macB, dir: dir, values: [Self.file: "joiner's own text"])
        reference.scan()
        reference.clock.now = reference.clock.now.addingTimeInterval(60)
        joiner.clock.now = joiner.clock.now.addingTimeInterval(120)
        joiner.scan()

        reference.send(to: joiner)
        let result = joiner.apply()
        #expect(joiner.text(Self.file) == "reference text")
        #expect(result.notices == [FleetMaterializer.Notice(unit: Self.file, from: "Mac A")], "the sync line says what it replaced")
        #expect(joiner.source.written.first?.origin == "Mac A", "the save is attributed to the Mac the text came from")
        let kept = joiner.store.history(of: Self.file)
        #expect(kept.count == 1 && kept[0].macName == "Mac B", "the joiner's own copy is in history")
        if case .blob(let hash, _) = kept[0].change { #expect(joiner.store.blob(hash) == Data("joiner's own text".utf8)) } else { Issue.record("not a blob") }

        joiner.send(to: reference)
        #expect(reference.apply().notices.isEmpty && reference.text(Self.file) == "reference text", "the reference keeps its text")
    }

    @Test func aMacWithNothingToShareJustTakesTheFleetsCopyAndSaysNothing() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = try Mac(Self.macA, dir: dir, values: [Self.file: "text"])
        let blank = try Mac(Self.macB, dir: dir, values: [Self.file: ""])
        reference.scan()
        blank.scan()
        reference.send(to: blank)
        #expect(blank.apply().notices.isEmpty && blank.text(Self.file) == "text")
    }

    // MARK: Edits

    @Test func aPersonsEditBecomesAnOpAndBeatsAnyOlderSeed() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try Mac(Self.macA, dir: dir, values: [Self.file: "one"])
        mac.scan()
        mac.clock.now = mac.clock.now.addingTimeInterval(5)
        mac.source.values[Self.file] = Data("two".utf8)
        let edit = try #require(mac.scan().first)
        #expect(edit.unit == Self.file && !edit.seed)
        #expect(mac.store.winner(of: Self.file) == edit)
        // The setting, unset to set: a removed value is a deletion.
        mac.source.values[Self.setting] = Data("\"a\"".utf8)
        mac.scan()
        mac.source.values[Self.setting] = nil
        #expect(mac.scan().first?.change == .deletion)
    }

    @Test func aWriteTheMaterializerMadeNeverComesBackAsAnOp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.file: "one"])
        let b = try Mac(Self.macB, dir: dir, values: [Self.file: "one"])
        a.scan()
        b.scan()
        a.clock.now = a.clock.now.addingTimeInterval(10)
        a.source.values[Self.file] = Data("two".utf8)
        a.scan()
        a.send(to: b)
        #expect(b.apply().notices.isEmpty && b.text(Self.file) == "two")
        let before = b.store.vector
        #expect(b.scan().isEmpty, "B's own write is not B's edit")
        #expect(b.store.vector == before)
    }

    @Test func aValueWhoseBlobHasntArrivedIsLeftAloneUntilItDoes() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.file: "one"])
        let b = try Mac(Self.macB, dir: dir, values: [Self.file: ""])
        a.scan()
        b.scan()
        a.clock.now = a.clock.now.addingTimeInterval(10)
        a.source.values[Self.file] = Data("two".utf8)
        let op = try #require(a.scan().first)
        _ = b.store.receive(a.store.ops(after: b.store.vector).first { $0.seq == 1 }!)
        _ = b.store.receive(op)
        #expect(b.apply().failed == false && b.text(Self.file) == "", "no blob, no write: never a partial file")
        #expect(b.scan().isEmpty, "and the wait is not an edit")
        let hash = try #require(op.blobHash)
        _ = b.store.putBlob(try #require(a.store.blob(hash)), named: hash)
        _ = b.apply()
        #expect(b.text(Self.file) == "two")
    }

    // MARK: Failures and refusals

    @Test func aWriteThatFailsIsTriedAgainAndNeverTurnsIntoAnOp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"a\""])
        let b = try Mac(Self.macB, dir: dir, values: [Self.setting: "\"b\""])
        a.scan()
        b.clock.now = b.clock.now.addingTimeInterval(100)
        b.scan()
        a.send(to: b)
        b.source.failing = CocoaError(.fileWriteNoPermission)
        let first = b.apply()
        #expect(first.failed)
        let before = b.store.vector
        b.scan()
        #expect(b.store.vector[Self.macB] <= before[Self.macB], "pi holding its lock is not a local edit")
        b.source.failing = nil
        #expect(!b.apply().failed)
    }

    @Test func aValueThisBuildDoesntUnderstandIsRefusedOnceAndNeverRevertedFleetWide() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"future\""])
        let b = try Mac(Self.macB, dir: dir, values: [Self.setting: "\"mine\""])
        a.scan()
        b.clock.now = b.clock.now.addingTimeInterval(100)
        b.scan()
        a.send(to: b)
        b.source.failing = FleetUnitRefused(description: "unknown value")
        let result = b.apply()
        #expect(!result.failed, "a refusal isn't retried")
        let before = b.store.vector[Self.macB]
        b.clock.now = b.clock.now.addingTimeInterval(60)
        #expect(b.scan().filter { !$0.seed }.isEmpty, "B's own value stays, and does not outvote the fleet's")
        #expect(b.store.vector[Self.macB] >= before)
    }

    @Test func aSourceTheAppHasntReportedYetIsNotReadAsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"a\""])
        mac.source.ready = false
        #expect(mac.scan().isEmpty && mac.apply().notices.isEmpty)
        mac.source.ready = true
        #expect(mac.scan().map(\.unit) == [Self.setting])
    }

    @Test func anAsynchronousWriteIsWaitedForNotTakenForAnEdit() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"a\""])
        let b = try Mac(Self.macB, dir: dir, values: [Self.setting: "\"b\""])
        a.scan()
        b.source.asynchronous = true
        b.clock.now = b.clock.now.addingTimeInterval(100)
        b.scan()
        a.clock.now = a.clock.now.addingTimeInterval(500)
        a.source.values[Self.setting] = Data("\"newer\"".utf8)
        a.scan()
        a.send(to: b)
        _ = b.apply()
        #expect(b.source.written.map(\.value) == ["\"newer\""])
        let before = b.store.vector[Self.macB]
        #expect(b.scan().isEmpty, "the app hasn't applied it yet: the old value is not a new edit")
        #expect(b.store.vector[Self.macB] == before)
        b.source.values[Self.setting] = Data("\"newer\"".utf8)
        #expect(b.scan().isEmpty)
        b.source.values[Self.setting] = Data("\"edited again\"".utf8)
        #expect(b.scan().count == 1, "and once it landed, edits count again")
    }

    @Test func aPersonsEditWhileAnAsynchronousWriteIsInFlightIsStillTheirEdit() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"a\""])
        let b = try Mac(Self.macB, dir: dir, values: [Self.setting: "\"b\""])
        a.scan()
        b.source.asynchronous = true
        b.clock.now = b.clock.now.addingTimeInterval(100)
        b.scan()
        a.clock.now = a.clock.now.addingTimeInterval(500)
        a.source.values[Self.setting] = Data("\"newer\"".utf8)
        a.scan()
        a.send(to: b)
        _ = b.apply()
        // Before the app applied "newer", the person picked a third value.
        b.clock.now = b.clock.now.addingTimeInterval(1)
        b.source.values[Self.setting] = Data("\"mine\"".utf8)
        let edit = try #require(b.scan().first)
        #expect(edit.change == .value("\"mine\"") && !edit.seed, "it is not mistaken for the write in flight")
    }

    @Test func anAsynchronousWriteThatNeverLandsIsGivenUpOnNotRevertedFleetWide() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Mac(Self.macA, dir: dir, values: [Self.setting: "\"a\""])
        let b = try Mac(Self.macB, dir: dir, values: [Self.setting: "\"b\""])
        a.scan()
        b.source.asynchronous = true
        b.clock.now = b.clock.now.addingTimeInterval(100)
        b.scan()
        a.clock.now = a.clock.now.addingTimeInterval(500)
        a.source.values[Self.setting] = Data("\"newer\"".utf8)
        a.scan()
        a.send(to: b)
        _ = b.apply()
        b.clock.now = b.clock.now.addingTimeInterval(FleetMaterializer.pendingPatience + 1)
        let before = b.store.vector
        #expect(b.scan().isEmpty && b.store.vector == before, "the app never applied it: the old value is not an edit")
    }
}
