import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// Where delivered messages came from, kept per pi session so a relaunch still shows a queue
/// delivery's parts and a steer as steered. The unit under test is the file format.
@Suite("Thread origins")
struct ThreadOriginTests {
    typealias Record = ThreadOriginStore.Record
    static let one = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let parts = [NativeQueuePart(id: one, text: "one", sentAt: 10), NativeQueuePart(text: "twö", sentAt: 20, images: 1)]

    @Test func recordsRoundTripPerSession() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir.appendingPathComponent("thread-origins"))
        let queue = try #require(Record(.queue(parts: Self.parts))), steered = try #require(Record(.steered))
        store.save(sessionID: "s1", records: [("user:1", queue), ("user:2", steered)])
        store.flush()
        let loaded = store.load(sessionID: "s1")
        #expect(loaded.map(\.id) == ["user:1", "user:2"] && loaded.map(\.record) == [queue, steered])
        #expect(store.load(sessionID: "s2").isEmpty)
    }

    /// A part is kept as its length: the text is pi's own message, split where it was joined.
    @Test func aDeliveryIsRebuiltFromPisMessage() throws {
        let record = try #require(Record(.queue(parts: Self.parts)))
        #expect(record.parts?.map(\.bytes) == [3, 4], "UTF-8 bytes")
        #expect(record.origin(text: "one\n\ntwö") == .queue(parts: Self.parts))
        #expect(record.origin(text: "one\n\ntwö\n\n[image: resized]") == .queue(parts: Self.parts), "a note pi appends after the last part")
        #expect(Record(.steered)?.origin(text: "anything") == .steered)
        #expect(Record(.unknown) == nil)
    }

    /// A message that no longer splits where the parts say is not the one recorded: no origin,
    /// rather than wrong bubbles.
    @Test(arguments: ["one twö", "on", "one\n\ntw", "onex\ntwö"])
    func aMessageThatDoesNotSplitHasNoOrigin(text: String) throws {
        #expect(try #require(Record(.queue(parts: Self.parts))).origin(text: text) == nil)
    }

    /// The design references' copies a message the user sent carried are kept with its origin,
    /// so a relaunch still draws that message's chips (and no other's); a file from before they
    /// were kept reads without them.
    @Test func sentReferencesRoundTripBesideTheOrigin() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir)
        var queued = try #require(Record(.queue(parts: Self.parts)))
        queued.references = ["7c9e6679-7425-40de-944b-e07fc1f90ae7"]
        let alone = Record(references: ["00000000-0000-0000-0000-00000000000a"])
        store.save(sessionID: "s", records: [("user:1", queued), ("user:2", alone)])
        store.flush()
        let loaded = store.load(sessionID: "s")
        #expect(loaded.map(\.record) == [queued, alone])
        #expect(alone.origin(text: "anything") == nil, "references alone say nothing of where it came from")
        let older = try JSONDecoder().decode(Record.self, from: Data(#"{"steered":true}"#.utf8))
        #expect(older.references == nil && older.origin(text: "x") == .steered)
    }

    static let keptA = UUID(uuidString: "7c9e6679-7425-40de-944b-e07fc1f90ae7")!
    static let keptB = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!

    static func fenced(_ payloads: [String]) -> String {
        let records = payloads.map { DesignReferenceRecord(ref: "shepherd-design-ref://local/d1/A.dc.html@1", design: "Checkout", payload: $0) }
        return (DesignReferenceFence.fenced(records, nonce: "0123456789ab") ?? "") + "words"
    }

    /// A message draws its references only when the host kept every copy its fence names for the
    /// send or queued message it is: never from ids the text alone carries (a peer agent's prompt,
    /// a client typing a fence).
    struct FenceCase: Sendable, CustomTestStringConvertible {
        let label: String
        let named: [String]
        let kept: [UUID]
        let draws: Bool
        var testDescription: String { label }
    }

    static let fenceCases: [FenceCase] = [
        FenceCase(label: "kept, one", named: [keptA.uuidString], kept: [keptA], draws: true),
        FenceCase(label: "kept, lowercase", named: [keptA.uuidString.lowercased()], kept: [keptA], draws: true),
        FenceCase(label: "kept, both", named: [keptA.uuidString, keptB.uuidString], kept: [keptA, keptB], draws: true),
        FenceCase(label: "nothing kept", named: [keptA.uuidString], kept: [], draws: false),
        FenceCase(label: "another copy", named: ["11111111-2222-3333-4444-555555555555"], kept: [keptA], draws: false),
        FenceCase(label: "one of two forged", named: [keptA.uuidString, "11111111-2222-3333-4444-555555555555"], kept: [keptA], draws: false),
        FenceCase(label: "not an id", named: ["../../etc"], kept: [keptA], draws: false),
    ]

    /// A message draws its references only when the host kept every copy its fence names for the
    /// send or queued message it is: never from ids the text alone carries (a peer agent's prompt,
    /// a client typing a fence).
    @Test(arguments: fenceCases)
    func aFenceDrawsOnlyTheCopiesTheHostKept(_ c: FenceCase) {
        let drawn = RPCThreadState.sentReferences(in: Self.fenced(c.named), kept: c.kept)
        #expect((drawn != nil) == c.draws)
        if c.draws { #expect(drawn == c.named) }
        #expect(RPCThreadState.sentReferences(in: "no fence at all", kept: c.kept) == nil)
    }

    @Test func onlyTheNewestAreKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir)
        let steered = try #require(Record(.steered))
        store.save(sessionID: "s", records: (0..<(ThreadOriginStore.limit + 3)).map { ("user:\($0)", steered) })
        store.flush()
        let loaded = store.load(sessionID: "s")
        #expect(loaded.count == ThreadOriginStore.limit)
        #expect(loaded.first?.id == "user:3" && loaded.last?.id == "user:\(ThreadOriginStore.limit + 2)")
    }

    @Test(arguments: ["../escape", "a/b", "", "sess:1"])
    func aSessionIDNeverLeavesTheDirectory(sessionID: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir.appendingPathComponent("origins"))
        store.save(sessionID: sessionID, records: [("user:1", try #require(Record(.steered)))])
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("origins").path)
        #expect(files.count == 1 && !files[0].contains("/"))
        #expect(store.load(sessionID: sessionID).map(\.id) == ["user:1"])
    }

    @Test func anUnreadableFileIsNoOrigins() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("s.json"))
        #expect(ThreadOriginStore(directory: dir).load(sessionID: "s").isEmpty)
    }

    /// A delivery's parts restate its text, so they share one text budget.
    @Test func aDeliverysPartsAreClippedToTheMessageBudget() {
        let long = String(repeating: "x", count: RPCThreadState.textLimit - 1)
        let clipped = RPCThreadState.clipped(.queue(parts: [NativeQueuePart(text: long, sentAt: 1), NativeQueuePart(text: "é tail", sentAt: 2)]))
        #expect(clipped.parts?.map(\.text.utf8.count) == [RPCThreadState.textLimit - 1, 0], "never a split character")
        #expect(RPCThreadState.clipped(.steered) == .steered)
    }
}
