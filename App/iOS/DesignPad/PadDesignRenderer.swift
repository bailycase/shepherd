import SwiftUI
import UIKit
import DesignSurfaceKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The iPad's board rendering, and the only iOS file that imports DesignSurfaceKit (as
// DesignHost.swift is on the Mac), so the renderer's API drift breaks exactly one file.
//
// Boards render on this device from the files the host serves (docs/designs.md › Remote), never
// on the host. A design on screen keeps at most `DesignTouchLivePlan.liveCap` live web view (the
// selected board, else the board nearest the middle of the canvas), and one off-screen view
// (`PadDesignRasterizer`) draws every other board's snapshot, one at a time: two web views at
// most, the plan's iOS cap, however large the canvas. A hidden design gives its live view up and
// keeps its snapshots.

/// An element a board reported under a point: its id as a view record names it, where the board
/// draws it (the board's own points), and what it is.
struct PadDesignPick: Equatable {
    let board: DesignPath
    let id: DesignElementID
    var rect: CGRect
    var kind: DesignElementKind
    var label: String?
    /// "card · Checkout funnel".
    var tag: String
    /// What a comment on it is on: its `data-el` name, else its words.
    var words: String?

    init?(_ hit: DesignHit, on board: DesignPath) {
        guard let id = hit.id(on: board) else { return nil }
        self.board = board
        self.id = id
        rect = hit.rect
        kind = hit.kind
        label = hit.label
        tag = hit.tag
        words = hit.name ?? hit.label
    }

    init(board: DesignPath, id: DesignElementID, rect: CGRect, kind: DesignElementKind, label: String?, tag: String, words: String?) {
        self.board = board
        self.id = id
        self.rect = rect
        self.kind = kind
        self.label = label
        self.tag = tag
        self.words = words
    }
}

// MARK: Rendering

/// Every remote design's renderers on this device: one host per design (its sandbox over the
/// files cached from its host) and the one shared rasterizer.
@MainActor
final class PadDesignRendering {
    static let shared = PadDesignRendering()

    let rasterizer = PadDesignRasterizer()
    private var hosts: [PadDesignRef: PadDesignHost] = [:]

    /// A design's renderer, over `source` (its files, fetched by hash and cached here).
    func host(for ref: PadDesignRef, source: @autoclosure () -> any DesignFileSource) -> PadDesignHost {
        if let host = hosts[ref] { return host }
        let surface = DesignSurface(designID: ref.design, source: source(), network: .googleFonts)
        let host = PadDesignHost(designID: ref.design, surface: surface, rasterizer: rasterizer)
        hosts[ref] = host
        return host
    }

    /// Designs that are gone give up everything they held.
    func prune(keeping refs: Set<PadDesignRef>) {
        for ref in Set(hosts.keys).subtracting(refs) { hosts.removeValue(forKey: ref)?.release() }
    }

    /// Web views alive now: every host's live views and the rasterizer's.
    var webViews: Int { hosts.values.reduce(0) { $0 + $1.liveCount } + rasterizer.webViews }
}

/// One design's boards as the canvas draws them: a live view for the board worth one, snapshots
/// for the rest, and the reload of whichever changed.
@MainActor @Observable
final class PadDesignHost {
    struct Board: Equatable {
        var size: CGSize
        var sha: String
        /// Its tweaked props as JSON (canvas.json's `tweaks` for it); nil when it has none.
        var props: String?

        var drawing: String { props.map { sha + "+" + $0 } ?? sha }
    }

    let designID: DesignID
    /// Each board's drawing, as the canvas compares it: moves when its snapshot changes or its
    /// live view comes or goes.
    private(set) var tokens: [DesignPath: Int] = [:]
    /// A pinch is running: every board draws its snapshot until it rests.
    private(set) var zooming = false
    /// The board shown focused (Present, Play).
    private(set) var presented: DesignPath?

