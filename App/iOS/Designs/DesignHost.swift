import SwiftUI
import UIKit
import DesignSurfaceKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The one file of the iOS app that imports DesignSurfaceKit (as DesignHost.swift is on the Mac):
// boards render here, on the phone, from the files each host served by hash; never on the host.
//
// At most two web views live at once (docs/designs.md › Performance): the board on screen
// (`DesignLiveBoard`), and one off-screen renderer that draws thumbnails and exports one board at
// a time (`DesignRendering`).

/// An element a tap on a board named, as the board's bridge measured it (board points).
struct DesignPick: Equatable {
    var tid: Int
    var path: [Int]
    var rect: CGRect
    var kind: DesignElementKind
    var label: String?
    var name: String?
    var noun: String

    /// The selection tag's words: "card · Checkout funnel".
    var tag: String { [noun, name ?? label].compactMap { $0 }.joined(separator: " · ") }

    fileprivate init(_ hit: DesignHit) {
        tid = hit.tid
        path = hit.path
        rect = hit.rect
        kind = hit.kind
        label = hit.label
        name = hit.name
        noun = hit.noun
    }
}

/// What Export makes of a board.
enum DesignExportFormat: String, CaseIterable, Identifiable {
    case png, pdf
    var id: String { rawValue }
    var title: String { self == .png ? "Image (PNG)" : "PDF" }
}

/// Every design's sandbox on this phone, and the one off-screen renderer that draws boards into
/// images (the Designs tiles, the Boards sheet) and exports them, one board at a time.
@MainActor
final class DesignRendering {
    static let shared = DesignRendering()

    /// Web views alive now: the board on screen and the renderer's, never more than two.
    private(set) var liveViews = 0 {
        didSet { peakLiveViews = max(peakLiveViews, liveViews) }
    }
    /// The most web views alive at once since launch (a fixture checks the cap).
    private(set) var peakLiveViews = 0
    static let liveCap = 2

    private var surfaces: [HostDesignRef: DesignSurface] = [:]
    private var images: [String: UIImage] = [:]
    private var imageOrder: [String] = []
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private lazy var stage = RenderStage()

    /// Thumbnails kept in memory, the oldest given up first.
    static let imageBudget = 48

    /// Boards drawn into images and kept now.
    var renderedImages: Int { images.count }

    func surface(_ ref: HostDesignRef, source: RemoteDesignSource) -> DesignSurface {
        if let surface = surfaces[ref] { return surface }
        let surface = DesignSurface(designID: ref.design, source: source)
        surfaces[ref] = surface
        return surface
    }

    /// Forgets the sandboxes and images of designs no host lists any more.
    func prune(keeping live: Set<HostDesignRef>) {
        for ref in surfaces.keys where !live.contains(ref) { surfaces[ref] = nil }
    }

    fileprivate func opened() { liveViews += 1 }
    fileprivate func closed() { liveViews -= 1 }

    /// The board drawn as an image `width` points wide, from the cache while its hash holds.
    func image(_ ref: HostDesignRef, source: RemoteDesignSource, path: DesignPath, sha256: String, size: CGSize,
               width: CGFloat) async -> UIImage? {
        let key = "\(ref.host.uuidString)/\(ref.design.rawValue)/\(path.rawValue)/\(sha256)/\(Int(width))"
        if let image = images[key] { return image }
        let rendered: UIImage? = await exclusively {
            // A tile scrolled away while it waited its turn draws nothing: no web view for it.
            guard !Task.isCancelled else { return nil }
            let view = self.makeView(ref, source: source, path: path, size: size)
            defer { self.release(view) }
            guard (try? await Self.load(view)) != nil, let image = try? await view.snapshot(width: min(width, size.width)) else { return nil }
            return UIImage(cgImage: image, scale: max(1, image.width > 0 ? CGFloat(image.width) / min(width, size.width) : 1),
                           orientation: .up)
        }
        if let rendered { remember(rendered, key) }
        return rendered
    }

