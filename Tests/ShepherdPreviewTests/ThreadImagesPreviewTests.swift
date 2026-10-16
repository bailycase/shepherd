import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Thread images (ThreadImagesComposer, ThreadImageOpen) drawn from the real producers: the
/// composer's `ComposerAttachments` through `ComposerImageStrip`, and `ImageViewerState` through
/// `NWImageViewer`, in both appearances at text scale 1 and 1.3. The pictures are real PNGs the
/// test draws, so the thumbnails and the size labels come from bytes, not from board strings.
@Suite("Thread images previews", .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ThreadImagesPreviewTests {
    /// A tall phone-shaped picture, as bytes and as the image the chip decodes.
    static func attachment(_ name: String, bytes: Int, size: CGSize = CGSize(width: 117, height: 253)) -> ImageAttachment {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: rect.height - 36, width: 56, height: 12), xRadius: 3, yRadius: 3).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 14, width: rect.width - 20, height: 26), xRadius: 8, yRadius: 8).fill()
            return true
        }
        var data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        if data.count < bytes { data.append(Data(count: bytes - data.count)) }
        return ImageAttachment(name: name, image: NativeImage(mimeType: "image/png", data: data), thumbnail: Image(nsImage: image),
                               pixels: CGSize(width: 1170, height: 2532))
    }

    @Test(arguments: ["image", "empty", "long"])
    func pastedComposer(_ state: String) async throws {
        let fixture = ThreadFixture(Threads.idle)
        fixture.snapshot.messages = []
        fixture.snapshot.supportedActions.append("sendImages")
        defer { fixture.store.stop() }
        let input = ThreadInput()
        if state != "empty" {
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            let image = Self.attachment("clipboard.png", bytes: 0)
            clipboard.setData(image.image.data, forType: .png)
            let urls = await AppImageDrop.resolve(AppImageDrop.providers(from: clipboard))
            input.attachments.add(urls: urls)
            #expect(input.attachments.items.count == 1)
        }
        fixture.store.draft = state == "long" ? String(repeating: "Please compare this screenshot with the current checkout and explain the overlapping labels. ", count: 18)
            : state == "image" ? "Please fix the overlapping controls in this screenshot." : ""
        try await Preview.renderMatrix("composer-pasted-\(state)", size: CGSize(width: 760, height: 420), ready: { fixture.store.ready }) {
            ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request,
                       listModels: { .empty }, retainedInput: input)
        }
    }

    @Test(arguments: ["one", "two", "over", "long", "full"])
    func composerStrip(_ state: String) async throws {
        var attachments = ComposerAttachments()
        switch state {
        case "one": attachments.add([("after-mini.png", Self.attachment("after-mini.png", bytes: 1_400_000))])
        case "two": attachments.add([("after-mini.png", Self.attachment("after-mini.png", bytes: 1_400_000)),
                                     ("refunds-dashboard.png", Self.attachment("refunds-dashboard.png", bytes: 880_000))])
        case "over": attachments.add([("after-mini.png", Self.attachment("after-mini.png", bytes: 1_400_000)),
                                      ("after-promax.png", Self.attachment("after-promax.png", bytes: 3_100_000))])
        case "long":
            let name = "Screenshot 2026-10-13 at 3.02.41 PM — checkout totals card overlapping the pay button on iPhone 15 mini.png"
            attachments.add([(name, Self.attachment(name, bytes: 1_400_000))])
        case "full":
            attachments.add((1...5).map { ("shot-\($0).png", Self.attachment("shot-\($0).png", bytes: 600_000)) })
        default: break
        }
        try await Preview.renderMatrix("thread-images-composer-\(state)", size: CGSize(width: 760, height: 160)) {
            VStack(alignment: .leading, spacing: 0) {
                ComposerImageStrip(attachments: attachments, open: { _ in }, remove: { _ in })
                    .padding(NW.Space.l)
                Spacer(minLength: 0)
            }
            .frame(width: 760, height: 160, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: ["first", "second", "single", "failed", "loading"])
    func viewer(_ state: String) async throws {
        let images = [Self.attachment("checkout-iphone.png", bytes: 1_400_000), Self.attachment("refunds-dashboard.png", bytes: 880_000)]
            .map(ViewerImage.init)
        let viewer = ImageViewerState(images: state == "single" ? [images[0]] : images, origin: "Sent by you",
                                      addToMessage: { _ in })
        if state == "second" { viewer.next() }
        let image = try #require(viewer.current)
        let content: NWImageViewer.Content = switch state {
        case "failed": .failed("This image can't be shown.")
        case "loading": .loading
        default: image.picture.map { .picture(Image(nsImage: $0)) } ?? .failed("This image can't be shown.")
        }
        try await Preview.renderMatrix("thread-images-viewer-\(state)", size: CGSize(width: 1000, height: 700)) {
            NWImageViewer(name: image.name, facts: image.facts, position: viewer.position, content: content,
                          caption: "\(viewer.origin) · Esc to close",
                          previous: viewer.hasPrevious ? {} : nil, next: viewer.hasNext ? {} : nil,
                          copy: {}, addToMessage: {}, showInFinder: {}, close: {})
                .frame(width: 1000, height: 700)
        }
    }

    // MARK: In the thread (ThreadImagesSent, ThreadImagesReceived)

    /// A host holding real pictures by id, as the thread's store fetches them: nothing here is a board's string or a stand-in image.
    @MainActor final class Host {
        var images: [String: Data] = [:]
        var failing = false
        func answer(_ request: NativeThreadRequest) async throws -> NativeThreadResult {
            guard case .image(_, let id, let offset) = request else { return .failure(code: "invalid", message: "") }
            if failing { throw Down() }
            guard let data = images[id], offset < data.count else { return .failure(code: NativeImageCode.unknown, message: "gone") }
            let end = min(data.count, offset + NativeImage.chunkBytes)
            return .imageChunk(value: NativeImageChunk(imageID: id, mimeType: "image/png", totalBytes: data.count, offset: offset, data: data[offset..<end]))
        }
        struct Down: Error {}
    }

    static func picture(_ size: CGSize, tint: NSColor, dark: Bool = false) -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill(); rect.fill()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 14, y: 14, width: rect.width - 28, height: 34), xRadius: 10, yRadius: 10).fill()
            NSColor.systemRed.withAlphaComponent(dark ? 0.9 : 0.0).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: rect.height * 0.55, width: rect.width, height: 22)).fill()
            NSColor(white: dark ? 0.7 : 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 14, y: rect.height - 40, width: rect.width * 0.4, height: 14), xRadius: 4, yRadius: 4).fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    /// One turn the way the thread draws it: a sent message with its thumbnails, then the agent's images where they came, and a web image's chip.
    struct Turn: View {
        let sent: [NativeImageRef]
        let made: [NativeImageRef]
        let images: NativeThreadImages
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                // The real user turn: its thumbnails, its bubble and the neutral count under it (ThreadImagesSent).
                UserTurn(bubbles: [UserTurn.Bubble(text: "The pay button jumps when the keyboard opens, and the totals card overlaps on small phones.",
                                                   images: sent.count, caption: "3:02 PM", pending: false, imageRefs: sent)], hover: MessageHover(hovering: true))
                if !made.isEmpty {
                    Text("Refunds doubled on Tuesday because the retry job re-sent 412 webhooks after a deploy.").font(.nw(.body))
                    // What the agent turn draws for an `images` item: the neutral count, then the pictures (ThreadImagesReceived).
                    VStack(alignment: .leading, spacing: NW.Space.m) {
                        NWActivityLine(kind: .images, label: nativeCount(made.count, "image"), meta: "")
                        ReceivedImages(refs: made)
                    }
                }
            }
            .environment(\.threadImages, images)
            .frame(width: 820, alignment: .leading)
            .padding(24)
            .background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: ["sent", "received", "both", "failed", "loading", "many", "gone"])
    func transcript(_ state: String) async throws {
        let host = Host()
        host.images = ["s0": Self.picture(CGSize(width: 117, height: 253), tint: .systemBlue), "s1": Self.picture(CGSize(width: 240, height: 150), tint: .systemGray),
                       "r0": Self.picture(CGSize(width: 384, height: 240), tint: .systemBlue), "r1": Self.picture(CGSize(width: 384, height: 240), tint: .systemRed, dark: true)]
        // Each ref says what its bytes are (type, pixels, byte count), as the host's snapshot would: the client checks them against the pieces.
        func ref(_ id: String) -> NativeImageRef {
            let data = host.images[id] ?? Data()
            let rep = NSBitmapImageRep(data: data)
            return NativeImageRef(id: id, mimeType: "image/png", width: rep?.pixelsWide ?? 1, height: rep?.pixelsHigh ?? 1, byteCount: max(1, data.count))
        }
        let refs = ["s0", "s1", "r0", "r1"].map(ref)
        if state == "gone" { host.images["r1"] = nil }
        if state == "failed" { host.failing = true }
        let images = NativeThreadImages()
        images.configure(sessionID: "s", fetch: state == "loading" ? { _ in try await Task.sleep(for: .seconds(60)); return .failure(code: "x", message: "") }
                                                                  : { try await host.answer($0) })
        let sent = state == "received" ? [] : (state == "many" ? Array(refs[0..<2]) + [refs[0], refs[1]] : Array(refs[0..<2]))
        let made = state == "sent" ? [] : Array(refs[2..<4])
        // Each thumbnail asks for its picture as it comes on screen; the render waits for the asking to settle (or not, for loading).
        try await Preview.renderMatrix("thread-images-transcript-\(state)", size: CGSize(width: 880, height: 640), ready: {
            state == "loading" || state == "failed" ? true : images.heldBytes > 0 || state == "gone"
        }) {
            Turn(sent: sent.enumerated().map { NativeImageRef(id: "\($0.element.id)", mimeType: $0.element.mimeType, width: $0.element.width,
                                                               height: $0.element.height, byteCount: $0.element.byteCount) }, made: made, images: images)
                .frame(width: 880, height: 640, alignment: .topLeading)
        }
    }

    // MARK: The viewer over the real thread (ThreadImageOpen)

    /// A real PNG of `width` × `height` pixels shaped like a phone screen or a dashboard, small on disk.
    static func screen(_ width: Int, _ height: Int, accent: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.965, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        let w = CGFloat(width), h = CGFloat(height)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: w * 0.07, y: h * 0.9, width: w * 0.35, height: h * 0.03), xRadius: 8, yRadius: 8).fill()
        NSColor.white.setFill(); NSColor(white: 0.88, alpha: 1).setStroke()
        for box in [NSRect(x: w * 0.07, y: h * 0.62, width: w * 0.86, height: h * 0.2), NSRect(x: w * 0.07, y: h * 0.38, width: w * 0.86, height: h * 0.16)] {
            let path = NSBezierPath(roundedRect: box, xRadius: 24, yRadius: 24); path.fill(); path.lineWidth = 3; path.stroke()
        }
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: w * 0.07, y: h * 0.06, width: w * 0.86, height: h * 0.07), xRadius: 40, yRadius: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// A live thread (the stub pi, its history seeded from a file) whose first message carries two images, in a real window; the viewer opens over it.
    /// `fetch` replaces the host's answers for the loading and failed states.
    @MainActor
    func viewerOverThread(_ name: String, open index: Int, images count: Int = 2, size: CGSize = CGSize(width: 1440, height: 900),
                          fetch: ((@MainActor (NativeThreadRequest) async throws -> NativeThreadResult))? = nil) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let first = Self.screen(1170, 2532, accent: .systemBlue), second = Self.screen(2880, 1800, accent: .systemRed)
        let history = workspace.dir.appendingPathComponent("history.json")
        let message: [String: Any] = ["role": "user", "timestamp": 1_733_234_567_890, "content":
            [["type": "text", "text": "The pay button jumps when the keyboard opens, and the totals card overlaps on small phones. Both screenshots are from an iPhone 15 mini."]]
            + [first, second].prefix(count).map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/png"] as [String: Any] }]
        let reply: [String: Any] = ["role": "assistant", "timestamp": 1_733_234_567_891, "stopReason": "stop",
                                    "content": [["type": "text", "text": "I can see it in the first screenshot: the totals card is pinned with a fixed height of 180, so on the mini it runs under the pay button."]]]
        try JSONSerialization.data(withJSONObject: [message, reply]).write(to: history)
        let space = Space(name: "payments", path: workspace.dir.path)
        let session = try await workspace.server.createSession(params: CreateSessionParams(
            cwd: workspace.dir.path, command: StubPi.command, env: ["STUB_PI_MESSAGES_FILE": history.path], runtime: .rpc))
        let id = AgentID()
        let pane = LeafPane(sessionID: session.id, cwd: space.path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "Fix the checkout layout on iPhone", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .done, nameIsFinal: true)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = workspace.vm
        vm.selectAgent(id)
        let store = vm.threadStores.store(for: id)
        // `Preview.renderMatrix` mounts the real window; its `ready` hook waits for the thread to name its images, and the viewer opens then.
        var opened = false
        try await Preview.renderMatrix(name, size: size, ready: {
            guard store.ready, let row = store.messages.first(where: { $0.blocks.contains { $0.image != nil } }) else { return false }
            if !opened {
                opened = true
                let refs = row.blocks.compactMap(\.image)
                if let fetch { store.images.configure(sessionID: store.snapshot?.piSessionID, fetch: fetch) }
                let set = ThreadImageSet(refs: refs, names: refs.indices.map { "Image \($0 + 1)" }, origin: "Sent by you")
                vm.imageViewer = ImageViewerState(set: set, index: index, images: store.images, addToMessage: { _ in })
            }
            if fetch != nil { return true }
            return vm.imageViewer?.current != nil
        }) {
            RootView(vm: vm)
        }
        let row = try #require(store.messages.first { $0.blocks.contains { $0.image != nil } })
        #expect(row.blocks.compactMap(\.image).count == count, "the thread named the images it was seeded with")
    }

    @Test func viewerOverTheThreadFirst() async throws { try await viewerOverThread("thread-images-open-first", open: 0) }
    @Test func viewerOverTheThreadSecond() async throws { try await viewerOverThread("thread-images-open-second", open: 1) }
    @Test func viewerOverTheThreadOneImage() async throws { try await viewerOverThread("thread-images-open-single", open: 0, images: 1) }

    /// The bar's content is one centred column after the window controls, not the window's corners: a wide landscape window
    /// (2000 × 844), and a narrow one (760 × 700) whose sidebar is hidden, so the window controls sit over the bar and the labelled
    /// buttons give way to icons, in light and dark and at 1.3.
    @Test func viewerBarInAWideAndANarrowWindow() async throws {
        try await viewerOverThread("thread-images-open-wide", open: 0, size: CGSize(width: 2000, height: 844))
        try await viewerOverThread("thread-images-open-narrow", open: 0, size: CGSize(width: 760, height: 700))
    }

    struct HostDown: Error {}
    @Test func viewerOverTheThreadWhileLoading() async throws {
        try await viewerOverThread("thread-images-open-loading", open: 0) { _ in try await Task.sleep(for: .seconds(120)); return .failure(code: "x", message: "") }
    }
    @Test func viewerOverTheThreadWhenItCouldNotLoad() async throws {
        try await viewerOverThread("thread-images-open-failed", open: 0) { _ in throw HostDown() }
    }
}