    @ObservationIgnored let surface: DesignSurface
    @ObservationIgnored private let rasterizer: PadDesignRasterizer
    @ObservationIgnored private let liveCap: Int
    /// Reads a board's source (for a live reload in place).
    @ObservationIgnored var source: ((DesignPath) async throws -> String)?
    /// A presented board's link asked for another board of the design (Play).
    @ObservationIgnored var linked: ((_ from: DesignPath, _ to: DesignPath) -> Void)?
    /// A live board drew new source: a selection on it is found again where it is now.
    @ObservationIgnored var redrawn: ((DesignPath) -> Void)?
    @ObservationIgnored private var boards: [DesignPath: Board] = [:]
    @ObservationIgnored private var slots: [DesignPath: Slot] = [:]
    @ObservationIgnored private var images = PadDesignImageCache()
    @ObservationIgnored private var stamp: UInt64 = 0
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var zoom: CGFloat = 1
    @ObservationIgnored private var presentedZoom: CGFloat = 1
    @ObservationIgnored private var visible: [DesignPath] = []
    @ObservationIgnored private var selected: DesignPath?
    /// The board a tap is asking about.
    @ObservationIgnored private var asked: DesignPath?
    @ObservationIgnored private var failed: [DesignPath: String] = [:]

    final class Slot {
        let view: DesignBoardView
        var sha: String
        var ready = false
        var wanted: UInt64
        var task: Task<Void, Never>?

        init(view: DesignBoardView, sha: String, wanted: UInt64) {
            self.view = view
            self.sha = sha
            self.wanted = wanted
        }
    }

    init(designID: DesignID, surface: DesignSurface, rasterizer: PadDesignRasterizer, liveCap: Int = DesignTouchLivePlan.liveCap) {
        self.designID = designID
        self.surface = surface
        self.rasterizer = rasterizer
        self.liveCap = liveCap
    }

    var liveCount: Int { slots.count }
    var liveBoards: Set<DesignPath> { Set(slots.keys) }

    /// The live view a board draws in on the canvas, once it has drawn and while no pinch runs.
    fileprivate func liveView(_ path: DesignPath) -> DesignBoardView? {
        guard !zooming, path != presented, let slot = slots[path], slot.ready else { return nil }
        return slot.view
    }

    fileprivate func presentedView() -> DesignBoardView? {
        guard let presented, let slot = slots[presented], slot.ready else { return nil }
        return slot.view
    }

    /// The board's last snapshot, which may be of an older version while a new one renders.
    func image(_ path: DesignPath) -> CGImage? { images.image(path) }

    /// Whether each board draws something current: a ready live view, or a snapshot of its hash.
    func isDrawn(_ paths: [DesignPath]) -> Bool {
        paths.allSatisfy { path in
            guard let board = boards[path] else { return true }
            if let slot = slots[path], slot.ready, slot.sha == board.drawing { return true }
            return images.sha(path) == board.drawing || failed[path] == board.drawing
        }
    }

    // MARK: Boards

    /// The design's boards at a new revision: a changed board reloads in place while live and
    /// renders a new snapshot either way; a removed board leaves; a new one appears.
    func update(_ next: [DesignPath: Board]) {
        let previous = boards
        boards = next
        for path in Set(previous.keys).subtracting(next.keys) {
            releaseSlot(path)
            images.remove(path)
            tokens.removeValue(forKey: path)
            failed.removeValue(forKey: path)
        }
        for (path, board) in next {
            guard let old = previous[path], old != board, let slot = slots[path] else { continue }
            if old.size != board.size {
                releaseSlot(path)
            } else if slot.ready, slot.sha != board.drawing {
                reload(path, slot: slot)
            }
        }
        plan()
    }

    /// The boards on screen (nearest the middle first), the selected one, and the zoom, once the
    /// canvas rests.
    func show(visible: [DesignPath], selected: DesignPath?, zoom: CGFloat) {
        self.visible = visible
        self.selected = selected
        if self.zoom != zoom {
            self.zoom = zoom
            for (path, slot) in slots where path != presented { slot.view.zoom = zoom }
        }
        plan()
    }

