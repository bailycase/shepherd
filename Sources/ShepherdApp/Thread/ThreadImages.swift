import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Images in a thread (ThreadImageOpen, ThreadImagesSent, ThreadImagesReceived boards; docs/design/thread.md › Images in the
// thread). Sent images come from the bytes this client kept when it sent them (`NativeThreadStore.queuedImages`); the
// agent's come from the local files its prose names. Both open in one viewer over the thread.

/// An image the viewer can open.
struct ViewerEntry: Identifiable, Equatable {
    enum Origin: Equatable {
        case sent, agent

        var words: String { self == .sent ? "Sent by you" : "From the agent" }
    }

    enum Source {
        case bytes(NativeImage)
        case file(URL)
        /// An image this client sent: only which one. Its bytes stay in the store (`NativeThreadStore.queuedImages`) and are
        /// read when it is opened, so no thumbnail or entry holds a second copy.
        case sent(operation: UUID, index: Int)
        /// An image of a saved message this client did not send (or sent before it restarted): the host's small preview, which
        /// the store holds (`NativeThreadStore.savedImage`).
        case saved(entryID: String, index: Int)
    }

    let id: String
    let name: String
    let origin: Origin
    let source: Source

    static func == (a: ViewerEntry, b: ViewerEntry) -> Bool { a.id == b.id }

    static func file(_ url: URL) -> ViewerEntry {
        ViewerEntry(id: url.path, name: url.lastPathComponent, origin: .agent, source: .file(url))
    }

}

/// What reading an image's header and pixels gives.
struct ImageFacts: Equatable {
    var pixels: CGSize
    /// "PNG", "JPEG".
    var type: String

    static func read(_ source: CGImageSource) -> ImageFacts? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredFilenameExtension }?.uppercased() ?? "Image"
        return ImageFacts(pixels: CGSize(width: width, height: height), type: type)
    }

    static func read(_ data: Data) -> ImageFacts? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(read)
    }
}

/// An image decoded for the viewer, at most `NWImageMetrics.viewerPixels` on its long edge.
struct ViewerPicture {
    let image: CGImage
    let facts: ImageFacts

    /// Reads and decodes one image, synchronously: ImageIO cannot be cancelled once it is running, so the caller is
    /// `ViewerDecoder`, which runs one of these at a time.
    static func decode(_ source: ViewerEntry.Source) -> ViewerPicture? {
        let reader: CGImageSource?
        switch source {
        case .bytes(let image): reader = CGImageSourceCreateWithData(image.data as CFData, nil)
        case .file(let url): reader = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .sent, .saved: reader = nil
        }
        // The header decides before anything is decoded: a few compressed bytes can promise gigapixels.
        guard let reader, let facts = ImageFacts.read(reader),
              facts.pixels.width > 0, facts.pixels.height > 0, Int(facts.pixels.width) <= NativeImage.maxPixels / Int(facts.pixels.height)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(NWImageMetrics.viewerPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(reader, 0, options as CFDictionary).map { ViewerPicture(image: $0, facts: facts) }
    }
}

/// The viewer's one decoder: an actor whose `decode` has no suspension point, so requests run one after another however
/// fast the reader pages. A request whose caller was cancelled while it waited returns before it decodes; one already
/// decoding runs to its end (ImageIO has no cancel), and the next request waits for it. `perform` is the decode itself,
/// replaced by a test that counts how many run at once.
actor ViewerDecoder {
    private let perform: @Sendable (ViewerEntry.Source) -> ViewerPicture?

    init(perform: @escaping @Sendable (ViewerEntry.Source) -> ViewerPicture? = ViewerPicture.decode) {
        self.perform = perform
    }

    func decode(_ source: ViewerEntry.Source) -> ViewerPicture? {
        guard !Task.isCancelled else { return nil }
        return perform(source)
    }
}

extension ViewerPicture: @unchecked Sendable {}

/// What the viewer's buttons do outside the thread. Tests replace it.
struct ImageViewerEffects {
    var copy: @MainActor (ViewerEntry) -> Void = { entry in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.source {
        case .bytes(let image): if NativeImage.withinPixelPolicy(image.data), let value = NSImage(data: image.data) { pasteboard.writeObjects([value]) }
        case .file(let url):
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), NativeImage.withinPixelPolicy(data), let value = NSImage(data: data) { pasteboard.writeObjects([value]) }
        case .sent, .saved: break
        }
    }
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Where an image that exists only as bytes is written so Finder can show it.
    var exportDirectory: @MainActor () -> URL = { AppImageDrop.directory }
}

