import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Thread images (ThreadImagesComposer, ThreadImageOpen) pressed the way VoiceOver presses them, in
/// a window that is never shown: a chip's thumbnail opens the viewer, its x removes the image,
/// and the viewer's ‹ › Copy, Add to message, Show in Finder and close each do what they say. Each
/// scenario runs in its own process for the accessibility tree (`ControlPress`).
@Suite("Thread images, controls", .mainActorExclusive, .integrationTimeLimit)
struct ThreadImagesControlTests {
    @Test func theChipsThumbnailOpensTheViewerAndItsXRemovesTheImage() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.chips() }
        }
        expectScenarioCompleted(result)
    }

    @Test func theViewerStepsCopiesAddsAndCloses() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.viewing() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aThreadThumbnailOpensTheViewerOnItsMessageAndStepsThroughStoredImages() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.thumbnails() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aFailedThumbnailRetriesAndAGoneImageIsAChip() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.failing() }
        }
        expectScenarioCompleted(result)
    }

    /// The viewer over the whole window (ThreadImageOpen), measured against the board and pressed as VoiceOver presses it: a 44pt bar with a 28pt close
    /// circle, 36pt ‹ › with the one that has nowhere to go disabled, and every control at least the Mac's 24pt.
    @Test func theViewerOverTheWindowHasTheBoardsBarAndControls() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.measuring() }
        }
        expectScenarioCompleted(result)
    }

    // MARK: Fixtures

    @MainActor
    static func attachment(_ name: String, bytes: Int, source: URL? = nil) -> ImageAttachment {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        // The bytes decode; the size on the chip is the count asked for.
        var data = png
        if data.count < bytes { data.append(Data(count: bytes - data.count)) }
        return ImageAttachment(name: name, image: NativeImage(mimeType: "image/png", data: data),
                               thumbnail: Image(nsImage: image), source: source, pixels: CGSize(width: 1170, height: 2532))
    }

    // MARK: Scenarios

    @MainActor
    static func chips() async throws {
        AccessibilityNode.enable()
        var attachments = ComposerAttachments()
        attachments.add([("after-mini.png", attachment("after-mini.png", bytes: 1_400_000)),
                         ("after-promax.png", attachment("after-promax.png", bytes: 3_100_000))])
        var opened: [String] = []
        var removed: [UUID] = []
        let strip = ComposerImageStrip(attachments: attachments, open: { opened.append($0.name) }, remove: { removed.append($0) })
        let window = OffscreenWindow(size: CGSize(width: 820, height: 160), dark: true, strip)
        defer { window.close() }
        // Both chips name themselves and their size; the one over the limit says so, and so does the line under them.
        let labels = window.controls().compactMap(\.label)
        #expect(labels.contains("Open after-mini.png") && labels.contains("Open after-promax.png"), "\(labels)")
        #expect(labels.contains("Remove after-mini.png") && labels.contains("Remove after-promax.png"))
        #expect(attachments.error == "after-promax.png is over 2 MB after resizing. Remove it or send a smaller one.")
        try window.press("Open after-promax.png")
        try window.press("Remove after-mini.png")
        #expect(opened == ["after-promax.png"])
        #expect(removed == [attachments.items[0].id])
        // Every control is at least the Mac's 24pt hit area.
        let small = ControlPress.undersized(window.controls(), minimum: .desktop)
        #expect(small.isEmpty, "undersized: \(small)")
    }

    @MainActor
    static func viewing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        var added: [String] = []
        // Finder and the pasteboard are never touched: the viewer's requests are recorded.
        var revealed: [URL] = []
        var copied: [NSImage] = []
        vm.imageViewerActions = ImageViewerActions(reveal: { revealed.append($0) }, copy: { copied.append($0) })
        let shown = [attachment("checkout-iphone.png", bytes: 1_400_000, source: URL(fileURLWithPath: "/tmp/checkout-iphone.png")),
                     attachment("refunds-dashboard.png", bytes: 2_000)]
        vm.imageViewer = ImageViewerState(images: shown.map(ViewerImage.init), origin: "Sent by you", addToMessage: { added.append($0.name) })
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, ImageViewerOverlay(vm: vm))
        defer { window.close() }
        let state = try #require(vm.imageViewer)
        let labels = window.controls().compactMap(\.label)
        #expect(labels.contains("Next image") && labels.contains("Previous image"), "both arrows are drawn: \(labels)")
        #expect(throws: ControlPressError.self, "the first image's ‹ is drawn disabled, so it takes no press") { try window.press("Previous image") }
        try window.press("Next image")
        try await eventuallyOnMain("the second image") { state.current?.name == "refunds-dashboard.png" }
        try window.press("Previous image")
        try await eventuallyOnMain("the first image again") { state.current?.name == "checkout-iphone.png" }
        // Copy asks for the shown picture; Show in Finder asks for the file it came from.
        try window.press("Copy")
        #expect(copied.count == 1, "Copy asked to copy the picture")
        try window.press("Show in Finder")
        #expect(revealed == [URL(fileURLWithPath: "/tmp/checkout-iphone.png")], "Show in Finder asked to reveal the file: \(revealed)")
        try window.press("Next image")
        try await eventuallyOnMain("the second image") { state.current?.name == "refunds-dashboard.png" }
        #expect(!window.controls().contains { $0.label == "Show in Finder" }, "an image with no file offers no Show in Finder")
        try window.press("Previous image")
        try await eventuallyOnMain("the first image again") { state.current?.name == "checkout-iphone.png" }
        try window.press("Add to message")
        try await eventuallyOnMain("the viewer to close after Add to message") { vm.imageViewer == nil }
        #expect(added == ["checkout-iphone.png"])
        // Close.
        vm.imageViewer = ImageViewerState(images: shown.map(ViewerImage.init), origin: "Sent by you")
        try await eventuallyOnMain("the viewer to open again") { window.controls().contains { $0.label == "Close" } }
        #expect(!window.controls().contains { $0.label == "Add to message" }, "no Add to message where there is nowhere to add")
        try window.press("Close")
        try await eventuallyOnMain("the viewer to close") { vm.imageViewer == nil }
    }

    // MARK: Stored images

    struct ConnectionLost: Error {}

    /// A host holding `images` by id, answering a thread's image requests a piece at a time.
    @MainActor final class Host {
        var images: [String: Data]
        var asked = 0
        var failing = false
        init(_ images: [String: Data]) { self.images = images }
        func answer(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .image(_, let id, let offset) = request else { return .failure(code: "invalid", message: "") }
            asked += 1
            if failing { throw ConnectionLost() }
            guard let data = images[id], offset < data.count else { return .failure(code: NativeImageCode.unknown, message: "gone") }
            let end = min(data.count, offset + NativeImage.chunkBytes)
            return .imageChunk(value: NativeImageChunk(imageID: id, mimeType: "image/png", totalBytes: data.count, offset: offset, data: data[offset..<end]))
        }
    }

    @MainActor
    static func png(_ color: NSColor, side: Int = 24) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in color.setFill(); rect.fill(); return true }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    @MainActor
    static func thumbnails() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let first = png(.systemBlue), second = png(.systemOrange, side: 40)
        let host = Host(["u|0|aaaaaaaaaaaaaaaa": first, "u|1|bbbbbbbbbbbbbbbb": second])
        let images = NativeThreadImages()
        images.configure(sessionID: "s", fetch: { try await host.answer($0) })
        var copied: [NSImage] = []
        vm.imageViewerActions = ImageViewerActions(reveal: { _ in }, copy: { copied.append($0) })
        // What the snapshot would say of these bytes: their real type, size and byte count.
        let refs = [NativeImageRef(id: "u|0|aaaaaaaaaaaaaaaa", mimeType: "image/png", width: 24, height: 24, byteCount: first.count),
                    NativeImageRef(id: "u|1|bbbbbbbbbbbbbbbb", mimeType: "image/png", width: 40, height: 40, byteCount: second.count)]
        // The thread: two thumbnails, as a sent message draws them; pressing one opens the viewer on both, at that one.
        let thread = SentImages(refs: refs, names: ["checkout-iphone.png", "refunds-dashboard.png"], origin: "Sent by you")
            .environment(\.threadImages, images)
            .environment(\.viewImages, ThreadImageOpener { set, index in
                vm.imageViewer = ImageViewerState(set: set, index: index, images: images, addToMessage: nil)
            })
        let window = OffscreenWindow(size: CGSize(width: 600, height: 300), dark: true,
                                     ZStack { thread; ImageViewerOverlay(vm: vm) })
        defer { window.close() }
        try await eventuallyOnMain("both thumbnails to load") { window.controls().contains { $0.label == "Open refunds-dashboard.png, 40 by 40" } }
        #expect(host.asked == 2, "each image was asked for once")
        try window.press("Open refunds-dashboard.png, 40 by 40")
        let state = try #require(vm.imageViewer)
        try await eventuallyOnMain("the viewer on the second image") { state.current?.name == "refunds-dashboard.png" }
        #expect(state.position == "2 of 2" && state.hasPrevious && !state.hasNext)
        try await eventuallyOnMain("the viewer's bar") { window.controls().contains { $0.label == "Previous image" } }
        try window.press("Previous image")
        try await eventuallyOnMain("the first image") { state.current?.name == "checkout-iphone.png" }
        #expect(host.asked == 2, "stepping used what was already fetched")
        try window.press("Copy")
        #expect(copied.count == 1)
        try window.press("Close")
        try await eventuallyOnMain("the viewer to close") { vm.imageViewer == nil }
        let small = ControlPress.undersized(window.controls(), minimum: .desktop)
        #expect(small.isEmpty, "undersized: \(small)")
    }

    @MainActor
    static func failing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let teal = png(.systemTeal)
        let host = Host(["a": teal])
        host.failing = true
        let images = NativeThreadImages()
        images.configure(sessionID: "s", fetch: { try await host.answer($0) })
        let ref = NativeImageRef(id: "a", mimeType: "image/png", width: 24, height: 24, byteCount: teal.count)
        let gone = NativeImageRef(id: "missing", mimeType: "image/png", width: 24, height: 24, byteCount: teal.count)
        let thread = HStack {
            ReceivedImages(refs: [ref])
            ThreadImageThumb(ref: gone, name: "chart.png", size: CGSize(width: 80, height: 80), open: {})
        }
        .environment(\.threadImages, images)
        let window = OffscreenWindow(size: CGSize(width: 700, height: 320), dark: true, ZStack { thread; ImageViewerOverlay(vm: vm) })
        defer { window.close() }
        // The connection is down: the thumbnail says so and offers Retry; the host comes back and Retry fetches it.
        try await eventuallyOnMain("the failed thumbnail") { window.controls().contains { $0.label == "Retry loading Image 1" } }
        host.failing = false
        try window.press("Retry loading Image 1")
        try await eventuallyOnMain("the picture after Retry") { window.controls().contains { $0.label?.hasPrefix("Open Image 1") == true } }
        // Both thumbnails failed on the dropped connection. The second is an image the host no longer has: Retry asks again, the host
        // answers "not here", and the thread draws the chip, not an error to retry forever.
        try window.press("Retry loading chart.png")
        // An image the host no longer has is the chip, named and said to be gone: never a broken box or a spinner that does not end.
        // A chip that opens nothing is text, not a control: it is in the accessibility tree, not among the controls.
        let labels = { AccessibilityNode.all(under: window.host).compactMap(\.label) }
        try await eventuallyOnMain("the gone image's chip") { labels().contains { $0.contains("chart.png") && $0.contains("not available") } }
        #expect(!labels().contains("Loading chart.png") && !window.controls().contains { $0.label?.contains("chart.png") == true },
                "no spinner left behind, and no control that opens nothing")
    }

    @MainActor
    static func measuring() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let shown = [attachment("checkout-iphone.png", bytes: 1_400_000, source: URL(fileURLWithPath: "/tmp/checkout-iphone.png")),
                     attachment("refunds-dashboard.png", bytes: 2_000)]
        vm.imageViewerActions = ImageViewerActions(reveal: { _ in }, copy: { _ in })
        vm.imageViewer = ImageViewerState(images: shown.map(ViewerImage.init), origin: "Sent by you", addToMessage: { _ in })
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, ImageViewerOverlay(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the bar") { window.controls().contains { $0.label == "Close" } }
        let controls = window.controls()
        func control(_ label: String) throws -> Control { try #require(controls.first { $0.label == label }, "\(label)") }
        let frame = window.window.frame
        // The board's own numbers, written out (not read from the metrics under test): a 44pt bar, a 28pt close circle, 36pt arrows.
        // The bar is 44pt: its buttons and the close circle sit inside it, vertically centred.
        let close = try control("Close"), copy = try control("Copy")
        #expect(abs(close.frame.width - 28) < 1 && abs(close.frame.height - 28) < 1,
                "the close circle is 28pt: \(close.frame)")
        let barTop = frame.maxY
        #expect(abs((barTop - close.frame.midY) - 44 / 2) < 1, "the close circle is centred in a 44pt bar: \(close.frame) in \(frame)")
        #expect(abs((barTop - copy.frame.midY) - 44 / 2) < 1, "Copy is centred in the same bar")
        #expect(close.frame.maxX <= frame.maxX - NW.Space.l + 1 && close.frame.maxX >= frame.maxX - NW.Space.l - 1, "12pt from the window's edge")
        // ‹ › are 36pt discs, centred in the window's height between the bar and the footer; ‹ is disabled on the first image.
        let next = try control("Next image")
        #expect(abs(next.frame.width - 36) < 1 && abs(next.frame.height - 36) < 1, "\(next.frame)")
        let previous = try control("Previous image")
        #expect(!previous.isEnabled && next.isEnabled, "the first image's ‹ is drawn and disabled")
        // Every control is at least the Mac's 24pt, and each does what it says.
        let small = ControlPress.undersized(controls.filter { $0.isEnabled }, minimum: .desktop)
        #expect(small.isEmpty, "undersized: \(small)")
        for label in ["Copy", "Show in Finder", "Add to message"] { _ = try control(label) }
        try window.press("Next image")
        let state = try #require(vm.imageViewer)
        try await eventuallyOnMain("the second image") { state.current?.name == "refunds-dashboard.png" }
        try await eventuallyOnMain("the arrows swap") { window.controls().first { $0.label == "Next image" }?.isEnabled == false }
        #expect(window.controls().first { $0.label == "Previous image" }?.isEnabled == true)
    }
}
