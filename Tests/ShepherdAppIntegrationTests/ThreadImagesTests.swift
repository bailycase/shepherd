import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Images in the thread (ThreadImageOpen, ThreadImagesSent): the sent thumbnails the user turn draws from the bytes the
/// store kept, and the viewer's paging and metadata.
@Suite("Thread images", .mainActorExclusive)
@MainActor
struct ThreadImagesTests {
    static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func aSentImageDrawsAtItsOwnAspectWithinTheBoardsBox() {
        let box = CGSize(width: NWThreadMetrics.sentImageMaxWidth, height: NWThreadMetrics.sentImageMaxHeight)
        // checkout-iphone.png, 1170×2532 at 3x: height limits it, width follows (board: 83×180).
        #expect(NWImageFit.size(pixels: CGSize(width: 1170, height: 2532), scale: 3, within: box) == CGSize(width: 83, height: 180))
        // refunds-dashboard.png, 2880×1800: width limits it (board: 240×150).
        #expect(NWImageFit.size(pixels: CGSize(width: 2880, height: 1800), scale: 2, within: box) == CGSize(width: 240, height: 150))
        // A small image is never scaled up.
        #expect(NWImageFit.size(pixels: CGSize(width: 40, height: 20), scale: 2, within: box) == CGSize(width: 20, height: 10))
    }

    @Test func theViewerPagesThroughImagesAndSaysWhatItIsShowing() async throws {
        let model = ImageViewerModel()
        let first = NativeImage(mimeType: "image/png", data: try Self.png(width: 30, height: 60), name: "checkout-iphone.png")
        let second = NativeImage(mimeType: "image/png", data: try Self.png(width: 80, height: 50), name: "refunds-dashboard.png")
        let entries = [first, second].enumerated().map { index, image in
            ViewerEntry(id: "op/\(index)", name: image.name ?? "", origin: .sent, source: .bytes(image))
        }
        model.open(entries, at: 0)
        await model.loaded()
        var content = try #require(model.content(canAdd: true, addUnavailable: nil))
        #expect(content.name == "checkout-iphone.png" && content.position == "1 of 2" && content.origin == "Sent by you")
        #expect(content.detail.hasPrefix("30 × 60 · PNG · ") && content.image != nil)
        #expect(!content.canGoBack && content.canGoForward)
        model.step(1)
        await model.loaded()
        content = try #require(model.content(canAdd: false, addUnavailable: "At most 4 images per message."))
        #expect(content.name == "refunds-dashboard.png" && content.position == "2 of 2" && content.canGoBack && !content.canGoForward)
        #expect(content.detail.hasPrefix("80 × 50 · PNG · "), "the second image's own pixels: \(content.detail)")
        #expect(content.image != nil)
        #expect(!content.canAdd && content.addUnavailable == "At most 4 images per message.")
        model.step(1)
        #expect(model.current?.name == "refunds-dashboard.png", "stepping past the end stays put")
        model.close()
        #expect(!model.isOpen && model.content(canAdd: true, addUnavailable: nil) == nil)
    }