    func setZooming(_ zooming: Bool) {
        guard self.zooming != zooming else { return }
        self.zooming = zooming
        for path in slots.keys { bump(path) }
    }

    /// Shown, the design takes a live view again; hidden, it gives it up and keeps its snapshots.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { for path in Array(slots.keys) { releaseSlot(path) } }
        plan()
    }

    func release() {
        isActive = false
        for path in Array(slots.keys) { releaseSlot(path) }
        images.removeAll()
    }

    /// Shows `path` focused (nil: back to the canvas). While it is, it is the only live board.
    func present(_ path: DesignPath?) {
        guard presented != path else { return }
        let previous = presented
        presented = path
        if let previous, let slot = slots[previous] { slot.view.zoom = zoom }
        if let path { bump(path) }
        if let previous { bump(previous) }
        plan()
    }

    func setPresentedZoom(_ zoom: CGFloat) {
        presentedZoom = zoom
        if let presented, let slot = slots[presented], slot.view.zoom != zoom { slot.view.zoom = zoom }
    }

    // MARK: Selection

    /// The element drawn under `point` (the board's own points) once the board has a live view
    /// to ask; nil when nothing named is there, or the board can't draw.
    func hitTest(_ path: DesignPath, at point: CGPoint) async -> PadDesignPick? {
        guard let view = await readyView(path) else { return nil }
        return await view.hitTest(at: point).flatMap { PadDesignPick($0, on: path) }
    }

    /// Elements `tids` of a live board where it draws them now; nil without a live view.
    func locate(_ path: DesignPath, tids: [Int]) async -> [Int: PadDesignPick]? {
        guard let slot = slots[path], slot.ready else { return nil }
        var found: [Int: PadDesignPick] = [:]
        for tid in tids {
            if let hit = await slot.view.element(tid: tid), let pick = PadDesignPick(hit, on: path) { found[tid] = pick }
        }
        return found
    }

    // MARK: Tweak previews

    func previewStyle(_ path: DesignPath, _ changes: [Int: [String: String?]]) async -> Bool {
        guard let slot = slots[path], slot.ready else { return false }
        return await slot.view.previewStyle(changes) > 0
    }

    func previewProps(_ path: DesignPath, _ json: String) async -> Bool {
        guard let slot = slots[path], slot.ready else { return false }
        return await slot.view.previewProps(json)
    }

    func endPreview(_ path: DesignPath) async {
        guard let slot = slots[path], slot.ready else { return }
        await slot.view.endPreview()
    }

    /// The board's live view once it has drawn, making it wanted if it has none.
    private func readyView(_ path: DesignPath) async -> DesignBoardView? {
        guard isActive, boards[path] != nil else { return nil }
        if slots[path] == nil {
            asked = path
            plan()
        }
        for _ in 0..<3 {
            guard let slot = slots[path] else { return nil }
            if slot.ready { return slot.view }
            await slot.task?.value
        }
        return nil
    }

    // MARK: Planning

    private func plan() {
        guard isActive else { return }
        stamp += 1
        let wanted: [DesignPath]
        if let presented, boards[presented] != nil {
            for path in Array(slots.keys) where path != presented { releaseSlot(path) }
            wanted = [presented]
        } else {
            wanted = DesignTouchLivePlan.wanted(visible: visible.filter { boards[$0] != nil },
                                              selected: selected.flatMap { boards[$0] != nil ? $0 : nil },
                                              asked: asked.flatMap { boards[$0] != nil ? $0 : nil }, zoom: zoom, cap: liveCap)
        }
        for path in wanted { slots[path]?.wanted = stamp }
        let assignment = DesignTouchLivePlan.assign(slots: slots.mapValues(\.wanted), wanted: wanted, cap: liveCap)
        for path in assignment.evict { releaseSlot(path) }
        for path in assignment.create { makeSlot(path) }
        for path in visible where slots[path] == nil { rasterizeIfStale(path) }
    }

    private func makeSlot(_ path: DesignPath) {
        guard let board = boards[path] else { return }
        let view = DesignBoardView(surface: surface, board: path, size: board.size)
        view.zoom = path == presented ? presentedZoom : zoom
        view.isUserInteractionEnabled = path == presented
        let slot = Slot(view: view, sha: board.drawing, wanted: stamp)
        slots[path] = slot
        // A web view draws only in a window: until the canvas holds it, it waits on the stage.
        PadDesignStage.shared.hold(view)
        slot.task = Task { [weak self, weak slot] in
            guard let slot else { return }
            do {
                try await slot.view.load()
            } catch {
                guard let self, self.slots[path] === slot else { return }
                self.failed[path] = slot.sha
                self.releaseSlot(path)
                return
            }
            guard let self, self.slots[path] === slot, !Task.isCancelled else { return }
            if let current = self.boards[path], current.drawing != slot.sha {
                slot.ready = true
                self.reload(path, slot: slot)
            } else {
                await self.snapshot(path, slot: slot)
                guard self.slots[path] === slot else { return }
                slot.ready = true
                self.redrawn?(path)
            }
            if self.asked == path { self.asked = nil }
            self.bump(path)
        }
        slot.view.onEvent = { [weak self, weak slot] event in
            guard let self, let slot, self.slots[path] === slot else { return }
            switch event {
            case .terminated:
                self.releaseSlot(path)
                self.plan()
            case .link(let target):
                self.linked?(path, target)
            default:
                break
            }
        }
    }

    private func releaseSlot(_ path: DesignPath) {
        guard let slot = slots.removeValue(forKey: path) else { return }
        slot.task?.cancel()
        slot.view.onEvent = nil
        slot.view.removeFromSuperview()
        if slot.ready { bump(path) }
    }

    private func reload(_ path: DesignPath, slot: Slot) {
        guard let board = boards[path] else { return }
        slot.sha = board.drawing
        slot.task?.cancel()
        slot.task = Task { [weak self, weak slot] in
            guard let self, let slot, let source = self.source else { return }
            do {
                let text = try await source(path)
                guard self.slots[path] === slot, !Task.isCancelled else { return }
                try await slot.view.replaceSource(text, props: board.props ?? "{}")
                self.redrawn?(path)
            } catch DesignBoardError.refused {
                // Source the runtime refuses leaves the board as it was.
            } catch {
                guard self.slots[path] === slot, !Task.isCancelled else { return }
                self.releaseSlot(path)
                self.plan()
                return
            }
            guard self.slots[path] === slot, !Task.isCancelled else { return }
            await self.snapshot(path, slot: slot)
        }
    }

    private func snapshot(_ path: DesignPath, slot: Slot) async {
        let width = min(slot.view.boardSize.width, PadDesignRasterizer.snapshotWidth)
        guard let image = try? await slot.view.snapshot(width: width), slots[path] === slot else { return }
        images.store(image, sha: slot.sha, for: path, keeping: onScreen)
        bump(path)
    }

    private func rasterizeIfStale(_ path: DesignPath) {
        guard let board = boards[path], images.sha(path) != board.drawing, failed[path] != board.drawing else { return }
        let drawing = board.drawing
        rasterizer.enqueue(PadDesignRasterizer.Job(key: "\(designID.rawValue)/\(path.rawValue)", surface: surface, path: path,
                                                   size: board.size, wanted: { [weak self] in
                                                       guard let self, self.isActive, self.slots[path] == nil,
                                                             self.visible.contains(path) else { return false }
                                                       return self.boards[path]?.drawing == drawing && self.images.sha(path) != drawing
                                                   }) { [weak self] image in
            guard let self else { return }
            guard let image else { self.failed[path] = drawing; self.bump(path); return }
            guard self.boards[path]?.drawing == drawing else { return }
            self.images.store(image, sha: drawing, for: path, keeping: self.onScreen)
            self.bump(path)
        })
    }

    private var onScreen: Set<DesignPath> { Set(visible).union(slots.keys) }

    private func bump(_ path: DesignPath) {
        tokens[path, default: 0] += 1
    }

    // MARK: Leaving the canvas

    /// The boards as PNGs for another thread (Split View's "Send to the thread"): each board's
    /// snapshot as drawn now, named after it; boards not drawn yet are left out.
    func pngs(_ paths: [DesignPath]) -> [(data: Data, name: String)] {
        paths.compactMap { path in
            guard let image = images.image(path), let data = UIImage(cgImage: image).pngData() else { return nil }
            return (data, path.stem + ".png")
        }
    }
}

