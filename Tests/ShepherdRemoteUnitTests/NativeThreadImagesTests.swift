import AppKit
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The client's image fetching (`NativeThreadImages`): pieces in order into one image, a cache that is bounded, one fetch for many
/// askers, fetches that stop when the thread leaves, and a host that answers wrongly is not believed.
@MainActor
@Suite("Thread image fetching", .timeLimit(.minutes(1)))
struct NativeThreadImagesTests {
    /// A real PNG of `side` × `side` pixels, padded after its end marker to `bytes` (a decoder ignores trailing bytes), so a test serves
    /// bytes the client's raster check accepts at the size it needs.
    static func image(side: Int = 100, bytes: Int = 0, type: NSBitmapImageRep.FileType = .png) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var data = rep.representation(using: type, properties: [:])!
        if data.count < bytes { data.append(Data((0..<(bytes - data.count)).map { UInt8(truncatingIfNeeded: $0) })) }
        return data
    }

    /// Three pieces' worth: 700 KB of a 100 × 100 image.
    static let png = image(side: 100, bytes: 700_000)

    /// A host that serves `images` by id, `chunk` bytes at a time, counting what it was asked.
    @MainActor final class Host {
        var images: [String: Data]
        var asked: [(id: String, offset: Int)] = []
        var chunk = NativeImage.chunkBytes
        var gate: Gate?
        var lie: ((NativeImageChunk) -> NativeImageChunk)?
        var failure: NativeThreadResult?
        /// How many requests were being answered at once, and the most there were.
        var active = 0
        var peak = 0
        init(_ images: [String: Data]) { self.images = images }

        func answer(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .image(_, let id, let offset) = request else { return .failure(code: "invalid", message: "") }
            asked.append((id, offset))
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            if let gate { await gate.wait() }
            if let failure { return failure }
            guard let data = images[id], offset < data.count else { return .failure(code: NativeImageCode.unknown, message: "gone") }
            let end = min(data.count, offset + chunk)
            let piece = NativeImageChunk(imageID: id, mimeType: "image/png", totalBytes: data.count, offset: offset, data: data[offset..<end])
            return .imageChunk(value: lie?(piece) ?? piece)
        }
    }

    /// A deliberately non-cancellable host answer: clients must return cancellation without
    /// waiting for transport completion. Tests release every continuation during cleanup.
    @MainActor final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        /// A test timeout cancels this await, not the simulated transport. Unblock that
        /// transport on timeout so the test can unwind and run its deferred cleanup.
        func result(of task: Task<NativeThreadImages.Outcome, Never>) async -> NativeThreadImages.Outcome {
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor in self.releaseAll() }
            }
        }

        func releaseFirst() { waiting.removeFirst().resume() }

        func releaseAll() {
            open = true
            let held = waiting
            waiting.removeAll()
            for continuation in held { continuation.resume() }
        }
    }

    /// Counts expose registration, not a notification. Yield only until that state is reached;
    /// the iteration bound diagnoses missing registration, never asserts a response speed.
    static func registered(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "\(description)")
    }

    static func ref(_ id: String, bytes: Int = png.count, side: Int = 100) -> NativeImageRef {
        NativeImageRef(id: id, mimeType: "image/png", width: side, height: side, byteCount: bytes)
    }

    static func store(_ host: Host, session: String = "s") -> NativeThreadImages {
        let images = NativeThreadImages()
        images.configure(sessionID: session, fetch: { try await host.answer($0) })
        return images
    }

    @Test func piecesInOrderBecomeTheWholeImage() async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        #expect(await images.image(Self.ref("a")) == .image(Self.png))
        #expect(host.asked.map(\.offset) == [0, NativeImage.chunkBytes, NativeImage.chunkBytes * 2], "700 KB is three pieces, each asked from where the last ended")
    }

    @Test func aFinishedImageIsKeptAndAskedForOnce() async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        _ = await images.image(Self.ref("a"))
        let before = host.asked.count
        #expect(await images.image(Self.ref("a")) == .image(Self.png))
        #expect(host.asked.count == before && images.cached("a") == Self.png)
    }

    @Test func manyAskersForOneImageShareOneFetch() async throws {
        let host = Host(["a": Self.png]), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        var entered = 0
        let askers = (0..<3).map { _ in Task { @MainActor in
            entered += 1
            return await images.image(Self.ref("a"))
        } }
        defer { for asker in askers { asker.cancel() }; gate.releaseAll(); images.cancelAll() }
        try await Self.registered("all askers joined the held fetch") { entered == 3 && host.active == 1 }
        gate.releaseAll()
        var results: [NativeThreadImages.Outcome] = []
        for asker in askers { results.append(await gate.result(of: asker)) }
        #expect(results.allSatisfy { $0 == .image(Self.png) })
        #expect(host.asked.filter { $0.offset == 0 }.count == 1, "one fetch, not three")
        #expect(images.started == 1)
    }

    @Test func cancellingStopsAskingForTheRest() async throws {
        let host = Host(["a": Self.png]), gate = Gate()
        host.chunk = 64 * 1024
        host.gate = gate
        let images = Self.store(host)
        let task = Task { await images.image(Self.ref("a")) }
        defer { task.cancel(); gate.releaseAll(); images.cancelAll() }
        try await Self.registered("the first chunk is held") { host.active == 1 }
        images.cancelAll()
        #expect(await gate.result(of: task) == .cancelled)
        #expect(host.active == 1, "cancellation returned before the host answered")
        gate.releaseAll()
        try await Self.registered("the cancelled host request drained") { host.active == 0 }
        #expect(host.asked.map(\.offset) == [0], "no more pieces after cancel")
        #expect(images.cached("a") == nil)
    }

    @Test func aNewSessionForgetsWhatTheOldOneHeld() async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        _ = await images.image(Self.ref("a"))
        #expect(images.heldBytes == Self.png.count)
        images.configure(sessionID: "other", fetch: { try await host.answer($0) })
        #expect(images.cached("a") == nil && images.heldBytes == 0, "an id belongs to its session")
    }

    @Test func theCacheIsBoundedAndDropsTheLeastRecentlyUsed() async {
        let big = Self.image(side: 100, bytes: 2_000_000)
        let host = Host(Dictionary(uniqueKeysWithValues: (0..<16).map { ("i\($0)", big) }))
        let images = Self.store(host)
        for i in 0..<16 {
            _ = await images.image(Self.ref("i\(i)", bytes: big.count))
            if i == 5 { _ = images.cached("i0") }
        }
        #expect(images.heldBytes <= NativeThreadImages.memoryLimit)
        #expect(images.cached("i15") != nil, "the newest stays")
        #expect(images.cached("i1") == nil, "the oldest untouched goes first")
    }

    // MARK: A host that answers wrongly is not believed

    @Test(arguments: [
        "a piece from another image", "a piece out of order", "an empty piece", "a piece bigger than allowed", "a type the thread does not offer",
        "a total over the limit", "a total that changes",
    ])
    func aWrongPieceEndsTheFetch(_ lie: String) async {
        let host = Host(["a": Self.png])
        host.lie = { piece in
            var p = piece
            switch lie {
            case "a piece from another image": p.imageID = "b"
            case "a piece out of order": if p.offset > 0 { p.offset += 1 }
            case "an empty piece": p.data = Data()
            case "a piece bigger than allowed": p.data = Data(count: NativeImage.chunkBytes + 1)
            case "a type the thread does not offer": p.mimeType = "text/html"
            case "a total over the limit": p.totalBytes = NativeImage.maxBytes + 1
            default: if p.offset > 0 { p.totalBytes += 7 }
            }
            return p
        }
        let images = Self.store(host)
        #expect(await images.image(Self.ref("a")) == .unavailable, "\(lie)")
        #expect(images.cached("a") == nil)
        #expect(host.asked.count <= 3, "it stops asking")
    }

    @Test func whatTheSnapshotAlreadyRulesOutIsNeverAsked() async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        #expect(await images.image(NativeImageRef(id: "a", mimeType: "image/svg+xml")) == .unavailable)
        #expect(await images.image(Self.ref("a", bytes: NativeImage.maxBytes + 1)) == .unavailable)
        #expect(await images.image(NativeImageRef(id: "a", mimeType: "image/png", width: 5000, height: 5000)) == .unavailable)
        #expect(host.asked.isEmpty)
    }

    @Test func aGoneImageIsUnavailableAndAStaleSessionIsAFailureToRetry() async {
        let host = Host([:])
        let images = Self.store(host)
        #expect(await images.image(Self.ref("a")) == .unavailable)
        host.failure = .failure(code: "stale_session", message: "Refresh the thread before acting.")
        if case .failed = await images.image(Self.ref("b")) {} else { Issue.record("a stale session should be a failure the viewer can retry") }
        struct Down: Error {}
        images.configure(sessionID: "s", fetch: { _ in throw Down() })
        if case .failed = await images.image(Self.ref("c")) {} else { Issue.record("a lost connection should be a failure the viewer can retry") }
    }

    @Test func noMoreThanTheLimitAreAskedForAtOnce() async throws {
        let host = Host(Dictionary(uniqueKeysWithValues: (0..<10).map { ("i\($0)", Self.image(side: 100)) })), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        let small = Self.image(side: 100)
        let tasks = (0..<10).map { i in Task { @MainActor in await images.image(Self.ref("i\(i)", bytes: small.count)) } }
        defer { for task in tasks { task.cancel() }; gate.releaseAll(); images.cancelAll() }
        try await Self.registered("the host is full and the other fetches queued") {
            host.active == NativeThreadImages.maxInFlight && images.queued == 10 - NativeThreadImages.maxInFlight
        }
        gate.releaseAll()
        for task in tasks { _ = await gate.result(of: task) }
        #expect(images.started == 10 && host.asked.count == 10, "every image arrived")
        #expect(host.peak == NativeThreadImages.maxInFlight, "four at a time: \(host.peak)")
    }

    // MARK: In a thread's store

    /// A store hands its images the session of the snapshot it holds, so an id from an old session is never asked for.
    @Test func aStoreConfiguresItsImagesFromItsSnapshot() async throws {
        let png = Self.png
        let host = Host(["a": png])
        let store = NativeThreadStore()
        let snapshot = NativeThreadSnapshot(piSessionID: "session-1", generation: "g", revision: 1, running: false,
                                            supportedActions: ["send", "images"], dialogsSupported: true, dialogs: [],
                                            messages: [NativeThreadMessage(entryID: "user:1", role: "user", blocks: [
                                                NativeThreadBlock(kind: .unsupportedImage, text: "", imageID: "a", mimeType: "image/png",
                                                                  width: 100, height: 100, byteCount: png.count)])],
                                            provisional: [], clipped: false)
        let polling = Task { await store.run(request: { request in
            if case .snapshot = request { return .snapshot(value: snapshot) }
            return try await host.answer(request)
        }) }
        defer { polling.cancel() }
        let ref = try #require(snapshot.messages.first?.blocks.first?.image)
        var outcome: NativeThreadImages.Outcome?
        for _ in 0..<100 where outcome == nil {
            try await Task.sleep(for: .milliseconds(20))
            if store.ready { outcome = await store.images.image(ref) }
        }
        #expect(outcome == .image(png))
        #expect(host.asked.allSatisfy { $0.id == "a" })
    }

    // MARK: Hostile or wrong metadata

    /// A ref the snapshot could never have honestly made is refused before one piece is asked for.
    @Test(arguments: [
        ("a negative width", -5, 100, 700_000), ("a negative height", 100, -5, 700_000), ("a zero width", 0, 100, 700_000),
        ("a product that overflows", Int.max, 2, 700_000), ("a product past the bound", 5000, 5000, 700_000),
        ("a width alone past the bound", 100_000_000, 1, 700_000), ("a negative byte count", 100, 100, -1), ("a zero byte count", 100, 100, 0),
        ("a byte count over the limit", 100, 100, NativeImage.maxBytes + 1), ("a byte count of Int.max", 100, 100, Int.max),
    ])
    func metadataThatCannotBeTrueIsRefusedUnasked(_ name: String, width: Int, height: Int, bytes: Int) async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        let ref = NativeImageRef(id: "a", mimeType: "image/png", width: width, height: height, byteCount: bytes)
        #expect(await images.image(ref) == .unavailable, "\(name)")
        #expect(host.asked.isEmpty, "\(name): nothing was asked for")
    }

    @Test func halfASizeIsRefused() async {
        let host = Host(["a": Self.png])
        let images = Self.store(host)
        #expect(await images.image(NativeImageRef(id: "a", mimeType: "image/png", width: 100, height: nil, byteCount: nil)) == .unavailable)
        #expect(host.asked.isEmpty)
    }

    /// What the host says of an image must be what the bytes are: the type, the size and the byte count, checked on the finished bytes
    /// before anything is cached or returned.
    @Test(arguments: [
        "bytes that are not an image", "a TIFF where png was promised", "a different width than promised", "a different byte count than promised",
        "a different type than the pieces' own header", "an image over the pixel bound in its header",
    ])
    func finishedBytesMustBeWhatWasPromised(_ lie: String) async {
        var served = Self.png
        var ref = Self.ref("a")
        switch lie {
        case "bytes that are not an image": served = Data(repeating: 7, count: 700_000)
        case "a TIFF where png was promised": served = Self.image(side: 100, bytes: 700_000, type: .tiff)
        case "a different width than promised": ref = Self.ref("a", side: 64)
        case "a different byte count than promised": ref = Self.ref("a", bytes: Self.png.count - 1)
        case "a different type than the pieces' own header": ref = NativeImageRef(id: "a", mimeType: "image/jpeg", width: 100, height: 100, byteCount: served.count)
        default: served = Self.image(side: 4100, bytes: 0)
        }
        let host = Host(["a": served])
        let images = Self.store(host)
        #expect(await images.image(ref) == .unavailable, "\(lie)")
        #expect(images.cached("a") == nil && images.heldBytes == 0, "\(lie): nothing was kept")
    }

    @Test func aTypeLabelThatChangesBetweenPiecesEndsTheFetch() async {
        let host = Host(["a": Self.png])
        host.lie = { piece in
            var p = piece
            if p.offset > 0 { p.mimeType = "image/jpeg" }
            return p
        }
        let images = Self.store(host)
        #expect(await images.image(Self.ref("a")) == .unavailable)
        #expect(images.cached("a") == nil)
    }

    // MARK: Cancellation

    /// An old fetch that is cancelled finishes later and must not remove a newer fetch's entry or fill the new session's cache.
    @Test func anOldCancelledFetchDoesNotClobberANewerOne() async throws {
        let host = Host(["a": Self.png]), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        let old = Task { await images.image(Self.ref("a")) }
        defer { old.cancel(); gate.releaseAll(); images.cancelAll() }
        try await Self.registered("the old request is held") { host.active == 1 }
        images.cancelAll()
        #expect(await gate.result(of: old) == .cancelled)
        let newer = Task { await images.image(Self.ref("a")) }
        defer { newer.cancel() }
        try await Self.registered("the newer request is held beside the old one") { host.active == 2 }
        gate.releaseFirst()
        try await Self.registered("the old request drained while the newer one is held") { host.active == 1 }
        #expect(images.inFlight == 1 && images.cached("a") == nil, "the old completion left the newer entry alone")
        gate.releaseAll()
        #expect(await gate.result(of: newer) == .image(Self.png) && images.cached("a") == Self.png)
    }

    @Test func aFetchFromTheOldSessionNeverFillsTheNewOnesCache() async throws {
        let host = Host(["a": Self.png]), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        let old = Task { await images.image(Self.ref("a")) }
        defer { old.cancel(); gate.releaseAll(); images.cancelAll() }
        try await Self.registered("the old session's request is held") { host.active == 1 }
        images.configure(sessionID: "next", fetch: { try await host.answer($0) })
        #expect(await gate.result(of: old) == .cancelled)
        #expect(host.active == 1, "the session switch did not await the host")
        gate.releaseAll()
        try await Self.registered("the old session's request drained") { host.active == 0 }
        #expect(images.cached("a") == nil && images.heldBytes == 0, "an id belongs to its session")
    }

    /// The fetch goes on while any asker still wants it, and stops when the last one has gone: cancelling one of two askers returns
    /// that one at once and leaves the other its image; cancelling the last stops the chunk loader.
    @Test func theFetchEndsWithItsLastAskerAndNotBefore() async throws {
        let host = Host(["a": Self.png, "b": Self.png]), gate = Gate()
        host.chunk = 64 * 1024
        host.gate = gate
        let images = Self.store(host)
        var entered = 0
        let askers = (0..<2).map { _ in Task { @MainActor in
            entered += 1
            return await images.image(Self.ref("a"))
        } }
        defer { for asker in askers { asker.cancel() }; host.gate?.releaseAll(); images.cancelAll() }
        try await Self.registered("both askers joined the held fetch") { entered == 2 && host.active == 1 }
        askers[0].cancel()
        #expect(await gate.result(of: askers[0]) == .cancelled)
        #expect(images.inFlight == 1 && host.active == 1, "the other asker still needs the held fetch")
        gate.releaseAll()
        #expect(await gate.result(of: askers[1]) == .image(Self.png), "and it gets the whole image")
        #expect(host.asked.filter { $0.offset == 0 }.count == 1, "one fetch served both")

        let loneGate = Gate()
        host.gate = loneGate
        let lone = Task { await images.image(Self.ref("b")) }
        defer { lone.cancel(); loneGate.releaseAll() }
        try await Self.registered("the lone asker's first chunk is held") { host.active == 1 }
        lone.cancel()
        #expect(await loneGate.result(of: lone) == .cancelled)
        #expect(host.active == 1, "the last asker returned before the host answered")
        loneGate.releaseAll()
        try await Self.registered("the lone host request drained") { host.active == 0 }
        #expect(host.asked.filter { $0.id == "b" }.map(\.offset) == [0], "the last asker left: no further chunks")
        #expect(images.inFlight == 0 && images.cached("b") == nil)
    }

    /// Nothing is left hanging: cancelled askers all return, with none left behind in the table.
    @Test func cancellingEveryAskerReturnsThemAllAndLeavesNothingBehind() async throws {
        let host = Host(["a": Self.png]), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        var entered = 0
        let askers = (0..<6).map { _ in Task { @MainActor in
            entered += 1
            return await images.image(Self.ref("a"))
        } }
        defer { for asker in askers { asker.cancel() }; gate.releaseAll(); images.cancelAll() }
        try await Self.registered("every asker joined the held fetch") { entered == 6 && host.active == 1 }
        for asker in askers { asker.cancel() }
        var outcomes: [NativeThreadImages.Outcome] = []
        for asker in askers { outcomes.append(await gate.result(of: asker)) }
        #expect(outcomes.count == 6 && outcomes.allSatisfy { $0 == .cancelled }, "every asker returned cancellation")
        #expect(host.active == 1, "all askers returned while the host was still held")
        gate.releaseAll()
        try await Self.registered("the shared cancelled host request drained") { host.active == 0 }
        #expect(host.asked.count == 1)
        #expect(images.inFlight == 0 && images.queued == 0)
    }

    /// Fetches queued behind the limit leave the line when cancelled, take no place, and do not wait for a running one to finish.
    @Test func aCancelledFetchInTheLineLeavesItAndNeverTakesAPlace() async throws {
        let ids = (0..<8).map { "i\($0)" }, small = Self.image(side: 100)
        let host = Host(Dictionary(uniqueKeysWithValues: ids.map { ($0, small) })), gate = Gate()
        host.gate = gate
        let images = Self.store(host)
        let askers = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, Task { await images.image(Self.ref(id, bytes: small.count)) })
        })
        defer { for asker in askers.values { asker.cancel() }; gate.releaseAll(); images.cancelAll() }
        try await Self.registered("four actual host requests are held and all other requests have registered in the queue") {
            host.active == NativeThreadImages.maxInFlight && images.inFlight == ids.count
                && images.queued == ids.count - NativeThreadImages.maxInFlight
        }
        // Executor scheduling need not match creation order: only recorded host calls identify
        // the active IDs. Everything else has registered in the queue above.
        let activeIDs = Set(host.asked.map(\.id))
        let queuedIDs = Set(ids).subtracting(activeIDs)
        try #require(activeIDs.count == NativeThreadImages.maxInFlight && queuedIDs.count == 4)
        for id in queuedIDs { askers[id]!.cancel() }
        for id in queuedIDs { #expect(await gate.result(of: askers[id]!) == .cancelled) }
        // The gate is still closed: completing the awaits above proves responsiveness without
        // depending on how much wall time a parallel Release run gave this test.
        #expect(host.active == NativeThreadImages.maxInFlight)
        try await Self.registered("cancelled loaders have left the admission queue") { images.queued == 0 }
        #expect(images.inFlight == activeIDs.count)
        gate.releaseAll()
        for id in activeIDs { #expect(await gate.result(of: askers[id]!) == .image(small)) }
        #expect(Set(host.asked.map(\.id)) == activeIDs && host.asked.count == activeIDs.count,
                "no cancelled queued ID reached the host, even after active fetches released their slots")
        #expect(images.inFlight == 0 && images.queued == 0)
    }
}