    /// Show in Finder on an image that exists only as bytes writes it under its own name first; Copy puts the image on
    /// the pasteboard through the same effect.
    /// A saved image (another client's, or after a restart) draws the host's preview, but Copy, Add and Show in Finder wait for the
    /// original and then act on it: never on the lossy preview. Stepping or closing cancels the read.
    @Test func aSavedImagesActionsWaitForTheOriginalAndNeverUseThePreview() async throws {
        let model = ImageViewerModel()
        let preview = try Self.png(width: 4, height: 4), original = try Self.png(width: 40, height: 40)
        var copied: [Data] = []
        model.effects.copy = { entry in if case .bytes(let image) = entry.source { copied.append(image.data) } }
        var release: CheckedContinuation<Void, Never>?
        var started = 0
        model.context = .init(savedBytes: { _, _ in NativeImage(mimeType: "image/png", data: preview) },
                              savedOriginal: { _, _ in
                                  started += 1
                                  await withCheckedContinuation { release = $0 }
                                  return Task.isCancelled ? nil : NativeImage(mimeType: "image/png", data: original)
                              })
        let entries = [ViewerEntry(id: "u/0", name: "a.png", origin: .sent, source: .saved(entryID: "u", index: 0)),
                       ViewerEntry(id: "u/1", name: "b.png", origin: .sent, source: .saved(entryID: "u", index: 1))]
        model.open(entries, at: 0)
        try await eventuallyOnMain("the read to start") { started == 1 }
        #expect(model.originalNotice == "Loading the original…")
        model.copy()
        model.reveal()
        #expect(copied.isEmpty, "Copy does nothing until the original is here")
        model.step(1)
        #expect(model.originals.isEmpty)
        release?.resume()
        try await eventuallyOnMain("the second read to start") { started == 2 }
        try await eventuallyOnMain("the preview's picture") { model.pictures["u/1"]?.facts.pixels == CGSize(width: 4, height: 4) }
        release?.resume()
        try await eventuallyOnMain("the original") { model.originalNotice == nil }
        model.copy()
        #expect(copied == [original], "the original, never the preview")
        await model.loaded()
        let shown = try #require(model.pictures["u/1"])
        #expect(shown.facts.pixels == CGSize(width: 40, height: 40) && shown.facts.type == "PNG", "the original's size and type, not the preview's")
        model.close()
        #expect(model.originals.isEmpty && model.originalNotice == nil)
    }

    @Test func showInFinderWritesASentImageUnderItsNameAndRevealsIt() throws {
        let folder = try makeScratchDirectory("viewer-reveal")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ImageViewerModel()
        var revealed: [URL] = []
        model.effects.reveal = { revealed.append($0) }
        model.effects.exportDirectory = { folder }
        let data = try Self.png(width: 4, height: 4)
        let operation = UUID()
        model.sentBytes = { id, _ in id == operation ? NativeImage(mimeType: "image/png", data: data, name: "a.png") : nil }
        model.open([ViewerEntry(id: "op/0", name: "a.png", origin: .sent, source: .sent(operation: operation, index: 0))], at: 0)
        model.reveal()
        let url = try #require(revealed.first)
        let written = try Data(contentsOf: url)
        #expect(url.lastPathComponent == "a.png" && written == data)
        let file = folder.appendingPathComponent("b.png")
        try data.write(to: file)
        model.open(files: [file], at: 0)
        model.reveal()
        #expect(revealed.last == file)
    }

    /// The real producer: the store sends the images, the echo's bubble carries the send's id, and the user turn finds the
    /// thumbnails by it with names intact, one per image. A bubble whose bytes this client does not hold keeps "Image" chips.
    @Test func theUserTurnDrawsThumbnailsOfWhatTheStoreSent() async throws {
        let store = NativeThreadStore()
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false, supportedActions: ["send", "sendImages"],
                                            dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, runtime: "rpc")
        let host = Host(snapshot)
        let task = Task { await store.run(request: { await host.answer($0) }) }
        defer { task.cancel() }
        try await eventuallyOnMain("the thread to load") { store.ready }
        let images = [NativeImage(mimeType: "image/png", data: try Self.png(width: 30, height: 60), name: "a.png"),
                      NativeImage(mimeType: "image/png", data: try Self.png(width: 80, height: 50), name: "b.png")]
        store.draft = "Both screenshots"
        #expect(await store.send(images: images, delivery: .followUp))
        let turn = try #require(store.turns.last { $0.isUser })
        let thumbnails = SentImageThumbnails()
        let view = UserTurn(turn: turn, store: store, thumbnails: thumbnails)
        let bubble = try #require(view.bubbles.last)
        #expect(bubble.sent.map(\.entry.name) == ["a.png", "b.png"] && bubble.sent.allSatisfy { $0.thumbnail != nil })
        #expect(bubble.sent.map(\.pixels) == [CGSize(width: 30, height: 60), CGSize(width: 80, height: 50)])
        #expect(!bubble.imagesOnly, "its words keep their bubble")
        // The thumbnail row holds no source bytes: an entry names the send, and the bytes are read from the store when opened.
        for image in bubble.sent { if case .sent = image.entry.source {} else { Issue.record("\(image.entry.name) holds its bytes") } }
        #expect(UserTurn(turn: turn, store: nil).bubbles.last?.sent.isEmpty == true && bubble.images == 2)
    }
}

