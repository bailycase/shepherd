import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// The ThreadImage boards (ThreadImageOpen, ThreadImagesComposer, ThreadImagesReceived, ThreadImagesSent), in light and dark and
/// at text scale 1.3, drawn from the real producers: the store sends the images through the composer's own path and its echo
/// carries them, the agent's reply is Markdown naming files in its folder, and the composer holds `ImageAttachment`s read the
/// way a drop reads them.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter ThreadImagesPreviewTests
@Suite("Thread images previews", .mainActorExclusive)
@MainActor
struct ThreadImagesPreviewTests {
    static let size = CGSize(width: 1440, height: 900)

    // MARK: Pictures

    /// A phone screenshot as the boards draw one: pale page, two cards, a blue pay button.
    static func phone(width: Int = 1170, height: Int = 2532) -> Data {
        picture(width, height) { w, h in
            fill(NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1), CGRect(x: 0, y: 0, width: w, height: h))
            let s = w / 117
            for (y, tall) in [(30, 60), (100, 44)] {
                fill(.white, CGRect(x: 8 * s, y: h - (y + tall) * s, width: 101 * s, height: tall * s))
            }
            fill(NSColor(srgbRed: 0.18, green: 0.435, blue: 0.87, alpha: 1), CGRect(x: 8 * s, y: h - 238 * s, width: 101 * s, height: 22 * s))
        }
    }

    static func dashboard(width: Int = 2880, height: Int = 1800) -> Data {
        picture(width, height) { w, h in
            fill(NSColor(srgbRed: 0.965, green: 0.965, blue: 0.957, alpha: 1), CGRect(x: 0, y: 0, width: w, height: h))
            fill(NSColor(srgbRed: 0.925, green: 0.925, blue: 0.918, alpha: 1), CGRect(x: 0, y: 0, width: w / 5, height: h))
            for column in 0..<3 {
                fill(column == 2 ? NSColor(srgbRed: 0.85, green: 0.23, blue: 0.23, alpha: 1) : .white,
                     CGRect(x: w / 4 + column * w / 4, y: h - h / 3, width: w / 5, height: h / 6))
            }
            fill(.white, CGRect(x: w / 4, y: h / 10, width: w * 7 / 10, height: h / 2))
        }
    }

    static func chart(width: Int = 1600, height: Int = 1000) -> Data {
        picture(width, height) { w, h in
            fill(.white, CGRect(x: 0, y: 0, width: w, height: h))
            let line = NSBezierPath()
            line.lineWidth = CGFloat(h) / 70
            line.move(to: CGPoint(x: w / 12, y: h / 3))
            for step in 1...8 { line.line(to: CGPoint(x: w / 12 + step * w * 10 / 12 / 8, y: h / 3 + step * h / 14)) }
            NSColor(srgbRed: 0.18, green: 0.435, blue: 0.87, alpha: 1).setStroke()
            line.stroke()
        }
    }

    static func log(width: Int = 1440, height: Int = 900) -> Data {
        picture(width, height) { w, h in
            fill(NSColor(srgbRed: 0.11, green: 0.115, blue: 0.13, alpha: 1), CGRect(x: 0, y: 0, width: w, height: h))
            fill(NSColor(srgbRed: 0.28, green: 0.12, blue: 0.13, alpha: 1), CGRect(x: 0, y: h / 2, width: w, height: h / 14))
        }
    }

    private static func fill(_ color: NSColor, _ rect: CGRect) {
        color.setFill()
        rect.fill()
    }

    static func picture(_ width: Int, _ height: Int, _ draw: (Int, Int) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(width, height)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Harness

    /// A thread on a store that sends the way the app does, and a host that takes images. Everything the thread draws about a
    /// send comes from `store.send(images:)`.
    @MainActor final class Harness {
        let store = NativeThreadStore()
        let input = ThreadInput()
        let viewer = ImageViewerModel()
        let thumbnails = SentImageThumbnails()
        /// True: a local agent, whose files are on this Mac; false draws a remote agent's.
        var local = true
        let commands = ThreadCommandCenter()
        var snapshot: NativeThreadSnapshot
        let folder: URL
        let title: String
        private var running: Task<Void, Never>?

        init(_ snapshot: NativeThreadSnapshot, folder: URL, title: String) {
            self.snapshot = snapshot
            self.snapshot.supportedActions.append("sendImages")
            self.folder = folder
            self.title = title
        }

        deinit { running?.cancel() }

        var request: NativeThreadStore.Request {
            { [weak self] value in
                guard let self else { return .failure(code: "gone", message: "released") }
                if case .send(_, _, let operation, _, _, _, _, _, _) = value { return .accepted(operationID: operation) }
                return .snapshot(value: self.snapshot)
            }
        }

        func thread() -> some View {
            VStack(spacing: 0) {
                ThreadHeader(store: store, project: "payments", title: title)
                ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "preview", agentName: "Fix checkout",
                           workingDirectory: folder.path, review: { _ in }, allowsLocalFiles: local, retainedInput: input, retainedViewer: viewer)
            }
            .environment(\.threadCommands, commands)
            // The window's layer, over the header and the thread together, as RootView puts it over the workspace column.
            .modifier(ImageViewerLayer(model: viewer))
        }

        /// Runs the store against the host, as the app's thread does; the preview's thread needs it running too.
        func start() {
            guard running == nil else { return }
            running = Task { [store, request] in await store.run(request: request) }
        }

        /// Sends as the composer does and waits until the thread has the echo.
        func send(_ text: String, images: [NativeImage]) async throws {
            start()
            try await eventuallyOnMain("the thread to load") { self.store.ready }
            store.draft = text
            #expect(await store.send(images: images, delivery: .followUp))
        }
    }

    static func harness(messages: [NativeThreadMessage] = [], title: String? = nil) throws -> Harness {
        let folder = try makeScratchDirectory("images")
        return Harness(ActivityThreads.snapshot(messages), folder: folder, title: title ?? "Fix the checkout layout on iPhone")
    }

    static func sentImages() -> [NativeImage] {
        [NativeImage(mimeType: "image/png", data: phone(), name: "checkout-iphone.png"),
         NativeImage(mimeType: "image/png", data: dashboard(), name: "refunds-dashboard.png")]
    }

    private static let t0 = ActivityThreads.now - 3 * 60_000

    // MARK: Boards

    /// ThreadImagesSent: two screenshots above the bubble that carries their words, a reply under it.
    @Test func imagesSent() async throws {
        let h = try Self.harness(messages: [
            ActivityThreads.assistant("a0", "Which screenshots do you have?", at: Self.t0),
        ])
        try await h.send("The pay button jumps when the keyboard opens, and the totals card overlaps on small phones. Both screenshots are from an iPhone 15 mini.",
                         images: Self.sentImages())
        try await Preview.renderMatrix("thread-images-sent", size: Self.size, ready: { h.store.ready && !h.store.rows.isEmpty }) { h.thread() }
    }

    /// Four images, one with a long name, sent without words: the group wraps within 560pt and there is no empty bubble.
    @Test func imagesSentFourWithoutWords() async throws {
        let h = try Self.harness()
        let name = "screenshot-of-the-checkout-after-the-keyboard-inset-fix-on-a-real-device-iphone-15-mini-portrait.png"
        let images = [NativeImage(mimeType: "image/png", data: Self.phone(), name: name),
                      NativeImage(mimeType: "image/png", data: Self.dashboard(), name: "refunds-dashboard.png"),
                      NativeImage(mimeType: "image/png", data: Self.phone(width: 600, height: 600), name: "square.png"),
                      NativeImage(mimeType: "image/png", data: Self.dashboard(width: 60, height: 30), name: "tiny.png")]
        try await h.send("", images: images)
        try await Preview.renderMatrix("thread-images-sent-four", size: Self.size, ready: { h.store.ready && !h.store.rows.isEmpty }) { h.thread() }
    }

    /// ThreadImagesReceived: the agent's reply names two files in its folder with captions and a web image.
    @Test func imagesReceived() async throws {
        let h = try Self.harness(title: "Why did refunds spike on Tuesday?")
        h.start()
        try Self.chart().write(to: h.folder.appendingPathComponent("refund-rate.png"))
        try Self.log().write(to: h.folder.appendingPathComponent("console-error.png"))
        let reply = """
        Refunds doubled on Tuesday because the retry job re-sent 412 webhooks after a deploy. Here is the daily rate against last month, and the error the job logged.

        ![Daily refund rate, this month (blue) against last month.](refund-rate.png)
        ![The retry job's error at 09:14, from the server log.](console-error.png)
        ![grafana.internal/d/refunds.png](https://grafana.internal/d/refunds.png)

        The chart and the log are in the thread's files. The Grafana image is a web link, so Shepherd shows it as a link and never loads it.
        """
        h.snapshot = ActivityThreads.snapshot([
            ActivityThreads.user("u1", "Why did refunds spike on Tuesday? Show me what you find.", at: Self.t0),
            ActivityThreads.assistant("a1", reply, at: Self.t0 + 20_000),
        ])
        let chart = h.folder.appendingPathComponent("refund-rate.png"), log = h.folder.appendingPathComponent("console-error.png")
        try await Preview.renderMatrix("thread-images-received", size: Self.size,
                                       ready: { h.store.ready && !h.store.rows.isEmpty && NWProseThumbnails.cached(chart) != nil && NWProseThumbnails.cached(log) != nil }) {
            h.thread()
        }
    }

    /// A remote host's agent names an image at a path that exists here too (a scratch file with the same name): Shepherd must
    /// not draw this Mac's file. It is a chip, like every image of an agent whose files are not on this device.
    @Test func imagesReceivedRemoteAgentNeverReadsThisMacsFile() async throws {
        let h = try Self.harness(title: "Why did refunds spike on Tuesday?")
        h.local = false
        h.start()
        let url = h.folder.appendingPathComponent("refund-rate.png")
        try Self.chart().write(to: url)
        h.snapshot = ActivityThreads.snapshot([
            ActivityThreads.user("u1", "Show me.", at: Self.t0),
            ActivityThreads.assistant("a1", "Here it is.\n\n![Daily refund rate](refund-rate.png)\n![Same, absolute](\(url.path))", at: Self.t0 + 20_000),
        ])
        try await Preview.render("thread-images-received-remote", size: CGSize(width: 1180, height: 600),
                                 ready: { h.store.ready && !h.store.rows.isEmpty }) { h.thread() }
        #expect(NWProseThumbnails.cached(url) == nil, "this Mac's file was never decoded for a remote agent")
    }

    /// ThreadImagesSent's reply: "Looked at 2 images" above "Explored 4 files", from `read` results that carry the picture (what
    /// pi sends for an image file), under the message that sent them.
    @Test func imagesLookedAt() async throws {
        func read(_ id: String, _ path: String, image: Bool, at: Double) -> NativeThreadMessage {
            var message = ActivityThreads.tool(id, "read", ["path": path], output: image ? "Read image file [image/png]" : "1 line", start: at, end: at + 200)
            if image { message.blocks.append(NativeThreadBlock(kind: .unsupportedImage, text: "[Image unavailable in native thread]")) }
            return message
        }
        let h = try Self.harness(messages: [
            ActivityThreads.user("u1", "The pay button jumps when the keyboard opens, and the totals card overlaps on small phones. Both screenshots are from an iPhone 15 mini.", at: Self.t0),
            read("r1", "checkout-iphone.png", image: true, at: Self.t0 + 1_000),
            read("r2", "refunds-dashboard.png", image: true, at: Self.t0 + 2_000),
            read("r3", "CheckoutView.swift", image: false, at: Self.t0 + 3_000),
            read("r4", "TotalsCard.swift", image: false, at: Self.t0 + 4_000),
            ActivityThreads.assistant("a1", "I can see it in the first screenshot: the totals card is pinned with a fixed height of 180, so on the mini it runs under the pay button. The second one shows the refunds table cut off at the right edge.", at: Self.t0 + 20_000),
        ])
        h.start()
        try await Preview.renderMatrix("thread-images-looked-at", size: CGSize(width: 1180, height: 700), ready: { h.store.ready && !h.store.rows.isEmpty }) { h.thread() }
    }

    /// ThreadImageOpen in the whole app (RootView, sidebar, window controls), not a thread alone: the viewer's toolbar sits in a
    /// bounded column under the title bar, clear of the window controls, at a wide landscape window (2000×844, where the
    /// controls once stuck to the corners), the board's 1440×900, and a narrow window whose sidebar is hidden (the controls
    /// then sit over the column). Opened from files the way the thread's thumbnails open them.
    @Test(arguments: [("wide", CGSize(width: 2000, height: 844)), ("board", CGSize(width: 1440, height: 900)), ("narrow", CGSize(width: 760, height: 700))])
    func imageViewerInTheWholeWindow(_ name: String, _ size: CGSize) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let space = Space(name: "payments", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Review attached images", in: space, order: 0, live: true, cwd: workspace.dir.path)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        vm.selectAgent(agent.id)
        let store = vm.threadStores.store(for: agent.id)
        let files = [("checkout-iphone-with-a-rather-long-name-for-the-toolbar.png", Self.phone(width: 585, height: 1266)),
                     ("refunds-dashboard.png", Self.dashboard())].map { name, data -> URL in
            let url = workspace.dir.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
        vm.imageViewer.open(files: files, at: 0)
        try await Preview.renderMatrix("thread-image-viewer-window-\(name)", size: size, ready: { store.ready && vm.imageViewer.pictures.count == 2 }) { RootView(vm: vm) }
        vm.imageViewer.close()
    }

    /// An image the agent names that is not on this Mac: a chip, never a hole.
    @Test func imagesReceivedMissingFile() async throws {
        let h = try Self.harness(title: "Why did refunds spike on Tuesday?")
        h.start()
        h.snapshot = ActivityThreads.snapshot([
            ActivityThreads.user("u1", "Show me.", at: Self.t0),
            ActivityThreads.assistant("a1", "Here it is.\n\n![Gone](missing/after-the-deploy.png)", at: Self.t0 + 20_000),
        ])
        try await Preview.render("thread-images-received-missing", size: CGSize(width: 1180, height: 600), ready: { h.store.ready && !h.store.rows.isEmpty }) { h.thread() }
    }

    /// ThreadImagesComposer: one image fine, one over 2 MB after resizing, the line that says how to fix it. The images are
    /// `ImageAttachment`s as a drop makes them, so the sizes on the chips come from the bytes.
    @Test func imagesComposer() async throws {
        let h = try Self.harness(messages: [
            ActivityThreads.user("u1", "The pay button jumps when the keyboard opens.", at: Self.t0),
            ActivityThreads.assistant("a1", "The jump comes from the keyboard inset being applied twice. Can you send the screen after the fix on a real device?", at: Self.t0 + 20_000),
        ])
        let mini = NativeImage(mimeType: "image/png", data: Self.padded(Self.phone(width: 585, height: 1266), to: 1_468_006), name: "after-mini.png")
        let promax = NativeImage(mimeType: "image/png", data: Self.padded(Self.phone(width: 585, height: 1266), to: 3_250_586), name: "after-promax.png")
        h.input.attachments.add([("after-mini.png", ImageAttachment(name: "after-mini.png", image: mini, thumbnail: Self.thumbnail(mini.data))),
                                 ("after-promax.png", ImageAttachment(name: "after-promax.png", image: promax, thumbnail: Self.thumbnail(promax.data)))])
        try await Preview.renderMatrix("thread-images-composer", size: Self.size,
                                       ready: { h.store.ready && !h.store.rows.isEmpty && { h.store.draft = "Here it is on the mini and the Pro Max."; return true }() }) {
            h.thread()
        }
    }

    /// ThreadImageOpen: the sent images open at full size over the thread, the first of two.
    @Test func imageOpen() async throws {
        let h = try Self.harness(messages: [ActivityThreads.assistant("a0", "Which screenshots do you have?", at: Self.t0)])
        try await h.send("The pay button jumps when the keyboard opens, and the totals card overlaps on small phones. Both screenshots are from an iPhone 15 mini.",
                         images: Self.sentImages())
        var opened = false
        try await Preview.renderMatrix("thread-image-open", size: Self.size, ready: {
            guard h.store.ready, !h.store.rows.isEmpty else { return false }
            if !opened, let bubble = h.store.turns.last(where: \.isUser)?.bubbles.last, let id = bubble.operationID {
                let images = h.thumbnails.images(for: id, in: h.store)
                guard images.count == 2 else { return false }
                opened = true
                // Through the launcher a thumbnail uses, so the viewer reads the bytes from the store as it does in the app.
                h.viewer.open(images.map(\.entry), at: 0, context: .init(sentBytes: { [store = h.store] operation, index in
                    let kept = store.queuedImages(operation)
                    return kept.indices.contains(index) ? kept[index] : nil
                }))
            }
            return opened && h.viewer.pictures[h.viewer.current?.id ?? ""] != nil
        }) { h.thread() }
    }

    // MARK: Helpers

    /// A PNG padded (in a trailing ancillary chunk's worth of bytes) to `count`, so a chip can read a realistic size.
    static func padded(_ png: Data, to count: Int) -> Data {
        var data = png
        if data.count < count { data.append(Data(count: count - data.count)) }
        return data
    }

    static func thumbnail(_ data: Data) -> Image? { NSImage(data: data).map { Image(nsImage: $0) } }
}
