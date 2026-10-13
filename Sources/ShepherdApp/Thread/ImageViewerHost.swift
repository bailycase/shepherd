import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// An image open full size (ThreadImageOpen, docs/design/thread-images.md): the images of one
// message or composer, shown one at a time over the window. The state is values only; the host
// view draws `NWImageViewer` and carries out Copy, Add to message and Show in Finder.

extension EnvironmentValues {
    /// Opens the viewer over the window (`ShepherdViewModel.imageViewer`); does nothing where no window sets it.
    @Entry var presentImages: (ImageViewerState) -> Void = { _ in }
}

/// One image the viewer can show: its bytes are already here (a composer's image, or one the
/// store kept), so nothing loads.
struct ViewerImage: Identifiable, Equatable {
    let id: String
    let name: String
    let data: Data
    let mimeType: String
    let pixels: CGSize?
    /// The file it came from; Show in Finder is drawn only when there is one.
    let source: URL?
    /// Decoded once, here, never in a view's body; nil when the bytes are not an image the viewer will draw
    /// (not raster, or past `maxPixels`).
    let picture: NSImage?

    init(attachment: ImageAttachment) {
        id = attachment.id.uuidString
        name = attachment.name
        data = attachment.image.data
        mimeType = attachment.image.mimeType
        pixels = attachment.pixels
        source = attachment.source
        picture = Self.decode(attachment.image.data)
    }

    /// A thread's image whose bytes are here (`id` is the host's image id).
    init(id: String, name: String, data: Data, mimeType: String, pixels: CGSize?) {
        self.id = id
        self.name = name
        self.data = data
        self.mimeType = mimeType
        self.pixels = pixels
        source = nil
        picture = Self.decode(data)
    }

    /// The raster header of `data`: its size, once it is an image of an offered type within the byte bound and
    /// `NativeImage.maxPixels` (overflow-safe). No bitmap is made. The one rule the host, the client and this viewer share.
    static func acceptedSize(_ data: Data) -> CGSize? {
        guard data.count <= NativeImage.maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let kind = CGImageSourceGetType(source) as String?, let mime = UTType(kind)?.preferredMIMEType, NativeImage.threadMimeTypes.contains(mime),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              NativeImage.fitsPixelBound(width: width, height: height) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The image at full size for the viewer, checked from its header before any bitmap is made. Anything the thread
    /// accepted (up to `NativeImage.maxPixels`) is drawn; a composer's own file is held to the same bound.
    static func decode(_ data: Data) -> NSImage? {
        acceptedSize(data) == nil ? nil : NSImage(data: data)
    }

    /// A transcript thumbnail: the picture decoded no larger than `longestSide` pixels (ImageIO scales while decoding, so a
    /// 4096 × 4096 image never becomes a full bitmap just to be drawn at 240 points).
    static func thumbnail(_ data: Data, longestSide: CGFloat) -> NSImage? {
        guard let size = acceptedSize(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(max(1, longestSide.rounded(.up)))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: min(size.width, CGFloat(image.width)), height: min(size.height, CGFloat(image.height))))
    }

    nonisolated static func == (a: ViewerImage, b: ViewerImage) -> Bool {
        a.id == b.id && a.name == b.name && a.data == b.data
    }

    /// "PNG", "JPEG".
    var format: String {
        switch mimeType {
        case "image/jpeg": "JPEG"
        case "image/gif": "GIF"
        case "image/webp": "WebP"
        default: "PNG"
        }
    }

    /// "1170 × 2532 · PNG · 1.4 MB".
    var facts: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let dimensions = pixels.map { "\(Int($0.width)) × \(Int($0.height))" }
        return ([dimensions, format, size].compactMap { $0 }).joined(separator: " · ")
    }
}

/// One place in the viewer: the image, or what is happening to it.
enum ViewerSlot: Equatable {
    case ready(ViewerImage)
    case loading(name: String, ref: NativeImageRef)
    case failed(name: String, ref: NativeImageRef, message: String)

    var name: String {
        switch self {
        case .ready(let image): image.name
        case .loading(let name, _), .failed(let name, _, _): name
        }
    }
}