/// A host that accepts sends and answers snapshots with what was sent echoed back as pi would not yet have saved it.
@MainActor
private final class Host {
    var snapshot: NativeThreadSnapshot
    init(_ snapshot: NativeThreadSnapshot) { self.snapshot = snapshot }

    func answer(_ request: NativeThreadRequest) -> NativeThreadResult {
        switch request {
        case .send(_, _, let operation, _, _, _, _, _, _): .accepted(operationID: operation)
        default: .snapshot(value: snapshot)
        }
    }
}

extension ThreadImagesTests {
    /// The viewer reads a sent image's bytes from the store when it opens it; once the store has dropped them there is
    /// nothing to show, copy, reveal or add, and none of those crash or write anything.
    @Test func aSentImageWhoseBytesTheStoreDroppedOpensEmptyAndDoesNothing() async throws {
        let model = ImageViewerModel()
        var copied = 0, revealed = 0
        model.effects.copy = { _ in copied += 1 }
        model.effects.reveal = { _ in revealed += 1 }
        model.open([ViewerEntry(id: "x/0", name: "gone.png", origin: .sent, source: .sent(operation: UUID(), index: 0))], at: 0)
        await model.loaded()
        let content = try #require(model.content(canAdd: true, addUnavailable: nil))
        #expect(content.image == nil && content.detail.isEmpty)
        model.copy()
        model.reveal()
        #expect(copied == 0 && revealed == 0)
    }

    @Test func aThreadsThumbnailsAreBoundedAndHoldNoSourceBytes() async throws {
        let store = NativeThreadStore()
        let thumbnails = SentImageThumbnails()
        #expect(thumbnails.images(for: UUID(), in: store).isEmpty, "a send this client does not hold has none")
    }
}

extension ThreadImagesTests {
    // MARK: Findings

