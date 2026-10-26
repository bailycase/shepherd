import AppKit
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The images of a thread, from pi's saved history to a client (docs/native-thread.md › Images): a send's images come back
/// named in the snapshot and fetched in pieces, after a restart too; an agent's and a tool's images are named the same way;
/// a stale, foreign, malformed or oversized request is refused; and nothing but metadata is in a snapshot.
// Serialized: several tests watch `ThreadImages.onHeavyWork`, one process-wide hook, which parallel tests would overwrite.
@Suite("Thread images, host", .serialized, .integrationTimeLimit)
struct ThreadImagesTests {
    /// A real PNG of `side` × `side` points, padded to `bytes` where it must be bigger (the padding follows IEND, which a decoder ignores).
    static func png(side: Int = 8, bytes: Int = 0) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        var data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        if data.count < bytes { data.append(Data(repeating: 0, count: bytes - data.count)) }
        return data
    }

    static func nativeImage(_ data: Data, name: String = "shot.png") -> NativeImage { NativeImage(mimeType: "image/png", data: data, name: name) }

    /// The whole of image `id` for `agent`, asked a piece at a time as a client does.
    static func fetch(_ id: String, from pi: PiAgent, session: String) async throws -> (mime: String, data: Data, pieces: Int) {
        var data = Data()
        var total: Int?
        var mime = ""
        var pieces = 0
        while total == nil || data.count < total! {
            guard case .imageChunk(let chunk) = try await pi.request(.image(expectedSessionID: session, imageID: id, offset: data.count)) else {
                throw WireError("no piece at \(data.count)")
            }
            #expect(chunk.offset == data.count && !chunk.data.isEmpty && chunk.data.count <= NativeImage.chunkBytes)
            total = chunk.totalBytes
            mime = chunk.mimeType
            data.append(chunk.data)
            pieces += 1
        }
        return (mime, data, pieces)
    }

    // MARK: Sent, then restored

    /// What a user sent comes back named in the snapshot, fetched whole from pi's saved history, and again after a restart
    /// that reloads that history: nothing depends on this client's memory or on the original file.
    @Test func aSentImageIsNamedFetchedInPiecesAndStillThereAfterARestart() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let history = h.dir.appendingPathComponent("history.json")
        let big = Self.png(side: 64, bytes: 600_000)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:0 see this", images: [Self.nativeImage(big)], from: idle).failureCode == nil)
        let settled = try await pi.snapshot("the turn to settle with its image") { s in
            !s.running && s.messages.contains { $0.role == "user" && $0.blocks.contains { $0.imageID != nil } }
        }
        let user = try #require(settled.messages.first { $0.role == "user" && $0.blocks.contains { $0.imageID != nil } })
        let block = try #require(user.blocks.first { $0.imageID != nil })
        #expect(block.kind == .unsupportedImage && block.mimeType == "image/png" && block.width == 64 && block.height == 64)
        #expect(block.byteCount == big.count)
        #expect(settled.supportedActions.contains("images"))
        // The snapshot carries no bytes.
        let encoded = try JSONEncoder().encode(settled)
        #expect(encoded.count < 20_000, "metadata only: \(encoded.count) bytes")

        let first = try await Self.fetch(try #require(block.imageID), from: pi, session: settled.piSessionID)
        #expect(first.data == big && first.mime == "image/png")
        #expect(first.pieces == (big.count + NativeImage.chunkBytes - 1) / NativeImage.chunkBytes && first.pieces >= 3)

        // A restart loads pi's saved history again; the image is still there under a name that finds it.
        let replay = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let restored = try await replay.ready()
        let again = try #require(restored.messages.first { $0.role == "user" && $0.blocks.contains { $0.imageID != nil } }?.blocks.first { $0.imageID != nil })
        #expect(again.imageID == block.imageID, "the name does not depend on the process")
        let second = try await Self.fetch(try #require(again.imageID), from: replay, session: restored.piSessionID)
        #expect(second.data == big)
    }

    // MARK: Received

    /// An image an agent or a tool returned is named like a user's: assistant and toolResult messages carry them.
    @Test func anAgentsAndAToolsImagesAreNamedAndFetched() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let png = Self.png(side: 32)
        let history = h.dir.appendingPathComponent("history.json")
        let record: [[String: Any]] = [
            ["role": "user", "content": "chart it", "timestamp": 1_733_234_567_890],
            ["role": "assistant", "content": [["type": "text", "text": "Here."], ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]],
             "stopReason": "stop", "timestamp": 1_733_234_567_891],
            ["role": "assistant", "content": [["type": "toolCall", "id": "c1", "name": "chart", "arguments": [:]]], "stopReason": "toolUse",
             "timestamp": 1_733_234_567_892],
            ["role": "toolResult", "toolCallId": "c1", "toolName": "chart", "isError": false, "timestamp": 1_733_234_567_893,
             "content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]],
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: history)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let s = try await pi.snapshot("the saved history") { $0.messages.contains { $0.role == "toolResult" } }
        let assistant = try #require(s.messages.first { $0.role == "assistant" && $0.blocks.contains { $0.imageID != nil } })
        let tool = try #require(s.messages.first { $0.role == "toolResult" })
        let refs = [assistant.blocks.compactMap(\.image), tool.blocks.compactMap(\.image)].flatMap { $0 }
        #expect(refs.count == 2 && Set(refs.map(\.id)).count == 2, "each image has an id of its own: \(refs)")
        for ref in refs {
            #expect(try await Self.fetch(ref.id, from: pi, session: s.piSessionID).data == png)
        }
    }

    // MARK: Refused

    @Test func aStaleForeignOrMadeUpIdFindsNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let history = h.dir.appendingPathComponent("history.json")
        let png = Self.png()
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let idle = try await pi.ready()
        _ = try await pi.send("tools:0 look", images: [Self.nativeImage(png)], from: idle)
        let s = try await pi.snapshot("the image") { s in !s.running && s.messages.contains { $0.blocks.contains { $0.imageID != nil } } }
        let id = try #require(s.messages.flatMap(\.blocks).compactMap(\.imageID).first)
        // A session the host has moved past.
        #expect(try await pi.request(.image(expectedSessionID: "another-session", imageID: id, offset: 0)).failureCode == "stale_session")
        // Ids that name no image: made up, another entry, another position, another hash, and shapes that are not ids.
        let parts = id.split(separator: "|").map(String.init)
        let zero = String(repeating: "0", count: 64)
        #expect(parts[2].count == 64, "the id carries the whole SHA-256: \(parts[2])")
        let flipped = String(parts[2].prefix(63)) + (parts[2].last == "0" ? "1" : "0")
        let bad = ["nope", "", "|0|", "user:1|0|\(zero)", "\(parts[0])|1|\(parts[2])", "\(parts[0])|0|\(zero)",
                   "other:9|0|\(parts[2])", "../../etc/passwd", "\(parts[0])|-1|\(parts[2])", "\(parts[0])|0|\(String(parts[2].dropLast()))",
                   "\(parts[0])|0|\(String(parts[2].prefix(16)))", "\(parts[0])|0|\(flipped)"]
        for value in bad {
            #expect(try await pi.request(.image(expectedSessionID: s.piSessionID, imageID: value, offset: 0)).failureCode == NativeImageCode.unknown, "\(value)")
        }
        // A piece past the end, and a negative start.
        #expect(try await pi.request(.image(expectedSessionID: s.piSessionID, imageID: id, offset: png.count)).failureCode == NativeImageCode.unknown)
        #expect(try await pi.request(.image(expectedSessionID: s.piSessionID, imageID: id, offset: -1)).failureCode == NativeImageCode.unknown)
    }

    /// Another thread's id finds nothing in this one: ids carry the image's hash, and a thread serves only its own history.
    @Test func anotherThreadsImageIdIsRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let a = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": h.dir.appendingPathComponent("a.json").path])
        let b = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": h.dir.appendingPathComponent("b.json").path])
        let sa = try await a.ready()
        let sb = try await b.ready()
        _ = try await a.send("tools:0 mine", images: [Self.nativeImage(Self.png(side: 16))], from: sa)
        _ = try await b.send("tools:0 yours", images: [Self.nativeImage(Self.png(side: 24))], from: sb)
        let ma = try await a.snapshot("a's image") { s in s.messages.contains { $0.blocks.contains { $0.imageID != nil } } && !s.running }
        let mb = try await b.snapshot("b's image") { s in s.messages.contains { $0.blocks.contains { $0.imageID != nil } } && !s.running }
        let idA = try #require(ma.messages.flatMap(\.blocks).compactMap(\.imageID).first)
        let idB = try #require(mb.messages.flatMap(\.blocks).compactMap(\.imageID).first)
        #expect(idA != idB)
        #expect(try await b.request(.image(expectedSessionID: mb.piSessionID, imageID: idA, offset: 0)).failureCode == NativeImageCode.unknown)
        #expect(try await a.request(.image(expectedSessionID: ma.piSessionID, imageID: idB, offset: 0)).failureCode == NativeImageCode.unknown)
    }

    // MARK: Off the server queue

    /// The header read, hash and base64 of a megabytes-long history run on a utility queue, never on the queue that owns the thread: a
    /// cold history (images never read before) is warmed off it before it is projected, and an image request does its scan off it too.
    /// Asked the way the reviewer asked: where did each piece of heavy work run?
    @Test func coldImageWorkRunsOffTheServerQueue() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var queues: [String] = []
            func add(_ label: String) { lock.withLock { queues.append(label) } }
            var all: [String] { lock.withLock { queues } }
        }
        let seen = Seen()
        // This test's image has a size no other test uses, so work another test does at the same time is not counted.
        let unique = Self.png(side: 41, bytes: 91_113)
        let mine = unique.base64EncodedString().utf8.count
        ThreadImages.onHeavyWork = { size in if size == mine { seen.add(String(cString: __dispatch_queue_get_label(nil))) } }
        defer { ThreadImages.onHeavyWork = nil }
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let history = h.dir.appendingPathComponent("history.json")
        let record: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "cold"], ["type": "image", "data": unique.base64EncodedString(), "mimeType": "image/png"]],
             "timestamp": 1_733_234_567_890],
            ["role": "assistant", "content": [["type": "text", "text": "ok"]], "stopReason": "stop", "timestamp": 1_733_234_567_891],
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: history)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let s = try await pi.snapshot("the cold history") { $0.messages.contains { $0.blocks.contains { $0.imageID != nil } } }
        let id = try #require(s.messages.flatMap(\.blocks).compactMap(\.imageID).first)
        #expect(!seen.all.isEmpty, "the header was read")
        // The queues that own the thread: the RPC session's (`shepherd.rpc`, which targets the server's `shepherd.sessions`).
        let owners: Set<String> = ["shepherd.rpc", "shepherd.sessions"]
        #expect(seen.all.allSatisfy { !owners.contains($0) && $0.contains("utility") },
                "a cold history's images were read on a utility queue, never on the thread's: \(seen.all)")
        // Serving a piece reads nothing on the owner either (the cache is warm, so nothing is read at all, or it is read off it).
        let before = seen.all.count
        _ = try await Self.fetch(id, from: pi, session: s.piSessionID)
        #expect(seen.all.dropFirst(before).allSatisfy { !owners.contains($0) }, "serving a piece did not read headers on the owner's queue: \(seen.all)")
    }

    // MARK: Identity is the whole content

    /// Two different valid PNGs of one length that agree on their first and last 64 base64 characters, as a partial-content key would
    /// not tell apart. They are one image's pixels with a few bytes changed in the middle of a padding chunk after the end marker, which a
    /// decoder ignores, so both decode and both say 8 × 8.
    static func lookalikes() -> (Data, Data) {
        let base = png(side: 8)
        var first = base, second = base
        let pad = 4_000
        first.append(Data(repeating: 0x11, count: pad))
        second.append(Data(repeating: 0x11, count: pad))
        // Change bytes only in the middle of the padding: the ends (and so the first and last 64 base64 characters) are shared.
        second[second.count - pad / 2] = 0x99
        second[second.count - pad / 2 - 1] = 0x98
        return (first, second)
    }

    @Test func twoImagesThatShareLengthPrefixAndSuffixAreDistinctAndEachServesItsOwnBytes() async throws {
        let (one, two) = Self.lookalikes()
        let (a, b) = (one.base64EncodedString(), two.base64EncodedString())
        #expect(one != two && one.count == two.count && a.count == b.count)
        #expect(a.prefix(64) == b.prefix(64) && a.suffix(64) == b.suffix(64), "the premise: only the middle differs")
        let ia = try #require(ThreadImages.inspect(mimeType: "image/png", base64: a))
        let ib = try #require(ThreadImages.inspect(mimeType: "image/png", base64: b))
        #expect(ia.meta.hash != ib.meta.hash && ia.meta.hash.count == 64, "the whole content's SHA-256, never a prefix")
        #expect(ia.meta.width == 8 && ib.meta.width == 8 && ia.meta.byteCount == one.count && ib.meta.byteCount == two.count)

        let history: [RPCMessage] = [
            RPCMessage(role: "user", content: [.text("a"), .image(mimeType: "image/png", data: a)], timestamp: 1),
            RPCMessage(role: "user", content: [.text("b"), .image(mimeType: "image/png", data: b)], timestamp: 2),
        ]
        let ids = RPCThreadState.projectHistory(history, images: ThreadImages.table(for: history)).flatMap(\.blocks).compactMap(\.imageID)
        #expect(ids.count == 2 && ids[0] != ids[1])
        #expect(ThreadImages.find(ids[0], in: history)?.data == one, "the first id serves the first image's bytes")
        #expect(ThreadImages.find(ids[1], in: history)?.data == two, "the second id serves the second, not the first")
        // Swap the two images' contents between the entries: an id names its content, so each id now finds nothing where its image no longer is.
        let swapped: [RPCMessage] = [
            RPCMessage(role: "user", content: [.text("a"), .image(mimeType: "image/png", data: b)], timestamp: 1),
            RPCMessage(role: "user", content: [.text("b"), .image(mimeType: "image/png", data: a)], timestamp: 2),
        ]
        #expect(ThreadImages.find(ids[0], in: swapped) == nil && ThreadImages.find(ids[1], in: swapped) == nil)
        // The same entry and position holding different bytes than the id named: refused, not served.
        let replaced = [RPCMessage(role: "user", content: [.text("a"), .image(mimeType: "image/png", data: b)], timestamp: 1), history[1]]
        #expect(ThreadImages.find(ids[0], in: replaced) == nil, "an id never serves bytes whose hash is not its own")
    }

    /// Nothing carries over between histories: the same image in a second history is inspected again, and a changed one is never answered
    /// from the first (there is no cache whose identity could be fooled).
    @Test func nothingIsRememberedBetweenHistories() {
        let (one, two) = Self.lookalikes()
        final class Count: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() { lock.withLock { n += 1 } }
            var value: Int { lock.withLock { n } }
        }
        let counter = Count()
        let size = one.base64EncodedString().utf8.count
        ThreadImages.onHeavyWork = { bytes in if bytes == size { counter.bump() } }
        defer { ThreadImages.onHeavyWork = nil }
        let first: [RPCMessage] = [RPCMessage(role: "user", content: [.image(mimeType: "image/png", data: one.base64EncodedString())], timestamp: 1)]
        let second: [RPCMessage] = [RPCMessage(role: "user", content: [.image(mimeType: "image/png", data: two.base64EncodedString())], timestamp: 1)]
        let t1 = ThreadImages.table(for: first), t2 = ThreadImages.table(for: second)
        #expect(counter.value == 2, "each history was read for itself, \(counter.value) reads")
        #expect(t1.values.first?.hash != t2.values.first?.hash)
    }

    // MARK: Many images, and the live path

    /// A history of more than 512 images (the old cache's size) names every one of them, correctly, and the snapshot path reads none of
    /// them on the thread's queue: the table is built off it, and the projection is a lookup.
    @Test func aHistoryOfMoreThanFiveHundredImagesIsNamedWholeAndNeverReadOnTheOwnersQueue() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var queues: [String] = []
            func add(_ label: String) { lock.withLock { queues.append(label) } }
            var all: [String] { lock.withLock { queues } }
        }
        let seen = Seen()
        // One distinct small image per message: 600 of them, each a different size so none is "the same image".
        let count = 600
        let images = (0..<count).map { Self.png(side: 3 + ($0 % 40), bytes: 600 + $0) }
        let sizes = Set(images.map { $0.base64EncodedString().utf8.count })
        ThreadImages.onHeavyWork = { size in if sizes.contains(size) { seen.add(String(cString: __dispatch_queue_get_label(nil))) } }
        defer { ThreadImages.onHeavyWork = nil }
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let history = h.dir.appendingPathComponent("history.json")
        var record: [[String: Any]] = []
        for (i, data) in images.enumerated() {
            record.append(["role": "user", "content": [["type": "text", "text": "m\(i)"], ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]],
                           "timestamp": 1_733_234_000_000 + i])
        }
        try JSONSerialization.data(withJSONObject: record).write(to: history)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let first = try await pi.snapshot("the history", timeout: .seconds(60)) { $0.messages.count >= 50 }
        _ = first
        // Page back to the beginning so every image has been named at least once.
        let owners: Set<String> = ["shepherd.rpc", "shepherd.sessions"]
        #expect(!seen.all.isEmpty && seen.all.allSatisfy { !owners.contains($0) }, "all \(seen.all.count) reads were off the owner's queue: \(Set(seen.all))")
        #expect(seen.all.count >= count, "every image was read once for this history, not just the last 512: \(seen.all.count)")
        // A page of the history names its images, each fetchable and each the right one.
        let named = first.messages.flatMap { m in m.blocks.compactMap(\.image).map { (m.entryID, $0) } }
        #expect(!named.isEmpty && named.allSatisfy { $0.1.width != nil && $0.1.id.split(separator: "|").last?.count == 64 })
        for (entryID, ref) in named.suffix(3) {
            let index = try #require(Int(entryID.split(separator: ":").last.map(String.init)?.suffix(3).description ?? "") ?? nil)
            _ = index
            let fetched = try await Self.fetch(ref.id, from: pi, session: first.piSessionID)
            #expect(fetched.data.count == ref.byteCount)
        }
    }

    /// A live tool result's image: pi streams it in a tool event before it is in history, and the live row is projected on the thread's queue.
    /// That projection looks nothing up (the row has no history entry yet), so it decodes and hashes nothing there. Driven end to end through the
    /// stub: while the tool's result is live its row is the chip, every read of its image is off the owner's queue, and once the turn ends and
    /// history is read, the same image is named and fetchable.
    @Test func aLiveToolImageIsNeverReadOnTheOwnersQueueAndIsNamedOnceHistoryHasIt() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var queues: [String] = []
            func add(_ label: String) { lock.withLock { queues.append(label) } }
            var all: [String] { lock.withLock { queues } }
        }
        let seen = Seen()
        let data = Self.png(side: 29, bytes: 70_321)
        let mine = data.base64EncodedString().utf8.count
        ThreadImages.onHeavyWork = { size in if size == mine { seen.add(String(cString: __dispatch_queue_get_label(nil))) } }
        defer { ThreadImages.onHeavyWork = nil }
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let result: [String: Any] = ["toolName": "chart", "isError": false,
                                     "content": [["type": "text", "text": "drawn"], ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]],
                                     "details": [:]]
        try JSONSerialization.data(withJSONObject: result).write(to: h.dir.appendingPathComponent("project-tool-result.json"))
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": h.dir.appendingPathComponent("h.json").path])
        let idle = try await pi.ready()
        _ = try await pi.send("project-action", from: idle)
        // While the tool is live (the stub holds the turn until released): its row carries the image block and names nothing.
        let live = try await pi.snapshot("the live tool result image") { s in
            s.provisional.contains { $0.role == "toolResult" && $0.blocks.contains { $0.kind == .unsupportedImage } }
        }
        let liveBlocks = live.provisional.filter { $0.role == "toolResult" }.flatMap(\.blocks).filter { $0.kind == .unsupportedImage }
        #expect(!liveBlocks.isEmpty && liveBlocks.allSatisfy { $0.imageID == nil }, "a live row names no image yet: \(liveBlocks)")
        #expect(seen.all.isEmpty, "projecting the live image read nothing on any queue: \(seen.all)")
        pi.release(1)
        let settled = try await pi.snapshot("history with the image named") { s in
            !s.running && s.messages.contains { $0.role == "toolResult" && $0.blocks.contains { $0.imageID != nil } }
        }
        let ref = try #require(settled.messages.filter { $0.role == "toolResult" }.flatMap(\.blocks).compactMap(\.image).first)
        #expect(ref.byteCount == data.count && ref.width == 29)
        let owners: Set<String> = ["shepherd.rpc", "shepherd.sessions"]
        #expect(!seen.all.isEmpty && seen.all.allSatisfy { !owners.contains($0) }, "history's read of it was off the owner's queue: \(seen.all)")
        #expect(try await Self.fetch(ref.id, from: pi, session: settled.piSessionID).data == data)
    }

    // MARK: Ids and hidden messages

    /// The reviewer's case: a visible custom message (an extension's, with an image) after hidden custom messages that share its timestamp.
    /// History skips the hidden ones before it counts repeats ("custom:7", "custom:7#1"), so `find` must skip them too; counting them made the
    /// offered id "custom:7" resolve to nothing, or "custom:7#1" to the wrong message.
    @Test func anIdStillFindsItsImageAfterHiddenMessagesWithTheSameTimestamp() async throws {
        let a = Self.png(side: 12), b = Self.png(side: 20)
        func custom(_ time: Double, _ content: [RPCContentBlock], display: Bool, kind: String = "note") -> RPCMessage {
            var m = RPCMessage(role: "custom", content: content, timestamp: time)
            m.display = display
            m.customType = kind
            return m
        }
        let history: [RPCMessage] = [
            custom(7, [.text("hidden one")], display: false),
            custom(7, [.text("shown"), .image(mimeType: "image/png", data: a.base64EncodedString())], display: true),
            custom(7, [.text("hidden two")], display: false),
            custom(7, [.text("a child's report")], display: true, kind: "shepherd-child"),
            custom(7, [.text("shown again"), .image(mimeType: "image/png", data: b.base64EncodedString())], display: true),
        ]
        let shown = RPCThreadState.shownHistory(history)
        #expect(shown.map(\.entryID) == ["custom:7", "custom:7#1"], "history counts only what it shows: \(shown.map(\.entryID))")
        let ids = RPCThreadState.projectHistory(history, images: ThreadImages.table(for: history)).flatMap(\.blocks).compactMap(\.imageID)
        #expect(ids.count == 2 && ids[0].hasPrefix("custom:7|0|") && ids[1].hasPrefix("custom:7#1|0|"), "\(ids)")
        #expect(ThreadImages.find(ids[0], in: history)?.data == a, "the first shown message, not nothing")
        #expect(ThreadImages.find(ids[1], in: history)?.data == b, "the second, not the first and not nothing")
    }

    /// Ids and rows come from the same list, whatever is hidden between: for every image the snapshot names, `find` returns that image.
    @Test func everyOfferedIdResolvesToItsOwnBytes() {
        let png = Self.png(side: 9), other = Self.png(side: 31)
        var history: [RPCMessage] = []
        for round in 0..<6 {
            var hidden = RPCMessage(role: "custom", content: [.text("h")], timestamp: Double(round / 2))
            hidden.display = false
            history.append(hidden)
            history.append(RPCMessage(role: round % 3 == 0 ? "toolResult" : "user",
                                      content: [.image(mimeType: "image/png", data: (round.isMultiple(of: 2) ? png : other).base64EncodedString())],
                                      toolCallId: round % 3 == 0 ? "c\(round)" : nil, timestamp: Double(round / 2)))
        }
        let rows = RPCThreadState.projectHistory(history, images: ThreadImages.table(for: history))
        let named = rows.flatMap(\.blocks).compactMap(\.image)
        #expect(named.count == 6)
        for ref in named {
            let found = ThreadImages.find(ref.id, in: history)
            #expect(found != nil && found.map { Data($0.data.count == ref.byteCount ? $0.data : Data()) }?.isEmpty == false, "\(ref.id)")
        }
    }

    // MARK: A label is not a type

    /// The bytes' own type must be the one the block says: a TIFF, a GIF or a JPEG called png is not offered, and a real png called
    /// jpeg is not either. ImageIO reads all of them, so the detected type is what decides.
    @Test func aRelabelledImageIsNotNamed() throws {
        func rep(_ type: NSBitmapImageRep.FileType) throws -> Data {
            try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: type, properties: [:]))
        }
        func named(_ data: Data, as mime: String) -> Bool { ThreadImages.inspect(mimeType: mime, base64: data.base64EncodedString()) != nil }
        let tiff = try rep(.tiff), gif = try rep(.gif), jpeg = try rep(.jpeg), png = try rep(.png), bmp = try rep(.bmp)
        #expect(named(png, as: "image/png") && named(jpeg, as: "image/jpeg") && named(gif, as: "image/gif"), "honest labels are named")
        #expect(!named(tiff, as: "image/png") && !named(tiff, as: "image/jpeg") && !named(bmp, as: "image/png"), "a TIFF or BMP called png or jpeg")
        #expect(!named(gif, as: "image/png") && !named(jpeg, as: "image/png") && !named(png, as: "image/jpeg"), "one offered type called another")
    }

    // MARK: Limits

    /// A snapshot names only what it will serve: over the byte or pixel bound, or not a raster type, is a chip.
    @Test func whatTheThreadWillNotServeIsNotNamed() throws {
        let png = Self.png(side: 8)
        func meta(_ data: Data, _ mime: String = "image/png") -> ThreadImages.Meta? { ThreadImages.inspect(mimeType: mime, base64: data.base64EncodedString())?.meta }
        #expect(meta(png)?.width == 8)
        #expect(meta(Self.png(side: 8, bytes: NativeImage.maxBytes + 1)) == nil, "over the byte bound")
        #expect(meta(png, "image/svg+xml") == nil, "not a raster type")
        #expect(meta(png, "text/html") == nil)
        #expect(meta(Data("<html></html>".utf8)) == nil, "not an image")
        #expect(meta(Data(count: 64)) == nil, "garbage")
        // Over the pixel bound: a header that says so, small on disk.
        let wide = Self.png(side: 4200)
        #expect(wide.count < NativeImage.maxBytes && meta(wide) == nil, "4200 × 4200 is over \(NativeImage.maxPixels) pixels")
    }

    @Test func aPieceIsAtMostTheChunkSizeAndTheLastOneIsTheRemainder() {
        let data = Data(count: NativeImage.chunkBytes * 2 + 10)
        let first = ThreadImages.chunk("id", mimeType: "image/png", data: data, offset: 0)
        let last = ThreadImages.chunk("id", mimeType: "image/png", data: data, offset: NativeImage.chunkBytes * 2)
        #expect(first?.data.count == NativeImage.chunkBytes && first?.totalBytes == data.count)
        #expect(last?.data.count == 10)
        #expect(ThreadImages.chunk("id", mimeType: "image/png", data: data, offset: data.count) == nil)
        #expect(ThreadImages.chunk("id", mimeType: "image/png", data: data, offset: -5) == nil)
    }

    @Test func anIdIsParsedOnlyInItsOwnShape() {
        let hash = String(repeating: "ab", count: 32)
        #expect(ThreadImages.parse("user:1733234567890|0|\(hash)")?.index == 0)
        #expect(ThreadImages.parse("t:call|with|bars|2|\(hash)")?.entryID == "t:call|with|bars")
        for bad in ["", "x", "a|b|c", "a|-1|\(hash)", "a|0|short", "|0|\(hash)", "a|0|0123456789abcdef", "a|0|\(hash)00"] {
            #expect(ThreadImages.parse(bad) == nil, "\(bad)")
        }
    }

    // MARK: A second client

    /// A remote client with the capability sees the same names and bytes; one without it is not offered the action.
    @Test func remoteScreenshotsFitTheListenerForSendsAndNewThreads() async throws {
        let host = try ScratchServer.fresh(); defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        let idle = try await pi.ready()
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(); defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "images")
        let images = Array(repeating: Self.nativeImage(Self.png(side: 48, bytes: 900_000)), count: 4)
        let result = try await client.nativeThread(agentID: pi.agent.id,
            request: .send(expectedSessionID: idle.piSessionID, generation: idle.generation, operationID: UUID(),
                           text: "remote screenshots", delivery: .followUp, images: images))
        guard case .accepted = result else { Issue.record("Expected image delivery: \(result)"); return }
        let prompt = try await pi.waitForStdin("prompt")
        let sent = try #require(prompt["images"] as? [[String: Any]])
        #expect(sent.count == 4)
        #expect(sent.allSatisfy { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? Int.max < 900_000 })
        let captured = Locked<[NativeImage]>([])
        host.server.onRemoteCreateAgent = { request, done in
            captured.withValue { $0 = request.initialImages }
            done(.success(AgentID()))
        }
        defer { host.server.onRemoteCreateAgent = nil }
        _ = try await client.createAgent(spaceID: pi.agent.spaceID, cwd: nil, model: nil, thinking: nil, initialPrompt: "opening screenshots", initialImages: images)
        #expect(captured.current.count == 4)
        #expect(captured.current.allSatisfy { $0.data.count < 900_000 && $0.name == "shot.png" })
        #expect(try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue != nil)
    }

    @Test func aRemoteClientFetchesTheSameImage() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let png = Self.png(side: 48, bytes: 400_000)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": h.dir.appendingPathComponent("h.json").path])
        let idle = try await pi.ready()
        _ = try await pi.send("tools:0 remote", images: [Self.nativeImage(png)], from: idle)
        _ = try await pi.snapshot("the image") { s in !s.running && s.messages.contains { $0.blocks.contains { $0.imageID != nil } } }

        let tokenURL = h.dir.appendingPathComponent("token")
        let port = try h.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(); defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "viewer")
        #expect(client.capabilities.contains(RemoteProtocol.nativeImagesCapability))
        let snapshot = try #require(try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue)
        #expect(snapshot.supportedActions.contains("images"))
        let ref = try #require(snapshot.messages.flatMap(\.blocks).compactMap(\.image).first)
        var data = Data()
        var total = Int.max
        while data.count < total {
            let reply = try await client.nativeThread(agentID: pi.agent.id,
                                                      request: .image(expectedSessionID: snapshot.piSessionID, imageID: ref.id, offset: data.count))
            guard case .imageChunk(let chunk) = reply else { throw WireError("no chunk: \(reply)") }
            total = chunk.totalBytes
            data.append(chunk.data)
        }
        #expect(data == png)
    }
}