/// The viewer's state: which images and which one is showing. Images in the composer are all here; a thread's are
/// fetched as they are reached (`NativeThreadImages`), the one shown first and its neighbours after.
@MainActor @Observable
final class ImageViewerState {
    private(set) var slots: [ViewerSlot]
    private(set) var index: Int
    /// The line along the bottom, before "Esc to close": "Sent by you", "Waiting to send".
    let origin: String
    /// Puts the shown image in the composer; nil where it already is.
    let addToMessage: ((ViewerImage) -> Void)?
    @ObservationIgnored private var images: NativeThreadImages?
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]

    init(images: [ViewerImage], index: Int = 0, origin: String, addToMessage: ((ViewerImage) -> Void)? = nil) {
        slots = images.map(ViewerSlot.ready)
        self.index = images.indices.contains(index) ? index : 0
        self.origin = origin
        self.addToMessage = addToMessage
    }

    /// A thread's images, named by the snapshot and fetched from `images`.
    init(set: ThreadImageSet, index: Int, images: NativeThreadImages?, addToMessage: ((ViewerImage) -> Void)?) {
        slots = zip(set.refs, set.names).map { ViewerSlot.loading(name: $1, ref: $0) }
        self.index = set.refs.indices.contains(index) ? index : 0
        origin = set.origin
        self.addToMessage = addToMessage
        self.images = images
        reach()
    }

    var images_: [ViewerImage] { slots.compactMap { if case .ready(let image) = $0 { image } else { nil } } }
    var count: Int { slots.count }
    var current: ViewerImage? { if case .ready(let image)? = slots[safe: index] { image } else { nil } }
    var currentSlot: ViewerSlot? { slots[safe: index] }
    var position: String? { slots.count > 1 ? "\(index + 1) of \(slots.count)" : nil }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < slots.count }

    func previous() { if hasPrevious { index -= 1; reach() } }
    func next() { if hasNext { index += 1; reach() } }

    func retry() {
        guard case .failed(let name, let ref, _)? = slots[safe: index] else { return }
        slots[index] = .loading(name: name, ref: ref)
        reach()
    }

    /// Stops what is still being fetched (the viewer closed).
    func close() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// Fetches the image shown and the next one, so stepping forward finds it ready.
    private func reach() {
        for position in [index, index + 1] where slots.indices.contains(position) {
            guard case .loading(let name, let ref) = slots[position], tasks[position] == nil else { continue }
            guard let images else { slots[position] = .failed(name: name, ref: ref, message: "This image can't be shown."); continue }
            tasks[position] = Task { [weak self] in
                let outcome = await images.image(ref)
                guard !Task.isCancelled, let self else { return }
                self.tasks[position] = nil
                guard self.slots.indices.contains(position), case .loading = self.slots[position] else { return }
                switch outcome {
                case .image(let data):
                    let image = ViewerImage(id: ref.id, name: name, data: data, mimeType: ref.mimeType,
                                            pixels: ref.width.flatMap { w in ref.height.map { CGSize(width: w, height: $0) } })
                    self.slots[position] = image.picture == nil
                        ? .failed(name: name, ref: ref, message: "This image can't be shown.") : .ready(image)
                case .unavailable:
                    self.slots[position] = .failed(name: name, ref: ref, message: "This image isn't in the thread any more.")
                case .failed(let why):
                    self.slots[position] = .failed(name: name, ref: ref, message: why)
                case .cancelled:
                    self.slots[position] = .failed(name: name, ref: ref, message: ThreadImageLoad.interrupted)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What the viewer does outside the app: set once by the view model, so a test records the request and
/// never opens Finder or touches the pasteboard.
struct ImageViewerActions {
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var copy: @MainActor (NSImage) -> Void = { image in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

/// The viewer over the window: a click outside the picture does not close it (the bar's close
/// button and Esc do); ← and → step through the images.
struct ImageViewerOverlay: View {
    var vm: ShepherdViewModel
    @FocusState private var focused: Bool

    private func content(_ slot: ViewerSlot) -> NWImageViewer.Content {
        switch slot {
        case .ready(let image): image.picture.map { .picture(Image(nsImage: $0)) } ?? .failed("This image can't be shown.")
        case .loading: .loading
        case .failed(_, _, let message): .failed(message)
        }
    }

    var body: some View {
        ZStack {
            if let state = vm.imageViewer, let slot = state.currentSlot {
                let actions = vm.imageViewerActions
                let image = state.current
                NWImageViewer(
                    name: slot.name, facts: image?.facts ?? "", position: state.position,
                    content: content(slot),
                    caption: "\(state.origin) · Esc to close",
                    previous: state.hasPrevious ? { state.previous() } : nil,
                    next: state.hasNext ? { state.next() } : nil,
                    copy: image?.picture.map { picture in { actions.copy(picture) } },
                    addToMessage: image.flatMap { shown in state.addToMessage.map { add in { add(shown); vm.closeImageViewer() } } },
                    showInFinder: image?.source.map { url in { actions.reveal(url) } },
                    retry: { if case .failed = slot { return { state.retry() } } else { return nil } }(),
                    close: { vm.closeImageViewer() })
                .id("\(slot.name)/\(state.index)")
                // Esc and the arrows go to a hidden focus target of their own: focusing the whole viewer would hand every control in it an
                // inherited focus, and each would draw its keyboard ring (`isFocused` reaches descendants).
                .background {
                    Color.clear
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focused)
                        .onAppear { focused = true }
                        .onKeyPress(.escape) { vm.closeImageViewer(); return .handled }
                        .onKeyPress(.leftArrow) { state.previous(); return .handled }
                        .onKeyPress(.rightArrow) { state.next(); return .handled }
                        .accessibilityHidden(true)
                }
                .nwTransition(.overlay)
            }
        }
        .allowsHitTesting(vm.imageViewer != nil)
        .nwAnimation(.overlay, value: vm.imageViewer != nil)
    }
}

/// The composer's images, above its card (ThreadImagesComposer): a chip each with its thumbnail,
/// name, size and remove, then the failed line while an image cannot go.
struct ComposerImageStrip: View {
    let attachments: ComposerAttachments
    let open: (ImageAttachment) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        if !attachments.isEmpty || attachments.error != nil {
            VStack(alignment: .leading, spacing: NW.Space.s) {
                NWFlowLayout(spacing: NW.Space.s, lineSpacing: NW.Space.s) {
                    ForEach(attachments.items) { attachment in
                        NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail, detail: attachment.sizeLabel,
                                         problem: attachment.isOversize, open: { open(attachment) }, remove: { remove(attachment.id) })
                            .nwTransition(.list, edge: .leading)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Images to send")
                if let error = attachments.error {
                    Text(error).font(.nw(.caption)).foregroundStyle(AgentState.failed.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .nwTransition(.list, edge: .bottom)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NW.Space.xs)
        }
    }
}