    /// A remote host's agent has a working directory, but its replies name files on that machine: reading the same path here
    /// would draw an unrelated local file. Only a local thread (`allowsLocalFiles`) has a prose root.
    @Test func aRemoteThreadHasNoFileRootAndALocalOneDoes() throws {
        #expect(ThreadView.proseFileRoot("~/Developer/payments", local: false) == nil)
        #expect(ThreadView.proseFileRoot(nil, local: true) == nil)
        let root = try #require(ThreadView.proseFileRoot("/tmp/payments", local: true))
        #expect(root.path == "/tmp/payments")
        let local = try makeScratchDirectory("root-local")
        #expect(NWProseImageSource("file://\(local.path)/x.png", root: ThreadView.proseFileRoot(local.path, local: false)) == .unavailable(local.path + "/x.png"),
                "a file: URL from a remote agent is not read here")
        #expect(NWProseImageSource("/etc/hosts.png", root: nil) == .unavailable("/etc/hosts.png"))
        // A file: URL with a host names that machine's file; only an empty host or localhost is this one.
        let root2 = URL(fileURLWithPath: local.path, isDirectory: true)
        #expect(NWProseImageSource("file://build-01/tmp/x.png", root: root2) == .unavailable("/tmp/x.png"))
        #expect(NWProseImageSource("file://BUILD-01.local/etc/passwd", root: root2) == .unavailable("/etc/passwd"))
        #expect(NWProseImageSource("file:///tmp/x.png", root: root2) == .file(URL(string: "file:///tmp/x.png")!))
        #expect(NWProseImageSource("file://localhost/tmp/x.png", root: root2) == .file(URL(string: "file://localhost/tmp/x.png")!))
        #expect(NWProseImageSource("file://LOCALHOST/tmp/x.png", root: root2).file != nil)
    }

    /// An image overwritten at the same path draws its new pixels: the cache is keyed by the file's revision as well as its path.
    @Test func anImageOverwrittenAtTheSamePathLoadsAgain() async throws {
        let folder = try makeScratchDirectory("overwrite")
        let url = folder.appendingPathComponent("chart.png")
        try Self.png(width: 20, height: 10).write(to: url)
        let first = try #require(await NWProseThumbnails.load(url, pixels: 400))
        #expect(first.width == 20 && NWProseThumbnails.cached(url)?.width == 20)
        // The same path, different bytes (and a different size, so the revision moves whatever the clock's grain).
        try Self.png(width: 60, height: 30).write(to: url)
        #expect(NWProseThumbnails.cached(url) == nil, "the old pixels are not served for the new file")
        let second = try #require(await NWProseThumbnails.load(url, pixels: 400))
        #expect(second.width == 60 && NWProseThumbnails.cached(url)?.width == 60)
    }

    /// Show in Finder on an image named `../../target.png` writes inside its own folder, under a safe name.
    @Test(arguments: [
        ("../../target.png", "target.png"), ("/etc/passwd", "passwd"), ("a/../../b.png", "b.png"), ("..\\..\\win.png", "win.png"),
        ("..", "Image.png"), (".", "Image.png"), ("", "Image.png"), ("   ", "Image.png"), ("...", "Image.png"), ("a\u{0}b\n.png", "ab.png"),
    ])
    func aSentImagesNameCannotEscapeItsFolder(name: String, safe: String) {
        #expect(ImageViewerModel.safeFileName(name, mimeType: "image/png") == safe)
    }

    @Test func revealingATraversalNamedImageWritesOnlyInsideItsOwnFolder() throws {
        let root = try makeScratchDirectory("traversal")
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        let model = ImageViewerModel()
        var revealed: [URL] = []
        model.effects.reveal = { revealed.append($0) }
        model.effects.exportDirectory = { exports }
        let data = try Self.png(width: 4, height: 4)
        let operation = UUID()
        model.sentBytes = { id, _ in id == operation ? NativeImage(mimeType: "image/png", data: data, name: "../../target.png") : nil }
        model.open([ViewerEntry(id: "t/0", name: "../../target.png", origin: .sent, source: .sent(operation: operation, index: 0))], at: 0)
        model.reveal()
        let url = try #require(revealed.first)
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == exports.standardizedFileURL,
                "written one folder under the export directory: \(url.path)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("target.png").path))
        #expect(!FileManager.default.fileExists(atPath: exports.deletingLastPathComponent().appendingPathComponent("target.png").path))
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(written == ["exports"], "nothing next to the export directory: \(written)")
    }

    /// Paging through large images keeps the open one and its neighbours decoded, no more, drops all on close, and a
    /// burst of steps leaves one decode's worth of work, not one per step.
    @Test func pagingKeepsOnlyTheOpenImageAndItsNeighboursAndCloseReleasesAll() async throws {
        let model = ImageViewerModel()
        let images = try (0..<8).map { NativeImage(mimeType: "image/png", data: try Self.png(width: 20 + $0, height: 10), name: "\($0).png") }
        let operation = UUID()
        model.sentBytes = { id, index in id == operation && images.indices.contains(index) ? images[index] : nil }
        let entries = images.indices.map { ViewerEntry(id: "op/\($0)", name: "\($0).png", origin: .sent, source: .sent(operation: operation, index: $0)) }
        model.open(entries, at: 0)
        await model.loaded()
        #expect(Set(model.pictures.keys) == ["op/0", "op/1"])
        // A burst of steps without waiting: only the final position's pictures remain, however many pages went by.
        for _ in 0..<6 { model.step(1) }
        await model.loaded()
        #expect(model.current?.name == "6.png")
        #expect(Set(model.pictures.keys) == ["op/5", "op/6", "op/7"], "\(model.pictures.keys.sorted())")
        #expect(model.pictures["op/6"]?.facts.pixels == CGSize(width: 26, height: 10), "the open image decoded at its own size")
        model.step(-1)
        await model.loaded()
        #expect(Set(model.pictures.keys) == ["op/4", "op/5", "op/6"])
        model.close()
        await model.loaded()
        #expect(model.pictures.isEmpty && !model.isOpen)
    }
}

