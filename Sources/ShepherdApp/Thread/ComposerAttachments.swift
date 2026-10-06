import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdRemote

/// Images waiting in a composer (a thread's, or the New thread page's) and the rules a send
/// takes: at most `NativeImage.maxPerSend`, each a raster image of at most `NativeImage.maxBytes`
/// once resized. Dropped, pasted and picked files are resized on the way in
/// (`AppImageDrop.resolve`: longest edge 2000px, JPEG stays JPEG, everything else PNG) before
/// they get here. Pure: only `add(urls:)` reads files.
struct ComposerAttachments: Equatable {
    private(set) var items: [ImageAttachment] = []
    /// Why the last add left something out, for the composer's `failed` line.
    private(set) var error: String?

    var isEmpty: Bool { items.isEmpty }
    var isFull: Bool { items.count >= NativeImage.maxPerSend }
    var ids: [UUID] { items.map(\.id) }
    /// What a send carries.
    var images: [NativeImage] { items.map(\.image) }

    /// Adds what fits, in order. A nil attachment is a file that is not an image.
    mutating func add(_ candidates: [(name: String, attachment: ImageAttachment?)]) {
        error = nil
        for candidate in candidates {
            guard !isFull else {
                error = "At most \(NativeImage.maxPerSend) images per message."
                return
            }
            guard let attachment = candidate.attachment else {
                error = "\(candidate.name) is not an image Shepherd can attach."
                continue
            }
            guard attachment.image.data.count <= NativeImage.maxBytes else {
                error = "\(candidate.name) is over \(NativeImage.maxBytes / 1024 / 1024) MiB after resizing."
                continue
            }
            items.append(attachment)
        }
    }

    /// Files already resized by `AppImageDrop.resolve`.
    mutating func add(urls: [URL]) {
        add(urls.map { ($0.lastPathComponent, ImageAttachment(url: $0)) })
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Sent: the images went with the message.
    mutating func removeAll() {
        items.removeAll()
    }

    mutating func clearError() {
        error = nil
    }

    mutating func reject(_ message: String) { error = message }
}

/// Shared by a thread's input paths; only the composer observes attachments and focus
/// requests. Scroll intent is sampled with geometry, without rebuilding the transcript.
@MainActor
@Observable
final class ThreadInput {
    var attachments = ComposerAttachments()
    var dropTargeted = false
    private(set) var focusRequest = 0
    var available = false {
        didSet { if available != oldValue { generation += 1 } }
    }
    private var generation = 0
    @ObservationIgnored private var wheelIntentUntil = Date.distantPast
    @ObservationIgnored private var wheelUpward = false

    /// Recoil after a downward wheel tick is layout, not a reader scrolling up again.
    func hasWheelIntent(movingUp: Bool) -> Bool {
        Date() <= wheelIntentUntil && movingUp == wheelUpward
    }

    func readerScrolled(upward: Bool) {
        wheelUpward = upward
        wheelIntentUntil = Date().addingTimeInterval(0.35)
    }

    func focus() {
        guard available else { return }
        focusRequest += 1
    }

    func attach(_ providers: [NSItemProvider], store: NativeThreadStore, localFiles: Bool) {
        guard available else { return }
        attachments.clearError()
        let generation = generation
        let session = store.sessionKey
        Task {
            let urls = await AppImageDrop.resolve(providers)
            guard available, self.generation == generation, store.sessionKey == session else { return }
            add(urls: urls, store: store, localFiles: localFiles)
        }
    }

    func add(urls: [URL], store: NativeThreadStore, localFiles: Bool) {
        var rejection: String?
        for url in urls {
            if let image = ImageAttachment(url: url) {
                guard store.supportedActions.contains("sendImages") else {
                    rejection = "This agent does not support image attachments."
                    continue
                }
                attachments.add([(url.lastPathComponent, image)])
                if let error = attachments.error { rejection = error }
            } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                rejection = "\(url.lastPathComponent) is not an image Shepherd can attach."
            } else if !localFiles {
                rejection = "Files cannot be attached to a remote thread yet. Images are supported."
            } else if url.isFileURL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      FileManager.default.isReadableFile(atPath: url.path) {
                store.attach(files: [NativeAttachedFile(name: url.lastPathComponent, path: url.path)])
            } else {
                rejection = "\(url.lastPathComponent) is not a readable file."
            }
        }
        if let rejection { attachments.reject(rejection) }
    }
}

/// A background, never an ancestor gesture: text selection and foreground controls retain
/// their clicks. No keyboard interception is needed to reclaim the field.
struct ThreadInputBackground: View {
    let input: ThreadInput

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { input.focus() }
            .accessibilityHidden(true)
    }
}

struct ThreadInputDrop: ViewModifier {
    @Bindable var input: ThreadInput
    let store: NativeThreadStore
    let localFiles: Bool

    func body(content: Content) -> some View {
        content.onDrop(of: [.image, .fileURL], isTargeted: $input.dropTargeted) { providers in
            guard input.available else { return false }
            input.attach(providers, store: store, localFiles: localFiles)
            return true
        }
    }
}

/// A resized image waiting in a composer. `image.data` is the bytes pi will receive; the
/// thumbnail is decoded once, here.
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let image: NativeImage
    let thumbnail: Image?

    init(id: UUID = UUID(), name: String, image: NativeImage, thumbnail: Image? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.thumbnail = thumbnail
    }

    /// nil when the file is not a raster image.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return nil }
        let mimeType = type == .jpeg ? "image/jpeg" : type == .gif ? "image/gif" : type == .webP ? "image/webp" : "image/png"
        self.init(name: url.lastPathComponent, image: NativeImage(mimeType: mimeType, data: data),
                  thumbnail: NSImage(data: data).map { Image(nsImage: $0) })
    }

    /// The thumbnail is derived from `image`, so identity and bytes say everything.
    static func == (a: ImageAttachment, b: ImageAttachment) -> Bool {
        a.id == b.id && a.name == b.name && a.image == b.image
    }
}