/// The last snapshot of each board. Past its budget the least recently stored go first, never
/// one of the boards on screen.
struct PadDesignImageCache {
    /// Bytes of pixels kept per design: less than the Mac's, as an iPad has less memory to spare.
    static let budget = 64 * 1024 * 1024
    private var entries: [DesignPath: (sha: String, image: CGImage)] = [:]
    private var order: [DesignPath] = []
    private var bytes = 0

    func image(_ path: DesignPath) -> CGImage? { entries[path]?.image }
    func sha(_ path: DesignPath) -> String? { entries[path]?.sha }

    mutating func store(_ image: CGImage, sha: String, for path: DesignPath, keeping protected: Set<DesignPath> = []) {
        remove(path)
        entries[path] = (sha, image)
        order.append(path)
        bytes += image.bytesPerRow * image.height
        var index = 0
        while bytes > Self.budget, index < order.count {
            let candidate = order[index]
            if candidate == path || protected.contains(candidate) { index += 1; continue }
            remove(candidate)
        }
    }

    mutating func remove(_ path: DesignPath) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        bytes -= entry.image.bytesPerRow * entry.image.height
        order.removeAll { $0 == path }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }
}

// MARK: Rasterizer

/// Renders boards to snapshots one at a time, in a view of its own on the stage: every board on
/// screen that has no live view.
@MainActor
final class PadDesignRasterizer {
    /// Snapshots are at most this many points wide (twice as many pixels): enough for a board at
    /// the canvas's zooms, and a sixth of a full-size board's memory.
    static let snapshotWidth: CGFloat = 640