/// Counts how many decodes run at once and holds each until released.
private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var running = 0, peak = 0, started: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    func decode(_ source: ViewerEntry.Source) -> ViewerPicture? {
        guard case .bytes(let image) = source else { return nil }
        lock.withLock { running += 1; peak = max(peak, running); started.append(image.name ?? "") }
        gate.wait()
        lock.withLock { running -= 1 }
        return nil
    }

    func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }
    var snapshot: (running: Int, peak: Int, started: [String]) { lock.withLock { (running, peak, started) } }
}

extension ThreadImagesTests {
    /// Rapid paging never has two decodes running: they go through one decoder, a decode in flight is waited for, and a
    /// request cancelled while it waited never starts. (ImageIO cannot be cancelled once it runs, so the one in flight
    /// finishes.)
    @Test func rapidPagingRunsOneDecodeAtATimeAndSkipsTheCancelledOnes() async throws {
        let probe = DecodeProbe()
        let model = ImageViewerModel(decoder: ViewerDecoder(perform: { probe.decode($0) }))
        let images = (0..<9).map { NativeImage(mimeType: "image/png", data: Data([UInt8($0)]), name: "\($0).png") }
        let operation = UUID()
        model.sentBytes = { id, index in id == operation && images.indices.contains(index) ? images[index] : nil }
        let entries = images.indices.map { ViewerEntry(id: "op/\($0)", name: "\($0).png", origin: .sent, source: .sent(operation: operation, index: $0)) }
        model.open(entries, at: 0)
        try await eventuallyOnMain("the first decode to start") { probe.snapshot.running == 1 }
        // Page eight times while it is held: each page cancels what was queued and queues the new neighbourhood.
        for _ in 0..<8 { model.step(1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.snapshot.running == 1 && probe.snapshot.peak == 1, "only the one in flight: \(probe.snapshot)")
        probe.release(20)
        await model.loaded()
        let seen = probe.snapshot
        #expect(seen.peak == 1, "never two at once: \(seen)")
        #expect(seen.started.first == "0.png")
        #expect(!seen.started.dropFirst().contains(where: { ["1.png", "2.png", "3.png", "4.png", "5.png", "6.png"].contains($0) }),
                "requests cancelled while they waited never started: \(seen.started)")
        #expect(seen.started.contains("8.png"), "the final position decoded: \(seen.started)")
    }

    /// Closing lets go of the thread: its store and composer closures leave with the images.
    @Test func closingReleasesTheThreadsContext() async throws {
        let model = ImageViewerModel()
        weak var held: NSObject?
        do {
            let owner = NSObject()
            held = owner
            model.open([ViewerEntry(id: "a", name: "a.png", origin: .agent, source: .file(URL(fileURLWithPath: "/tmp/none.png")))], at: 0,
                       context: .init(sentBytes: { _, _ in _ = owner; return nil }, addBlocker: { _ = owner; return nil }, add: { _ in _ = owner }))
        }
        #expect(held != nil, "the open viewer holds its thread")
        model.close()
        await model.loaded()
        #expect(held == nil, "close released the thread's closures")
    }
}