/// The viewer's state for one thread: the images it pages through and the one open.
@MainActor @Observable
final class ImageViewerModel {
    private(set) var entries: [ViewerEntry] = []
    private(set) var index = 0
    /// The decoded images the viewer holds: the open one and its neighbours (`keptAround`), never more, so paging through
    /// large images cannot pile up decoded pixels (up to 64 MiB each) until the viewer closes.
    private(set) var pictures: [String: ViewerPicture] = [:]
    static let keptAround = 1
    @ObservationIgnored var effects = ImageViewerEffects()
    /// The thread that opened the viewer: where a sent image's bytes are, and what "Add to message" does there. One viewer
    /// serves the whole window, so each opening brings its own.
    struct Context {
        var sentBytes: (UUID, Int) -> NativeImage? = { _, _ in nil }
        /// The host's preview of a saved image (what is drawn), and its original (what Copy, Add and Show in Finder use).
        var savedBytes: (String, Int) -> NativeImage? = { _, _ in nil }
        var savedOriginal: (String, Int) async -> NativeImage? = { _, _ in nil }
        /// Why Add to message cannot take the open image, or nil.
        var addBlocker: () -> String? = { nil }
        var add: (ViewerEntry) -> Void = { _ in }
    }

    @ObservationIgnored var context = Context()
    /// The bytes of the image a thread sent (`.sent`), from the store that kept them; nil once it dropped them.
    var sentBytes: (UUID, Int) -> NativeImage? {
        get { context.sentBytes }
        set { context.sentBytes = newValue }
    }
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The open saved image's original, read in slices while it is open (`NativeThreadStore.savedOriginal`); Copy, Add and
    /// Show in Finder wait for it, so none ever exports the host's lossy preview. Only the open image's is held.
    private(set) var originals: [String: NativeImage] = [:]
    private(set) var originalFailed: Set<String> = []
    @ObservationIgnored private var originalTask: Task<Void, Never>?
    @ObservationIgnored private let decoder: ViewerDecoder

    init(decoder: ViewerDecoder = ViewerDecoder()) { self.decoder = decoder }

    /// A source whose bytes are in hand: a sent image's are read from the store now, and `nil` when it no longer has them.
    func resolved(_ source: ViewerEntry.Source) -> ViewerEntry.Source? {
        switch source {
        case .sent(let operation, let index): return sentBytes(operation, index).map { .bytes($0) }
        case .saved(let entryID, let index): return context.savedBytes(entryID, index).map { .bytes($0) }
        default: return source
        }
    }

    /// What Copy, Add and Show in Finder use: a sent or file image as it is, a saved one only once its original has landed.
    func exportable(_ entry: ViewerEntry) -> ViewerEntry.Source? {
        if case .saved = entry.source { return originals[entry.id].map { .bytes($0) } }
        return resolved(entry.source)
    }

    /// Why the actions wait, for the open image: nil when they can run.
    var originalNotice: String? {
        guard let entry = current, case .saved = entry.source, originals[entry.id] == nil else { return nil }
        return originalFailed.contains(entry.id) ? "Couldn’t load the original" : "Loading the original…"
    }

    private func loadOriginal() {
        originalTask?.cancel()
        originalTask = nil
        let keep = current?.id
        originals = originals.filter { $0.key == keep }
        originalFailed = originalFailed.filter { $0 == keep }
        guard let entry = current, case .saved(let id, let index) = entry.source, originals[entry.id] == nil else { return }
        let fetch = context.savedOriginal
        originalTask = Task { [weak self] in
            let image = await fetch(id, index)
            guard let self, !Task.isCancelled, self.current?.id == entry.id else { return }
            guard let image else { self.originalFailed.insert(entry.id); return }
            // What is drawn, and its size and type in the header, become the original's, decoded through the same one-at-a-time
            // decoder; the actions stay disabled until then. Checked again after the decode: stepping or closing may have come.
            guard let picture = await self.decoder.decode(.bytes(image)) else { self.originalFailed.insert(entry.id); return }
            guard !Task.isCancelled, self.current?.id == entry.id else { return }
            self.originals[entry.id] = image
            self.pictures[entry.id] = picture
        }
    }

    func byteCount(_ entry: ViewerEntry) -> Int? {
        if case .saved = entry.source { return originals[entry.id]?.data.count }
        switch resolved(entry.source) {
        case .bytes(let image): return image.data.count
        case .file(let url): return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        default: return nil
        }
    }

    var isOpen: Bool { !entries.isEmpty }
    var current: ViewerEntry? { entries.indices.contains(index) ? entries[index] : nil }

    func open(_ entries: [ViewerEntry], at index: Int, context: Context) {
        self.context = context
        open(entries, at: index)
    }