    struct Job {
        let key: String
        let surface: DesignSurface
        let path: DesignPath
        let size: CGSize
        let wanted: () -> Bool
        let done: (CGImage?) -> Void
    }

    private var queue: [Job] = []
    private var running = false
    /// Its web view, while one renders.
    private(set) var webViews = 0

    func enqueue(_ job: Job) {
        queue.removeAll { $0.key == job.key }
        queue.append(job)
        run()
    }

    private func run() {
        guard !running else { return }
        while let job = queue.first, !job.wanted() { queue.removeFirst() }
        guard !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = true
        Task { [weak self] in
            let view = DesignBoardView(surface: job.surface, board: job.path, size: job.size)
            view.isUserInteractionEnabled = false
            PadDesignStage.shared.hold(view)
            self?.webViews = 1
            var image: CGImage?
            do {
                try await view.load()
                image = try await view.snapshot(width: min(job.size.width, Self.snapshotWidth))
            } catch {
                image = nil
            }
            view.removeFromSuperview()
            guard let self else { return }
            self.webViews = 0
            self.running = false
            job.done(image)
            self.run()
        }
    }
}

/// Where web views wait while no canvas holds them: a view at the back of the key window, under
/// the app's content. WebKit draws a page only in a window, and a snapshot needs one drawn; it
/// sits below the status bar and the window's top inset, where iOS paints tiles at low resolution.
@MainActor
final class PadDesignStage {
    static let shared = PadDesignStage()
    private let stage: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: PadDesignStage.top, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        view.clipsToBounds = false
        view.accessibilityElementsHidden = true
        return view
    }()

    /// Clear of the window's top inset.
    static let top: CGFloat = 160

    func hold(_ view: UIView) {
        attach()
        view.removeFromSuperview()
        view.frame.origin = .zero
        stage.addSubview(view)
    }

    private func attach() {
        guard stage.window == nil else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.insertSubview(stage, at: 0)
    }
}

