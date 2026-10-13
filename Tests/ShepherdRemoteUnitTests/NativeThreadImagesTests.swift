import AppKit
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The client's image fetching (`NativeThreadImages`): pieces in order into one image, a cache that is bounded, one fetch for many
/// askers, fetches that stop when the thread leaves, and a host that answers wrongly is not believed.
@MainActor
@Suite("Thread image fetching")
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
        var delay: Duration?
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
            if let delay { try await Task.sleep(for: delay) }
            if let failure { return failure }
            guard let data = images[id], offset < data.count else { return .failure(code: NativeImageCode.unknown, message: "gone") }
            let end = min(data.count, offset + chunk)
            let piece = NativeImageChunk(imageID: id, mimeType: "image/png", totalBytes: data.count, offset: offset, data: data[offset..<end])
            return .imageChunk(value: lie?(piece) ?? piece)
        }
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

    @Test func manyAskersForOneImageShareOneFetch() async {
        let host = Host(["a": Self.png])
        host.delay = .milliseconds(30)
        let images = Self.store(host)
        async let one = images.image(Self.ref("a"))
        async let two = images.image(Self.ref("a"))
        async let three = images.image(Self.ref("a"))
        let results = await [one, two, three]
        #expect(results.allSatisfy { $0 == .image(Self.png) })
        #expect(host.asked.filter { $0.offset == 0 }.count == 1, "one fetch, not three")
        #expect(images.started == 1)
    }

    @Test func cancellingStopsAskingForTheRest() async {
        let host = Host(["a": Self.png])
        host.chunk = 64 * 1024
        host.delay = .milliseconds(40)
        let images = Self.store(host)
        let task = Task { await images.image(Self.ref("a")) }
        try? await Task.sleep(for: .milliseconds(90))
        images.cancelAll()
        let outcome = await task.value
        let askedWhenStopped = host.asked.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(host.asked.count <= askedWhenStopped + 1, "no more pieces after cancel")
        #expect(host.asked.count < 11, "it did not run to the end: \(host.asked.count)")
        #expect(images.cached("a") == nil)
        if case .image = outcome { Issue.record("a cancelled fetch gave an image") }
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

    @Test func noMoreThanTheLimitAreAskedForAtOnce() async {
        let host = Host(Dictionary(uniqueKeysWithValues: (0..<10).map { ("i\($0)", Self.image(side: 100)) }))
        host.delay = .milliseconds(30)
        let images = Self.store(host)
        let small = Self.image(side: 100)
        let tasks = (0..<10).map { i in Task { @MainActor in await images.image(Self.ref("i\(i)", bytes: small.count)) } }
        for task in tasks { _ = await task.value }
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
    @Test func anOldCancelledFetchDoesNotClobberANewerOne() async {
        let host = Host(["a": Self.png])
        host.delay = .milliseconds(60)
        let images = Self.store(host)
        let old = Task { await images.image(Self.ref("a")) }
        try? await Task.sleep(for: .milliseconds(20))
        images.cancelAll()
        _ = await old.value
        let newer = Task { await images.image(Self.ref("a")) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(images.inFlight == 1, "the newer fetch is registered")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await newer.value == .image(Self.png) && images.cached("a") == Self.png)
    }

    @Test func aFetchFromTheOldSessionNeverFillsTheNewOnesCache() async {
        let host = Host(["a": Self.png])
        host.delay = .milliseconds(50)
        let images = Self.store(host)
        let old = Task { await images.image(Self.ref("a")) }
        try? await Task.sleep(for: .milliseconds(20))
        images.configure(sessionID: "next", fetch: { try await host.answer($0) })
        _ = await old.value
        try? await Task.sleep(for: .milliseconds(200))
        #expect(images.cached("a") == nil && images.heldBytes == 0, "an id belongs to its session")
    }

    /// The fetch goes on while any asker still wants it, and stops when the last one has gone: cancelling one of two askers returns
    /// that one at once and leaves the other its image; cancelling the last stops the chunk loader.
    @Test func theFetchEndsWithItsLastAskerAndNotBefore() async {
        let host = Host(["a": Self.png])
        host.chunk = 64 * 1024
        host.delay = .milliseconds(30)
        let images = Self.store(host)
        let first = Task { await images.image(Self.ref("a")) }
        let second = Task { await images.image(Self.ref("a")) }
        try? await Task.sleep(for: .milliseconds(70))
        first.cancel()
        let early = await first.value
        if case .image = early { Issue.record("a cancelled asker was given an image") }
        #expect(images.inFlight == 1, "the other asker still needs it")
        #expect(await second.value == .image(Self.png), "and it gets the whole image")
        #expect(host.asked.filter { $0.offset == 0 }.count == 1, "one fetch served both")

        let lone = Task { await images.image(Self.ref("b")) }
        let host2 = host
        host2.images["b"] = Self.png
        try? await Task.sleep(for: .milliseconds(70))
        lone.cancel()
        _ = await lone.value
        let asked = host.asked.count
        try? await Task.sleep(for: .milliseconds(250))
        #expect(host.asked.count <= asked + 1, "the last asker left: the loader stopped asking")
        #expect(images.inFlight == 0 && images.cached("b") == nil)
    }

    /// Nothing is left hanging: cancelled askers all return, with none left behind in the table.
    @Test func cancellingEveryAskerReturnsThemAllAndLeavesNothingBehind() async {
        let host = Host(["a": Self.png])
        host.delay = .milliseconds(200)
        let images = Self.store(host)
        let askers = (0..<6).map { _ in Task { await images.image(Self.ref("a")) } }
        try? await Task.sleep(for: .milliseconds(30))
        for asker in askers { asker.cancel() }
        let outcomes = await withTaskGroup(of: NativeThreadImages.Outcome.self) { group in
            for asker in askers { group.addTask { await asker.value } }
            var all: [NativeThreadImages.Outcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        #expect(outcomes.count == 6, "every asker returned")
        #expect(images.inFlight == 0 && images.queued == 0)
    }

    /// Fetches queued behind the limit leave the line when cancelled, take no place, and do not wait for a running one to finish.
    @Test func aCancelledFetchInTheLineLeavesItAndNeverTakesAPlace() async {
        let ids = (0..<8).map { "i\($0)" }
        let host = Host(Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.image(side: 100)) }))
        host.delay = .milliseconds(300)
        let images = Self.store(host)
        let small = Self.image(side: 100).count
        let askers = ids.map { id in Task { await images.image(Self.ref(id, bytes: small)) } }
        // Wait for the state itself, not for a time: four fetches running and the other four in the line.
        for _ in 0..<200 where !(images.started == NativeThreadImages.maxInFlight && images.queued == 8 - NativeThreadImages.maxInFlight) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(images.inFlight == 8 && images.queued == 8 - NativeThreadImages.maxInFlight, "four run, the rest wait: inFlight \(images.inFlight) queued \(images.queued) asked \(host.asked.count) started \(images.started)")
        let waiting = Array(askers[NativeThreadImages.maxInFlight...])
        let started = Date()
        for asker in waiting { asker.cancel() }
        for asker in waiting { _ = await asker.value }
        #expect(Date().timeIntervalSince(started) < 0.25, "the queued ones returned without waiting for a running fetch to finish")
        #expect(images.queued == 0, "the line is empty")
        for asker in askers[0..<NativeThreadImages.maxInFlight] { _ = await asker.value }
        #expect(host.asked.count == NativeThreadImages.maxInFlight, "a cancelled queued fetch never asked the host: \(host.asked.count)")
        #expect(images.inFlight == 0)
    }
}