    func open(_ entries: [ViewerEntry], at index: Int) {
        guard entries.indices.contains(index) else { return }
        self.entries = entries
        self.index = index
        load()
        loadOriginal()
    }

    func open(files: [URL], at index: Int) {
        open(files.map(ViewerEntry.file), at: index)
    }

    func close() {
        loading?.cancel()
        loading = nil
        originalTask?.cancel()
        originalTask = nil
        originals = [:]
        originalFailed = []
        // The thread's closures (its store, its composer) are let go with the images.
        context = Context()
        entries = []
        index = 0
        pictures = [:]
    }

    func step(_ delta: Int) {
        let next = index + delta
        guard entries.indices.contains(next) else { return }
        index = next
        load()
        loadOriginal()
    }

    /// Decodes the open image, then its neighbours, through the viewer's one `ViewerDecoder`. A new page cancels the task
    /// that was waiting, so what it had queued is skipped before it decodes; a decode already running finishes (ImageIO
    /// cannot be cancelled) and its result is dropped, and the next request runs after it. So at most one decode runs at a
    /// time however fast the reader pages. Pictures outside the open image and its neighbours are released.
    private func load() {
        loading?.cancel()
        let wanted = Set(entries.indices.filter { abs($0 - index) <= Self.keptAround }.map { entries[$0].id })
        pictures = pictures.filter { wanted.contains($0.key) }
        let order = entries.indices.filter { abs($0 - index) <= Self.keptAround }.sorted { abs($0 - index) < abs($1 - index) }
        let queue = order.map { entries[$0] }.filter { pictures[$0.id] == nil }
        guard !queue.isEmpty else { loading = nil; return }
        let epoch = entries.map(\.id)
        loading = Task { [weak self] in
            for entry in queue {
                guard let self, !Task.isCancelled, self.entries.map(\.id) == epoch, let source = self.resolved(entry.source) else { continue }
                let picture = await self.decoder.decode(source)
                // The original's picture, once it is here, is never replaced by the preview's decode.
                guard !Task.isCancelled, self.entries.map(\.id) == epoch, let picture, self.originals[entry.id] == nil,
                      self.entries.indices.contains(self.index), abs(self.entries.firstIndex(of: entry).map { $0 - self.index } ?? .max) <= Self.keptAround
                else { continue }
                self.pictures[entry.id] = picture
            }
        }
    }

    /// Awaits the current decode work (tests).
    func loaded() async { await loading?.value }

    func content(canAdd: Bool, addUnavailable: String?) -> NWImageViewerContent? {
        guard let entry = current else { return nil }
        let picture = pictures[entry.id]
        let parts = [picture.map { "\(Int($0.facts.pixels.width)) × \(Int($0.facts.pixels.height))" }, picture?.facts.type,
                     byteCount(entry).map(NWByteText.string)].compactMap { $0 }
        return NWImageViewerContent(
            name: entry.name, detail: parts.joined(separator: " · "),
            position: entries.count > 1 ? "\(index + 1) of \(entries.count)" : nil, origin: entry.origin.words,
            image: picture.map { Image(decorative: $0.image, scale: 1) }, pixels: picture?.facts.pixels,
            canGoBack: index > 0, canGoForward: index < entries.count - 1, canAdd: canAdd, addUnavailable: addUnavailable,
            actionsWaitFor: originalNotice)
    }

    func copy() {
        guard let entry = current, let source = exportable(entry) else { return }
        effects.copy(ViewerEntry(id: entry.id, name: entry.name, origin: entry.origin, source: source))
    }

    /// A file name that stays inside the folder it is written to: the last path component only (no `/`, `\\`, `..` or a
    /// leading dot), control characters removed, 120 characters at most, and "Image.<ext>" when nothing safe is left.
    static func safeFileName(_ name: String, mimeType: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
        guard !cleaned.isEmpty else { return "Image.\(ext)" }
        return String(cleaned.prefix(120))
    }

    func reveal() {
        guard let entry = current, let source = exportable(entry) else { return }
        switch source {
        case .file(let url): effects.reveal(url)
        case .sent, .saved: return
        case .bytes(let image):
            let folder = effects.exportDirectory().appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let url = folder.appending(path: Self.safeFileName(entry.name, mimeType: image.mimeType))
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? image.data.write(to: url)) != nil else { return }
            effects.reveal(url)
        }
    }
}

/// What a thread's thumbnails open the viewer through: the window's viewer and this thread's context.
@MainActor struct ImageViewerLauncher {
    let model: ImageViewerModel
    let context: ImageViewerModel.Context

    func open(_ entries: [ViewerEntry], at index: Int) { model.open(entries, at: index, context: context) }
}