// MARK: Views

/// A board's page in its canvas frame: its live view, else its snapshot, else nothing yet.
/// `content` (the board's token) tells SwiftUI it changed.
struct PadDesignBoardSlot: View {
    let host: PadDesignHost
    let path: DesignPath
    let zoom: CGFloat
    let content: Int

    var body: some View {
        if let view = host.liveView(path) {
            PadLiveBoard(view: view, zoom: zoom, interactive: false)
        } else if let image = host.image(path) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

/// The presented board's page (Present, Play): its live view, which takes touches so its links
/// work, else its snapshot.
struct PadDesignPresentedSlot: View {
    let host: PadDesignHost
    let path: DesignPath
    let zoom: CGFloat
    let content: Int

    var body: some View {
        if let view = host.presentedView() {
            PadLiveBoard(view: view, zoom: zoom, interactive: true)
                .onAppear { host.setPresentedZoom(zoom) }
                .onChange(of: zoom) { _, zoom in host.setPresentedZoom(zoom) }
        } else if let image = host.image(path) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

/// Hosts a live board's view. On the canvas it takes no touches (the canvas takes them all);
/// presented, it takes them, so a tap reaches the page and its links.
private struct PadLiveBoard: UIViewRepresentable {
    let view: DesignBoardView
    let zoom: CGFloat
    let interactive: Bool

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.show(view)
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        container.show(view)
        if !interactive, view.zoom != zoom { view.zoom = zoom }
        view.isUserInteractionEnabled = interactive
        container.isUserInteractionEnabled = interactive
        container.setNeedsLayout()
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.clear()
    }

    final class Container: UIView {
        private weak var board: DesignBoardView?

        func show(_ view: DesignBoardView) {
            guard board !== view || view.superview !== self else { return }
            clear()
            board = view
            view.removeFromSuperview()
            addSubview(view)
            setNeedsLayout()
        }

        func clear() {
            if let board, board.superview === self {
                // Back to the stage, still drawn, until its host lets it go.
                PadDesignStage.shared.hold(board)
            }
            board = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let board, board.frame != bounds { board.frame = bounds }
        }
    }
}

/// Tweak's live previews go to the board's live view.
extension PadDesignHost: DesignTweakPreviews {}

// MARK: Thumbnails

/// The Designs list's cards: each design's first board, rendered by the shared rasterizer when its
/// hash is new, from the files the host serves.
@MainActor @Observable
final class PadDesignThumbnails {
    static let shared = PadDesignThumbnails()

    /// Moves when a card's image lands.
    private(set) var versions: [PadDesignRef: Int] = [:]
    @ObservationIgnored private var images: [PadDesignRef: (sha: String, image: CGImage)] = [:]
    @ObservationIgnored private var asked: [PadDesignRef: String] = [:]

    func image(_ ref: PadDesignRef) -> CGImage? { images[ref]?.image }

    /// Renders the design's first board unless it is drawn at `sha` already.
    func update(_ ref: PadDesignRef, path: DesignPath, size: CGSize, sha: String, source: @autoclosure () -> any DesignFileSource) {
        guard images[ref]?.sha != sha, asked[ref] != sha, size.width > 0, size.height > 0 else { return }
        asked[ref] = sha
        let surface = PadDesignRendering.shared.host(for: ref, source: source()).surface
        PadDesignRendering.shared.rasterizer.enqueue(PadDesignRasterizer.Job(
            key: "thumbnail/\(ref.host.uuidString)/\(ref.design.rawValue)", surface: surface, path: path, size: size,
            wanted: { [weak self] in self?.asked[ref] == sha }) { [weak self] image in
                guard let self, self.asked[ref] == sha, let image else { return }
                self.images[ref] = (sha, image)
                self.versions[ref, default: 0] += 1
            })
    }
}

/// A card's thumbnail: the first board's snapshot, top-aligned in its frame.
struct PadDesignThumbnail: View {
    let image: CGImage?
    /// The card's image version, so a new one redraws the card.
    let version: Int

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