    /// The board as a PNG (twice its size) or PDF file for the share sheet, drawn at zoom 1.
    func export(_ ref: HostDesignRef, source: RemoteDesignSource, path: DesignPath, board: DesignIndex.Board, name: String,
                format: DesignExportFormat) async throws -> URL {
        let size = CGSize(width: board.w, height: board.h)
        let data: Data = try await exclusivelyThrowing {
            let view = self.makeView(ref, source: source, path: path, size: size)
            defer { self.release(view) }
            try await Self.load(view)
            switch format {
            case .png: return try DesignImageFile.png(try await view.image(scale: 2))
            case .pdf: return try await view.pdf(DesignPrint.of(board))
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("design-export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(DesignExportNames.file(name, format: format))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: The renderer

    private func makeView(_ ref: HostDesignRef, source: RemoteDesignSource, path: DesignPath, size: CGSize) -> DesignBoardView {
        let view = DesignBoardView(surface: surface(ref, source: source), board: path, size: size)
        opened()
        stage.add(view)
        return view
    }

    private func release(_ view: DesignBoardView) {
        view.removeFromSuperview()
        closed()
    }

    /// Loads a board, giving up after a while: a board that never draws leaves its tile blank.
    fileprivate static func load(_ view: DesignBoardView) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in _ = try await view.load() }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw DesignBoardError.loadFailed("timed out")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// One board at a time through the renderer.
    private func exclusively<T>(_ body: @MainActor () async -> T) async -> T {
        await acquire()
        defer { releaseTurn() }
        return await body()
    }

    private func exclusivelyThrowing<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        await acquire()
        defer { releaseTurn() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseTurn() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    private func remember(_ image: UIImage, _ key: String) {
        images[key] = image
        imageOrder.append(key)
        while imageOrder.count > Self.imageBudget { images[imageOrder.removeFirst()] = nil }
    }
}

/// Where the renderer's web view sits while it draws: inside the app's window (WebKit draws only
/// there), in a one-point corner that clips it, behind everything and out of touch and VoiceOver.
@MainActor
private final class RenderStage {
    private var container: UIView?

    func add(_ view: UIView) {
        guard let window = Self.window() else { return }
        if container?.window !== window {
            container?.removeFromSuperview()
            let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            stage.clipsToBounds = true
            stage.isUserInteractionEnabled = false
            stage.accessibilityElementsHidden = true
            window.insertSubview(stage, at: 0)
            container = stage
        }
        view.frame.origin = .zero
        container?.addSubview(view)
    }

    private static func window() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// The one board on screen, live: it lays the board out at its own size, scaled to the canvas's zoom, answers what an
/// element under a tap is and where a comment's element is now, and takes a new source in place
/// when the host's copy changes.
@MainActor
@Observable
final class DesignLiveBoard {
    let ref: HostDesignRef
    let path: DesignPath
    let size: CGSize
    private(set) var booted = false
    private(set) var failure: String?
    /// Moves each time the board redraws (booted, reloaded), so pins measure again.
    private(set) var drawn = 0

    @ObservationIgnored private var view: DesignBoardView?
    @ObservationIgnored private let source: RemoteDesignSource

    init(ref: HostDesignRef, path: DesignPath, size: CGSize, source: RemoteDesignSource) {
        self.ref = ref
        self.path = path
        self.size = size
        self.source = source
    }

    /// Makes the web view and loads the board (once).
    fileprivate func attach() -> DesignBoardView {
        if let view { return view }
        let made = DesignBoardView(surface: DesignRendering.shared.surface(ref, source: source), board: path, size: size)
        made.isUserInteractionEnabled = false
        made.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .terminated:
                self.booted = false
                Task { await self.load() }
            case .resized:
                self.drawn += 1
            default:
                break
            }
        }
        view = made
        DesignRendering.shared.opened()
        Task { await load() }
        return made
    }

    /// Gives up the web view (the screen left, or showed another board).
    func close() {
        guard let view else { return }
        view.removeFromSuperview()
        self.view = nil
        booted = false
        DesignRendering.shared.closed()
    }

    private func load() async {
        guard let view else { return }
        do {
            try await DesignRendering.load(view)
            booted = true
            failure = nil
            drawn += 1
        } catch {
            failure = "This board didn't draw."
        }
    }

    /// Takes the host's new copy of the board in place (no reload, no blank frame).
    func reload() async {
        guard let view, booted, let text = try? await source.source(path) else { return }
        if (try? await view.replaceSource(text)) != nil { drawn += 1 }
    }

    func zoom(_ zoom: CGFloat) {
        view?.zoom = zoom
    }

    /// The element under `point` (board points), or nil.
    func pick(at point: CGPoint) async -> DesignPick? {
        guard booted, let hit = await view?.hitTest(at: point) else { return nil }
        return DesignPick(hit)
    }

    /// Where element `tid` is drawn now, or nil.
    func rect(tid: Int) async -> CGRect? {
        guard booted else { return nil }
        return await view?.element(tid: tid)?.rect
    }
}

/// A live board in SwiftUI, at `zoom` (points per board point).
struct DesignLiveBoardView: UIViewRepresentable {
    let board: DesignLiveBoard
    let zoom: CGFloat

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        let view = board.attach()
        container.addSubview(view)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        board.zoom(zoom)
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// A board drawn as an image (a tile, the Boards sheet), rendered off screen and cached by hash,
/// `shown` points big at `alignment` in whatever frame it gets, on the board's own background
/// (its top-leading pixel) where it doesn't fill that frame.
struct DesignBoardImage: View {
    let ref: HostDesignRef
    let source: RemoteDesignSource?
    let path: DesignPath
    let sha256: String
    let size: CGSize
    let shown: CGSize
    var alignment: Alignment = .topLeading
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: alignment) {
            if let image {
                Color(uiColor: DesignRendering.edgeColor(image))
                Image(uiImage: image).resizable().interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .task(id: sha256 + "/\(Int(shown.width))") {
            guard let source, size.width > 0, size.height > 0 else { return }
            image = await DesignRendering.shared.image(ref, source: source, path: path, sha256: sha256, size: size,
                                                       width: shown.width)
        }
        .accessibilityHidden(true)
    }
}

extension DesignRendering {
    /// A board's own background: the color of its top-leading pixel.
    static func edgeColor(_ image: UIImage) -> UIColor {
        guard let cg = image.cgImage,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let corner = cg.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return .clear }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .clear }
        return UIColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255,
                       alpha: CGFloat(data[3]) / 255)
    }
}

/// The file names Export gives a board: the board's name, safe for a file.
enum DesignExportNames {
    static func file(_ name: String, format: DesignExportFormat) -> String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " ? $0 : "-" }
        let base = String(safe).trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Board" : base) + (format == .png ? "@2x.png" : ".pdf")
    }
}
