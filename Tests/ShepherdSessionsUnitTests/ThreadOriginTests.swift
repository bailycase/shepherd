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
        store.save(sessionID: "s1", records: [("user:1", queue), ("user:2", steered)],
                   generation: store.loadSession(sessionID: "s1").generation)
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
        store.save(sessionID: "s", records: [("user:1", queued), ("user:2", alone)],
                   generation: store.loadSession(sessionID: "s").generation)
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
        store.save(sessionID: "s", records: (0..<(ThreadOriginStore.limit + 3)).map { ("user:\($0)", steered) },
                   generation: store.loadSession(sessionID: "s").generation)
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
        store.save(sessionID: sessionID, records: [("user:1", try #require(Record(.steered)))],
                   generation: store.loadSession(sessionID: sessionID).generation)
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("origins").path)
        #expect(files.count == 1 && !files[0].contains("/"))
        #expect(store.load(sessionID: sessionID).map(\.id) == ["user:1"])
    }

    static let good = #"{"version":1,"entries":[{"id":"old","record":{"command":"/old"}}]}"#
    static let restored = #"{"version":1,"value":{"version":1,"entries":[{"id":"restored","record":{"command":"/restored"}}]}}"#
    static let badFiles = [
        "", "{", "null", "[]", "{}",
        #"{"version":null,"entries":[]}"#, #"{"version":"1","entries":[]}"#,
        #"{"version":2,"entries":[]}"#, #"{"version":1}"#,
        #"{"version":1,"entries":null}"#, #"{"version":1,"entries":{}}"#,
        #"{"version":1,"entries":[{}]}"#,
        #"{"version":1,"entries":[],"questions":null}"#,
        #"{"version":1,"entries":[],"questions":[null]}"#,
        #"{"version":1,"entries":[],"questions":[{"id":"q","endedAt":2,"record":{"kind":false,"question":"Proceed?","outcome":"answered","askedAt":1}}]}"#,
        #"{"version":1,"entries":[],"questions":[{"id":"q","endedAt":2,"record":{"kind":"confirm","question":"Proceed?","confirmed":null,"outcome":"answered","askedAt":1}}]}"#,
        #"{"version":1,"entries":[{"id":"a","record":{"command":null}}]}"#,
        #"{"version":1,"entries":[{"id":"a","record":{"references":{}}}]}"#,
        #"{"version":1,"entries":[{"id":"a","record":{"parts":[{"id":null,"bytes":1,"sentAt":0,"images":0}]}}]}"#,
        #"{"value":{"version":1,"entries":[]}}"#,
        #"{"version":null,"value":{"version":1,"entries":[]}}"#,
        #"{"version":2,"value":{"version":1,"entries":[]}}"#,
        #"{"version":1,"value":null}"#,
        #"{"version":1,"value":{"version":1,"entries":[]},"extra":true}"#,
    ]

    @Test(.timeLimit(.minutes(1)), arguments: badFiles)
    func damageKeepsLastGoodAndRefusesReplacement(_ input: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.json")
        try Data(Self.good.utf8).write(to: url)
        let store = ThreadOriginStore(directory: dir)
        #expect(store.load(sessionID: "s").map(\.id) == ["old"])
        let damaged = Data(input.utf8)
        try damaged.write(to: url, options: .atomic)
        let blocked = store.loadSession(sessionID: "s")
        #expect(blocked.entries.map(\.id) == ["old"])
        #expect(blocked.problem?.contains(url.path) == true)
        store.save(sessionID: "s", records: [("new", Record(command: "/new"))], generation: blocked.generation)
        store.flush()
        #expect(try Data(contentsOf: url) == damaged)
        try Data(Self.restored.utf8).write(to: url, options: .atomic)
        let repaired = store.loadSession(sessionID: "s")
        #expect(repaired.entries.map(\.id) == ["restored"] && repaired.problem == nil)
        store.save(sessionID: "s", records: [("new", Record(command: "/new"))], generation: repaired.generation)
        store.flush()
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(written.keys) == ["version", "entries"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func unreadablePathIsNeverReplaced(danglingLink: Bool) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.json")
        let target = dir.appendingPathComponent("absent")
        let store = ThreadOriginStore(directory: dir)
        try Data(Self.good.utf8).write(to: url)
        #expect(store.load(sessionID: "s").map(\.id) == ["old"])
        try FileManager.default.removeItem(at: url)
        if danglingLink {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let blocked = store.loadSession(sessionID: "s")
        #expect(blocked.entries.map(\.id) == ["old"] && blocked.problem != nil)
        store.save(sessionID: "s", records: [("new", Record(command: "/new"))], generation: blocked.generation)
        store.flush()
        if danglingLink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
        } else {
            #expect(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
        try FileManager.default.removeItem(at: url)
        let repaired = store.loadSession(sessionID: "s")
        #expect(repaired.entries.map(\.id) == ["old"] && repaired.problem == nil)
        store.save(sessionID: "s", records: [("new", Record(command: "/new"))], generation: repaired.generation)
        store.flush()
        #expect(store.load(sessionID: "s").map(\.id) == ["new"])
    }

    @Test(.timeLimit(.minutes(1)))
    func deletionRepairsDamageWithoutDiscardingLastGood() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.json")
        let store = ThreadOriginStore(directory: dir)
        try Data(Self.good.utf8).write(to: url)
        #expect(store.load(sessionID: "s").map(\.id) == ["old"])
        try Data("{".utf8).write(to: url, options: .atomic)
        #expect(store.load(sessionID: "s").map(\.id) == ["old"])
        try FileManager.default.removeItem(at: url)
        let repaired = store.loadSession(sessionID: "s")
        #expect(repaired.entries.map(\.id) == ["old"] && repaired.problem == nil)
        store.save(sessionID: "s", records: repaired.entries + [("new", Record(command: "/new"))], generation: repaired.generation)
        store.flush()
        #expect(ThreadOriginStore(directory: dir).load(sessionID: "s").map(\.id) == ["old", "new"])
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedWritesCannotReplaceARecoveredBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.json")
        let store = ThreadOriginStore(directory: dir)
        let backup = Data(Self.restored.utf8)
        try Data(Self.good.utf8).write(to: url)
        let original = store.loadSession(sessionID: "s")
        let damaged = Data("{".utf8)
        try damaged.write(to: url, options: .atomic)
        store.io.suspend()
        store.save(sessionID: "s", records: original.entries, generation: original.generation) { snapshot in
            #expect(snapshot.problem?.contains(url.path) == true)
            #expect((try? Data(contentsOf: url)) == damaged)
            #expect(throws: Never.self) { try backup.write(to: url, options: .atomic) }
        }
        store.save(sessionID: "s", records: [("stale", Record(command: "/stale"))], generation: original.generation)
        store.io.resume()
        store.flush()
        #expect(try Data(contentsOf: url) == backup)
        let recovered = store.loadSession(sessionID: "s")
        #expect(recovered.problem == nil)
        #expect(recovered.entries.map(\.id) == ["restored"])
        store.save(sessionID: "s", records: recovered.entries + [("new", Record(command: "/new"))], generation: recovered.generation)
        store.flush()
        #expect(ThreadOriginStore(directory: dir).load(sessionID: "s").map(\.id) == ["restored", "new"])
    }

    @Test func aLongDeliveryKeepsEveryPartsText() throws {
        let parts = [NativeQueuePart(text: String(repeating: "中🐑", count: 20_000), sentAt: 1),
                     NativeQueuePart(text: "é tail", sentAt: 2)]
        let text = parts.map(\.text).joined(separator: "\n\n")
        let record = try #require(Record(.queue(parts: parts)))
        let rows = RPCThreadState.projectHistory([RPCMessage(role: "user", content: [.text(text)])]) { row, _ in
            row.origin = record.origin(text: text)
        }
        #expect(rows.first?.origin == .queue(parts: parts))
        #expect(rows.first?.blocks.first?.text == text)
    }
}