extension EnvironmentValues {
    /// The thread's launcher, for the sent images above a bubble.
    @Entry var threadImageViewer: ImageViewerLauncher? = nil
    /// The window's viewer (`ImageViewerLayer`); threads open their images in it.
    @Entry var imageViewerModel: ImageViewerModel? = nil
}

/// The image viewer over the window's workspace column (ThreadImageOpen): `bgBase` at 94% over the toolbar and the thread,
/// with the column behind blurred 4pt, the board's backdrop. It is the one place the viewer is drawn: the workspace and
/// every test window that wants it apply this around the column.
struct ImageViewerLayer: ViewModifier {
    let model: ImageViewerModel
    /// How far the window controls reach into the column (`AppLayout.trafficLightInset` while the sidebar is not docked): the
    /// viewer's toolbar starts after them.
    var leadingInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .blur(radius: model.isOpen ? NW.Space.xs : 0)
            .environment(\.imageViewerModel, model)
            .overlay {
                if let viewer = model.content(canAdd: model.context.addBlocker() == nil, addUnavailable: model.context.addBlocker()) {
                    NWImageViewer(content: viewer, actions: NWImageViewerActions(
                        copy: model.copy,
                        add: { if let entry = model.current { model.context.add(entry); model.close() } },
                        reveal: model.reveal,
                        previous: { model.step(-1) }, next: { model.step(1) }, close: model.close),
                                  leadingInset: leadingInset)
                        .nwTransition(.overlay)
                }
            }
    }
}

/// An image the user sent, with the thumbnail drawn above its bubble.
struct SentImage: Equatable, Identifiable {
    let entry: ViewerEntry
    let thumbnail: Image?
    let pixels: CGSize

    var id: String { entry.id }
    static func == (a: SentImage, b: SentImage) -> Bool { a.entry == b.entry && a.pixels == b.pixels }

    var forView: NWSentImage? {
        thumbnail.map { NWSentImage(id: id, name: entry.name, thumbnail: $0, pixels: pixels) }
    }
}

/// A thread's sent images as thumbnails, decoded once from the bytes the store kept. Owned by one `ThreadView`, so it goes
/// with the thread, and it holds only the small thumbnails (never the source bytes): opening one reads the bytes from the
/// store. At most `kept` sends, the same bound the store keeps bytes for.
@MainActor
final class SentImageThumbnails {
    static let kept = 32
    private var values: [String: [SentImage]] = [:]
    private var order: [String] = []

    /// A send's images, or none where this client does not hold their bytes (another client's, or before a restart, or
    /// dropped by the store's own bound).
    func images(for operation: UUID, in store: NativeThreadStore) -> [SentImage] {
        let sent = store.queuedImages(operation)
        guard !sent.isEmpty else { return [] }
        if let kept = values[operation.uuidString], kept.count == sent.count { return kept }
        return decode(sent, key: operation.uuidString) { index in
            ViewerEntry(id: "\(operation.uuidString)/\(index)", name: sent[index].name ?? "Image \(index + 1)", origin: .sent,
                        source: .sent(operation: operation, index: index))
        }
    }

    /// A saved message's images from the host's previews, `count` of them starting at `offset` among the message's pictures;
    /// none until every one has landed (a half-drawn group would be wrong).
    func images(entry entryID: String, offset: Int, count: Int, in store: NativeThreadStore) -> [SentImage] {
        let previews = (offset..<offset + count).compactMap { store.savedImage(entryID: entryID, index: $0) }
        guard count > 0, previews.count == count else { return [] }
        let key = "\(entryID)#\(offset)"
        if let kept = values[key], kept.count == count { return kept }
        return decode(previews, key: key) { index in
            ViewerEntry(id: "\(entryID)/\(offset + index)", name: "Image \(offset + index + 1)", origin: .sent,
                        source: .saved(entryID: entryID, index: offset + index))
        }
    }

    private func decode(_ sent: [NativeImage], key: String, entry: (Int) -> ViewerEntry) -> [SentImage] {
        let decoded = sent.enumerated().map { index, image in
            let entry = entry(index)
            let ok = NativeImage.withinPixelPolicy(image.data)
            return SentImage(entry: entry, thumbnail: ok ? Self.thumbnail(of: image.data) : nil, pixels: ok ? ImageFacts.read(image.data)?.pixels ?? .zero : .zero)
        }
        if values[key] == nil { order.append(key) }
        values[key] = decoded
        while order.count > Self.kept { values[order.removeFirst()] = nil }
        return decoded
    }

    private static func thumbnail(of data: Data) -> Image? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(NWThreadMetrics.sentThumbnailPixels),
        ]
        return CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            .map { Image(decorative: $0, scale: 1) }
    }
}
