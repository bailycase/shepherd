import AppKit
import ImageIO
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Images in the transcript (ThreadImagesSent, ThreadImagesReceived, ThreadImageOpen): a thumbnail for each image the
// host names, fetched when it comes on screen, and the same bytes in the full-size viewer. Values come from the snapshot
// (`NativeImageRef`) and the store's `NativeThreadImages`; nothing is decoded in a body.

extension EnvironmentValues {
    /// The thread's images, for the views that draw them; nil where there is none (a transcript of a subagent, a preview).
    @Entry var threadImages: NativeThreadImages? = nil
    /// Opens the viewer on `ViewerImage`s, the first being the one pressed.
    @Entry var viewImages: ThreadImageOpener = ThreadImageOpener { _, _ in }
}

/// A closure the environment can compare: one per window, so a redraw does not rebuild every thumbnail.
struct ThreadImageOpener: Equatable {
    let id = UUID()
    let run: (ThreadImageSet, Int) -> Void
    init(_ run: @escaping (ThreadImageSet, Int) -> Void) { self.run = run }
    func callAsFunction(_ set: ThreadImageSet, _ index: Int) { run(set, index) }
    static func == (a: ThreadImageOpener, b: ThreadImageOpener) -> Bool { a.id == b.id }
}

/// The images of one message, in the order they are shown.
struct ThreadImageSet: Equatable {
    var refs: [NativeImageRef]
    var names: [String]
    var origin: String
}

/// What one image has become: nothing yet, a picture, or a reason it is not one.
@MainActor @Observable
final class ThreadImageLoad {
    enum State: Equatable {
        case loading
        case picture(Data, NSImage)
        case unavailable
        case failed(String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.loading, .loading), (.unavailable, .unavailable): true
            case (.picture(let x, _), .picture(let y, _)): x == y
            case (.failed(let x), .failed(let y)): x == y
            default: false
            }
        }
    }

    /// Twice the largest box a thumbnail is drawn in (384 points), for a 2x display.
    static let thumbnailPixels: CGFloat = 768
    /// What a fetch the thread stopped says, with a Retry beside it.
    static let interrupted = "The connection was interrupted."

    let ref: NativeImageRef
    private(set) var state: State = .loading
    @ObservationIgnored private var task: Task<Void, Never>?

    init(_ ref: NativeImageRef) { self.ref = ref }

    /// Starts once; a failure can be asked again with `retry`.
    func load(from images: NativeThreadImages?) {
        guard task == nil, case .loading = state else { return }
        guard let images else { state = .unavailable; return }
        task = Task { [weak self] in
            let outcome = await images.image(self?.ref ?? NativeImageRef(id: "", mimeType: ""))
            guard !Task.isCancelled, let self else { return }
            self.state = switch outcome {
            case .image(let data): ViewerImage.thumbnail(data, longestSide: Self.thumbnailPixels).map { State.picture(data, $0) } ?? .unavailable
            case .unavailable: .unavailable
            case .failed(let why): .failed(why)
            // Stopped by the thread, not by this view (which would have returned above): the image may still be there.
            case .cancelled: .failed(Self.interrupted)
            }
            self.task = nil
        }
    }

    func retry(from images: NativeThreadImages?) {
        guard case .failed = state else { return }
        state = .loading
        task = nil
        load(from: images)
    }

    func cancel() { task?.cancel(); task = nil }
}

/// One image in the transcript: its thumbnail, or the chip that stands for one the thread does not draw. Pressing it
/// opens the viewer on the message's images at this one.
struct ThreadImageThumb: View {
    let ref: NativeImageRef
    let name: String
    let size: CGSize
    let open: () -> Void
    @Environment(\.threadImages) private var images
    @State private var load: ThreadImageLoad

    init(ref: NativeImageRef, name: String, size: CGSize, open: @escaping () -> Void) {
        self.ref = ref
        self.name = name
        self.size = size
        self.open = open
        _load = State(initialValue: ThreadImageLoad(ref))
    }

    var body: some View {
        switch load.state {
        case .unavailable:
            SHThreadImageChip(name: name, detail: "not available")
        case .picture(_, let image):
            SHThreadImage(name: name, size: size, content: .picture(Image(nsImage: image)), open: open)
        case .failed:
            // Retry starts the fetch itself: the `.loading` branch's task only runs when that branch first appears.
            SHThreadImage(name: name, size: size, content: .failed, open: {}, retry: { load.retry(from: images) })
        case .loading:
            SHThreadImage(name: name, size: size, content: .loading, open: open)
                .task { load.load(from: images) }
                .onDisappear { load.cancel() }
        }
    }
}

/// The thumbnails of a sent message, above its bubble (ThreadImagesSent): in a row, trailing, wrapping.
struct SentImages: View {
    let refs: [NativeImageRef]
    let names: [String]
    let origin: String
    @Environment(\.viewImages) private var view

    var body: some View {
        HStack(spacing: SH.Space.s) {
            ForEach(Array(refs.enumerated()), id: \.element.id) { index, ref in
                ThreadImageThumb(ref: ref, name: names.indices.contains(index) ? names[index] : "Image \(index + 1)",
                                 size: SHThreadImageMetrics.box(width: ref.width, height: ref.height,
                                                                widest: SHThreadImageMetrics.sentWidest,
                                                                tallest: SHThreadImageMetrics.sentLongestSide)) {
                    view(ThreadImageSet(refs: refs, names: names, origin: origin), index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(refs.count) image\(refs.count == 1 ? "" : "s") you sent")
    }
}

/// Images the agent made or a tool returned, where they happened (ThreadImagesReceived).
struct ReceivedImages: View {
    let refs: [NativeImageRef]
    @Environment(\.viewImages) private var view

    var body: some View {
        SHFlowLayout(spacing: SH.Space.l, lineSpacing: SH.Space.l) {
            ForEach(Array(refs.enumerated()), id: \.element.id) { index, ref in
                ThreadImageThumb(ref: ref, name: "Image \(index + 1)",
                                 size: SHThreadImageMetrics.box(width: ref.width, height: ref.height,
                                                                widest: SHThreadImageMetrics.receivedWidest,
                                                                tallest: SHThreadImageMetrics.receivedTallest)) {
                    view(ThreadImageSet(refs: refs, names: refs.indices.map { "Image \($0 + 1)" }, origin: "From the agent"), index)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(refs.count) image\(refs.count == 1 ? "" : "s") from the agent")
    }
}
