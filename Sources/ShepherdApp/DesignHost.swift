import AppKit
import SwiftUI
import DesignSurfaceKit
import ShepherdCore
import ShepherdProtocol

// The app's board rendering, and the only file that imports DesignSurfaceKit (as TerminalHost is
// for TerminalSurfaceKit), so the renderer's API drift breaks exactly one file.
//
// A design on screen keeps at most `DesignLivePlan.liveCap` live web views: the selected board,
// the board under the pointer with Select, and the boards nearest the middle of the view,
// recycled least recently wanted first. Selection asks a live board what is under a point
// (`hitTest`), so the board under the pointer is always one of them. A board presented (Present,
// Play) is the only live one while it is shown, and takes its own events there. Every
// other board draws its snapshot, taken by one shared off-screen view (`DesignRasterizer`), so
// the app never holds more than six web views however large the canvas. A hidden design gives
// its live views up and keeps its snapshots.

// MARK: Plan

/// Which boards get a live view, and which views make room: pure, so the rules are tested
/// without WebKit.
enum DesignLivePlan {
    /// Live views for the design on screen; with the rasterizer's one view, six web views at most.
    static let liveCap = 5
    /// Below this zoom boards draw from their snapshots; the selected board stays live down to
    /// `selectedThreshold`.
    static let threshold: CGFloat = 0.25
    static let selectedThreshold: CGFloat = 0.1

    /// The boards to keep live, most wanted first: the selected board, the board under the
    /// pointer (Select asks it what is there, at any zoom), then the visible boards in the order
    /// given (nearest the middle first).
    static func wanted(visible: [DesignPath], selected: DesignPath?, hovered: DesignPath? = nil, zoom: CGFloat,
                       cap: Int = liveCap) -> [DesignPath] {
        var result: [DesignPath] = []
        if let selected, zoom >= selectedThreshold { result.append(selected) }
        if let hovered, hovered != selected { result.append(hovered) }
        if zoom >= threshold {
            for path in visible where !result.contains(path) && result.count < cap { result.append(path) }
        }
        return Array(result.prefix(cap))
    }

    struct Assignment: Equatable {
        /// Views to give up, least recently wanted first.
        var evict: [DesignPath]
        /// Boards that need a view.
        var create: [DesignPath]
    }

    /// Makes room for the wanted boards among `slots` (each live board and when it was last
    /// wanted): a board keeps its view; a new one takes a free slot, else the least recently
    /// wanted slot no wanted board holds.
    static func assign(slots: [DesignPath: UInt64], wanted: [DesignPath], cap: Int = liveCap) -> Assignment {
        let missing = wanted.filter { slots[$0] == nil }
        let free = max(0, cap - slots.count)
        let evictable = slots.filter { !wanted.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .map(\.key)
        return Assignment(evict: Array(evictable.prefix(max(0, missing.count - free))), create: missing)
    }
}

// MARK: Selection

extension DesignElementPick {
    /// What a board's hit test reported, as the canvas and the view record take it; nil when the
    /// grammar can't name it on this board.
    init?(_ hit: DesignHit, on board: DesignPath) {
        guard let id = hit.id(on: board) else { return nil }
        self.init(board: board, id: id, rect: hit.rect, kind: hit.kind, label: hit.label, tag: hit.tag, words: hit.name ?? hit.label)
    }
}

// MARK: Rendering

/// What boards may load beyond the design's own files (`DesignSandbox.Network`).
enum DesignRenderingNetwork {
    /// Google Fonts, as boards link them.
    case googleFonts
    /// Nothing (tests).
    case none

    var sandbox: DesignSandbox.Network {
        switch self {
        case .googleFonts: .googleFonts
        case .none: .none
        }
    }
}

/// Every design's renderers: one host per design, the shared rasterizer, and the Designs page's
/// thumbnails. Owned by the view model.
@MainActor
final class DesignRendering {
    let rasterizer = DesignRasterizer()
    private var hosts: [DesignID: DesignHost] = [:]
    private let folder: (DesignID) -> URL?
    private let network: DesignSandbox.Network
    /// The Designs page's cards' first boards.
    let thumbnails: DesignThumbnails

    /// Live views a design on screen may hold (previews take none: their captures can't draw a
    /// web view, so every board draws its snapshot).
    let liveCap: Int

    init(folder: @escaping (DesignID) -> URL?, network: DesignRenderingNetwork = .googleFonts, liveCap: Int = DesignLivePlan.liveCap) {
        self.folder = folder
        self.network = network.sandbox
        self.liveCap = liveCap
        thumbnails = DesignThumbnails(rasterizer: rasterizer)
        thumbnails.surface = { [weak self] id in self?.surface(for: id) }
        rasterizer.countWebViews = { [weak self] in self?.webViews ?? 0 }
    }

    private var surfaces: [DesignID: DesignSurface] = [:]

    func surface(for id: DesignID) -> DesignSurface? {
        if let surface = surfaces[id] { return surface }
        guard let folder = folder(id) else { return nil }
        let surface = DesignSurface(designID: id, folder: folder, network: network)
        surfaces[id] = surface
        return surface
    }

    func host(for id: DesignID) -> DesignHost? {
        if let host = hosts[id] { return host }
        guard let surface = surface(for: id) else { return nil }
        let host = DesignHost(designID: id, surface: surface, rasterizer: rasterizer, liveCap: liveCap)
        hosts[id] = host
        return host
    }

    /// Designs that are gone give up everything they held.
    func prune(keeping ids: Set<DesignID>) {
        for id in Set(hosts.keys).subtracting(ids) { hosts.removeValue(forKey: id)?.release() }
        for id in Set(surfaces.keys).subtracting(ids) { surfaces.removeValue(forKey: id) }
        thumbnails.prune(keeping: ids)
    }

    /// Web views alive now: every host's live views and the rasterizer's.
    var webViews: Int { hosts.values.reduce(0) { $0 + $1.liveCount } + rasterizer.webViews }
}

/// One design's boards as the canvas draws them: live views for the few that are worth one,
/// snapshots for the rest, and the reload of whichever changed.
@MainActor @Observable
final class DesignHost {
    struct Board: Equatable {
        var size: CGSize
        /// The file's hash.
        var sha: String
        /// Its tweaked props as JSON (canvas.json's `tweaks` for it); nil when it has none.
        var props: String?

        init(size: CGSize, sha: String, props: String? = nil) {
            self.size = size
            self.sha = sha
            self.props = props
        }

        /// What the board draws: its file and its props. Snapshots and live views are kept by it.
        var drawing: String { props.map { sha + "+" + $0 } ?? sha }
    }

    let designID: DesignID
    /// Each board's drawing, as the canvas compares it: moves when its snapshot changes or its
    /// live view comes or goes.
    private(set) var tokens: [DesignPath: Int] = [:]
    /// A zoom gesture is running: every board draws its snapshot until it rests.
    private(set) var zooming = false

    @ObservationIgnored let surface: DesignSurface
    @ObservationIgnored private let rasterizer: DesignRasterizer
    @ObservationIgnored private let liveCap: Int
    /// Reads a board's source at the host (for a live reload).
    @ObservationIgnored var source: ((DesignPath) async throws -> String)?
    @ObservationIgnored private var boards: [DesignPath: Board] = [:]
    @ObservationIgnored private var slots: [DesignPath: Slot] = [:]
    @ObservationIgnored private var images = DesignImageCache()
    @ObservationIgnored private var stamp: UInt64 = 0
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var zoom: CGFloat = 1
    @ObservationIgnored private var visible: [DesignPath] = []
    @ObservationIgnored private var selected: DesignPath?
    /// The board under the pointer with Select.
    @ObservationIgnored private var hovered: DesignPath?
    /// The board shown focused (Present, Play): the one live view while it is, drawn by the
    /// presentation at its own zoom.
    private(set) var presented: DesignPath?
    @ObservationIgnored private var presentedZoom: CGFloat = 1
    /// Told when a live board's link asks for another board of the design (Play); the host never
    /// navigates.
    @ObservationIgnored var linked: ((_ from: DesignPath, _ to: DesignPath) -> Void)?
    /// Told when a live board draws new source (a live reload, or a fresh load of a new version),
    /// so a selection on it is found again where it is drawn now.
    @ObservationIgnored var redrawn: ((DesignPath) -> Void)?
    /// Boards whose render failed at a hash: not tried again until it changes.
    @ObservationIgnored private var failed: [DesignPath: String] = [:]
    /// Tests: snapshots taken, and live reloads made.
    @ObservationIgnored private(set) var snapshotsTaken = 0
    @ObservationIgnored private(set) var reloads = 0

    final class Slot {
        let view: DesignBoardView
        /// The hash the view shows once it is ready.
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

    init(designID: DesignID, surface: DesignSurface, rasterizer: DesignRasterizer, liveCap: Int = DesignLivePlan.liveCap) {
        self.designID = designID
        self.surface = surface
        self.rasterizer = rasterizer
        self.liveCap = liveCap
    }

    var liveCount: Int { slots.count }
    var liveBoards: Set<DesignPath> { Set(slots.keys) }

    /// The live view a board draws in on the canvas, once it has drawn and while no zoom gesture
    /// runs; the presented board draws its snapshot there.
    func liveView(_ path: DesignPath) -> DesignBoardView? {
        guard !zooming, path != presented, let slot = slots[path], slot.ready else { return nil }
        return slot.view
    }

    /// The presented board's live view, once it has drawn.
    func presentedView() -> DesignBoardView? {
        guard let presented, let slot = slots[presented], slot.ready else { return nil }
        return slot.view
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

    /// The zoom the presentation draws its board at.
    func setPresentedZoom(_ zoom: CGFloat) {
        presentedZoom = zoom
        if let presented, let slot = slots[presented], slot.view.zoom != zoom { slot.view.zoom = zoom }
    }

    /// The board's last snapshot, which may be of an older version while a new one renders.
    func image(_ path: DesignPath) -> CGImage? { images.image(path) }

    /// Whether each board draws something current: a ready live view, or a snapshot of its hash.
    func isDrawn(_ paths: [DesignPath]) -> Bool {
        paths.allSatisfy { path in
            guard let board = boards[path] else { return true }
            if let slot = slots[path], slot.ready, slot.sha == board.drawing { return true }
            return images.sha(path) == board.drawing
        }
    }

    // MARK: Boards

    /// The design's boards at a new revision. A changed board reloads in place while live, and
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
            guard let old = previous[path], old != board else { continue }
            if let slot = slots[path] {
                if old.size != board.size {
                    // A new size lays the page out again: load it afresh.
                    releaseSlot(path)
                } else if slot.ready, slot.sha != board.drawing {
                    reload(path, slot: slot)
                }
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

    /// Shown, the design takes live views again; hidden, it gives them up and keeps its snapshots.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { for path in Array(slots.keys) { releaseSlot(path) } }
        plan()
    }

    /// Gives up every view and snapshot (the design is gone).
    func release() {
        isActive = false
        for path in Array(slots.keys) { releaseSlot(path) }
        images.removeAll()
    }

    // MARK: Selection

    /// The board under the pointer with Select (nil once it leaves the boards): it takes a live
    /// view so what is under the pointer can be named.
    func hover(_ path: DesignPath?) {
        guard hovered != path else { return }
        hovered = path
        plan()
    }

    /// The element drawn under `point` (the board's own points) on a board, once the board has a
    /// live view to ask; nil when nothing named is there, or the board can't draw.
    func hitTest(_ path: DesignPath, at point: CGPoint) async -> DesignElementPick? {
        guard let view = await readyView(path) else { return nil }
        return await view.hitTest(at: point).flatMap { DesignElementPick($0, on: path) }
    }

    /// Elements `tids` of a live board where it draws them now; an element it no longer draws is
    /// missing. Nil when the board has no live view to ask.
    func locate(_ path: DesignPath, tids: [Int]) async -> [Int: DesignElementPick]? {
        guard let slot = slots[path], slot.ready else { return nil }
        var found: [Int: DesignElementPick] = [:]
        for tid in tids {
            if let hit = await slot.view.element(tid: tid), let pick = DesignElementPick(hit, on: path) { found[tid] = pick }
        }
        return found
    }

    // MARK: Tweak previews

    /// Shows style changes in a board's live view without writing them (a tweak being dragged).
    /// False when the board has no live view drawn: its snapshot shows the change once written.
    func previewStyle(_ path: DesignPath, _ changes: [Int: [String: String?]]) async -> Bool {
        guard let slot = slots[path], slot.ready else { return false }
        return await slot.view.previewStyle(changes) > 0
    }

    /// Draws a board's live view with props `json` without writing them.
    func previewProps(_ path: DesignPath, _ json: String) async -> Bool {
        guard let slot = slots[path], slot.ready else { return false }
        return await slot.view.previewProps(json)
    }

    /// Puts back what a board's previews changed (a tweak that wasn't kept).
    func endPreview(_ path: DesignPath) async {
        guard let slot = slots[path], slot.ready else { return }
        await slot.view.endPreview()
    }

    /// The board's live view once it has drawn, making it wanted if it has none.
    private func readyView(_ path: DesignPath) async -> DesignBoardView? {
        guard isActive, boards[path] != nil else { return nil }
        if slots[path] == nil {
            hovered = path
            plan()
        }
        // A view still loading answers once it has drawn.
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
            // Presented, a board is the one live view: the canvas under it draws snapshots.
            for path in Array(slots.keys) where path != presented { releaseSlot(path) }
            wanted = Array([presented].prefix(liveCap))
        } else {
            wanted = DesignLivePlan.wanted(visible: visible.filter { boards[$0] != nil },
                                           selected: selected.flatMap { boards[$0] != nil ? $0 : nil },
                                           hovered: hovered.flatMap { boards[$0] != nil ? $0 : nil }, zoom: zoom, cap: liveCap)
        }
        for path in wanted { slots[path]?.wanted = stamp }
        let assignment = DesignLivePlan.assign(slots: slots.mapValues(\.wanted), wanted: wanted, cap: liveCap)
        for path in assignment.evict { releaseSlot(path) }
        for path in assignment.create { makeSlot(path) }
        // Boards on screen without a view draw from snapshots; render the stale ones.
        for path in visible where slots[path] == nil { rasterizeIfStale(path) }
    }

    private func makeSlot(_ path: DesignPath) {
        guard let board = boards[path] else { return }
        let view = DesignBoardView(surface: surface, board: path, size: board.size)
        view.zoom = path == presented ? presentedZoom : zoom
        let slot = Slot(view: view, sha: board.drawing, wanted: stamp)
        slots[path] = slot
        rasterizer.noteWebViews()
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
                // Written after the view read the file: show what is there now.
                slot.ready = true
                self.reload(path, slot: slot)
            } else {
                // Its snapshot first, so the board never swaps to an older picture later.
                await self.snapshot(path, slot: slot)
                guard self.slots[path] === slot else { return }
                slot.ready = true
                self.redrawn?(path)
            }
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

    /// A live board's new source, in place: no navigation, its state kept. Source the runtime
    /// refuses (logic that doesn't compile) leaves the board as it was.
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
                self.reloads += 1
                self.redrawn?(path)
            } catch DesignBoardError.refused {
                self.reloads += 1
            } catch {
                guard self.slots[path] === slot, !Task.isCancelled else { return }
                // Anything else (the page went away): load it afresh.
                self.releaseSlot(path)
                self.plan()
                return
            }
            guard self.slots[path] === slot, !Task.isCancelled else { return }
            await self.snapshot(path, slot: slot)
        }
    }

    private func snapshot(_ path: DesignPath, slot: Slot) async {
        guard let image = try? await slot.view.snapshot() else { return }
        guard slots[path] === slot else { return }
        snapshotsTaken += 1
        images.store(image, sha: slot.sha, for: path, keeping: onScreen)
        bump(path)
    }

    private func rasterizeIfStale(_ path: DesignPath) {
        let drawing = boards[path]?.drawing
        guard let board = boards[path], let drawing, images.sha(path) != drawing, failed[path] != drawing else { return }
        rasterizer.enqueue(DesignRasterizer.Job(key: "\(designID.rawValue)/\(path.rawValue)", surface: surface, path: path,
                                                size: board.size, sha: drawing, priority: .canvas,
                                                wanted: { [weak self] in
                                                    guard let self, self.isActive, self.slots[path] == nil,
                                                          self.visible.contains(path) else { return false }
                                                    return self.boards[path]?.drawing == drawing && self.images.sha(path) != drawing
                                                }) { [weak self] image in
            guard let self else { return }
            guard let image else { self.failed[path] = drawing; return }
            guard self.boards[path]?.drawing == drawing else { return }
            self.snapshotsTaken += 1
            self.images.store(image, sha: drawing, for: path, keeping: self.onScreen)
            self.bump(path)
        })
    }

    /// The boards whose snapshots must stay: those on screen and those live.
    private var onScreen: Set<DesignPath> { Set(visible).union(slots.keys) }

    private func bump(_ path: DesignPath) {
        tokens[path, default: 0] += 1
    }
}

/// The last snapshot of each board. Past its budget the least recently stored go first, never
/// one of the boards on screen.
struct DesignImageCache {
    /// Bytes of pixels kept per design.
    static let budget = 160 * 1024 * 1024
    private var entries: [DesignPath: (sha: String, image: CGImage)] = [:]
    private var order: [DesignPath] = []
    private var bytes = 0

    func image(_ path: DesignPath) -> CGImage? { entries[path]?.image }
    func sha(_ path: DesignPath) -> String? { entries[path]?.sha }
    var count: Int { entries.count }

    mutating func store(_ image: CGImage, sha: String, for path: DesignPath, keeping protected: Set<DesignPath> = []) {
        remove(path)
        entries[path] = (sha, image)
        order.append(path)
        bytes += Self.cost(image)
        var index = 0
        while bytes > Self.budget, index < order.count {
            let candidate = order[index]
            if candidate == path || protected.contains(candidate) { index += 1; continue }
            remove(candidate)
        }
    }

    mutating func remove(_ path: DesignPath) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        bytes -= Self.cost(entry.image)
        order.removeAll { $0 == path }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    static func cost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }
}

// MARK: Rasterizer

/// Renders boards to snapshots one at a time in a view of its own, off screen: the canvas's
/// boards without a live view, then the Designs page's thumbnails.
@MainActor
final class DesignRasterizer {
    enum Priority: Int, Comparable {
        case canvas, thumbnail
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    struct Job {
        let key: String
        let surface: DesignSurface
        let path: DesignPath
        let size: CGSize
        let sha: String
        let priority: Priority
        /// Asked as the job starts: false skips it.
        let wanted: () -> Bool
        /// The snapshot, or nil when the board could not render.
        let done: (CGImage?) -> Void

        init(key: String, surface: DesignSurface, path: DesignPath, size: CGSize, sha: String, priority: Priority,
             wanted: @escaping () -> Bool, done: @escaping (CGImage?) -> Void) {
            self.key = key
            self.surface = surface
            self.path = path
            self.size = size
            self.sha = sha
            self.priority = priority
            self.wanted = wanted
            self.done = done
        }
    }

    private var queue: [Job] = []
    private var running = false
    /// Its web view, while one renders.
    private(set) var webViews = 0
    /// Tests: the most web views alive at once, across every host.
    private(set) var peakWebViews = 0
    /// Renders waiting.
    var pending: Int { queue.count + (running ? 1 : 0) }
    /// Every host's views, to track the peak.
    var countWebViews: (() -> Int)?

    func enqueue(_ job: Job) {
        queue.removeAll { $0.key == job.key }
        let index = queue.firstIndex { $0.priority > job.priority } ?? queue.endIndex
        queue.insert(job, at: index)
        run()
    }

    /// Tests: starts the peak over from what is alive now.
    func resetPeak() { peakWebViews = countWebViews?() ?? webViews }

    func noteWebViews() {
        peakWebViews = max(peakWebViews, countWebViews?() ?? webViews)
    }

    var isIdle: Bool { !running && queue.isEmpty }

    private func run() {
        guard !running else { return }
        while let job = queue.first, !job.wanted() { queue.removeFirst() }
        guard !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = true
        Task { [weak self] in
            let view = DesignBoardView(surface: job.surface, board: job.path, size: job.size)
            self?.webViews = 1
            self?.noteWebViews()
            var image: CGImage?
            do {
                try await view.load()
                image = try await view.snapshot()
            } catch {
                image = nil
            }
            guard let self else { return }
            self.webViews = 0
            self.running = false
            job.done(image)
            self.run()
        }
    }
}

// MARK: Thumbnails

/// The Designs page's cards: each design's first board (`order` first), rendered by the
/// rasterizer whenever its hash changes.
@MainActor @Observable
final class DesignThumbnails {
    struct Entry: Equatable {
        var path: DesignPath
        var size: CGSize
        var sha: String
        /// Moves when a new image lands.
        var version = 0
    }

    private(set) var entries: [DesignID: Entry] = [:]
    @ObservationIgnored private var images: [DesignID: (sha: String, image: CGImage)] = [:]
    @ObservationIgnored private let rasterizer: DesignRasterizer
    @ObservationIgnored var surface: ((DesignID) -> DesignSurface?)?

    init(rasterizer: DesignRasterizer) {
        self.rasterizer = rasterizer
    }

    func image(_ id: DesignID) -> CGImage? { images[id]?.image }

    /// A design's first board from its snapshot; renders it when its hash is new.
    func update(_ id: DesignID, snapshot: DesignSnapshot) {
        guard let path = snapshot.index.order.first(where: { snapshot.index.boards[$0] != nil }) ?? snapshot.index.boards.keys.sorted().first,
              let board = snapshot.index.boards[path], let sha = snapshot.boards[path] else {
            entries.removeValue(forKey: id)
            images.removeValue(forKey: id)
            return
        }
        let size = CGSize(width: board.w, height: board.h)
        var entry = entries[id] ?? Entry(path: path, size: size, sha: sha)
        entry.path = path
        entry.size = size
        entry.sha = sha
        if entries[id] != entry { entries[id] = entry }
        guard images[id]?.sha != sha, let surface = surface?(id) else { return }
        let width = min(size.width, AppLayout.designThumbnailPixelWidth)
        rasterizer.enqueue(DesignRasterizer.Job(key: "thumbnail/\(id.rawValue)", surface: surface, path: path, size: size, sha: sha,
                                                priority: .thumbnail, wanted: { [weak self] in
                                                    self?.entries[id]?.sha == sha && self?.images[id]?.sha != sha
                                                }) { [weak self] image in
            guard let self, let image, self.entries[id]?.sha == sha else { return }
            self.images[id] = (sha, image.scaled(toWidth: width))
            self.entries[id]?.version += 1
        })
    }

    func prune(keeping ids: Set<DesignID>) {
        for id in Set(entries.keys).subtracting(ids) { entries.removeValue(forKey: id) }
        for id in Set(images.keys).subtracting(ids) { images.removeValue(forKey: id) }
    }
}

private extension CGImage {
    /// A smaller copy, `width` pixels wide at the same aspect; itself when it is no wider.
    func scaled(toWidth target: CGFloat) -> CGImage {
        guard CGFloat(width) > target, target > 0 else { return self }
        let height = Int((CGFloat(self.height) * target / CGFloat(width)).rounded())
        guard let context = CGContext(data: nil, width: Int(target), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: Int(target), height: max(1, height)))
        return context.makeImage() ?? self
    }
}

// MARK: Views

/// A board's page in its canvas frame: its live view, else its snapshot, else nothing yet (the
/// frame's fill). What it reads from the host isn't observed, so `content` (the board's token)
/// is what tells SwiftUI it changed.
struct DesignBoardSlot: View {
    let host: DesignHost
    let path: DesignPath
    let zoom: CGFloat
    let content: Int

    var body: some View {
        if let view = host.liveView(path) {
            LiveDesignBoard(view: view, zoom: zoom)
        } else if let image = host.image(path) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

/// The presented board's page (Present, Play): its live view, which takes its own events so its
/// links work, else its snapshot. `content` (the board's token) tells SwiftUI it changed.
struct DesignPresentedSlot: View {
    let host: DesignHost
    let path: DesignPath
    let zoom: CGFloat
    let content: Int

    var body: some View {
        if let view = host.presentedView() {
            InteractiveDesignBoard(view: view, zoom: zoom) { host.setPresentedZoom($0) }
        } else if let image = host.image(path) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

/// A card's thumbnail: the first board's snapshot, top-aligned in its frame.
struct DesignThumbnailSlot: View {
    let image: CGImage?

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

/// Hosts a live board's view in the canvas. The canvas takes every event, so the board never does.
private struct LiveDesignBoard: NSViewRepresentable {
    let view: DesignBoardView
    let zoom: CGFloat

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.show(view)
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.show(view)
        if view.zoom != zoom { view.zoom = zoom }
        container.needsLayout = true
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.clear()
    }

    final class Container: NSView {
        private weak var board: DesignBoardView?

        override var isFlipped: Bool { true }

        func show(_ view: DesignBoardView) {
            // The presentation may have taken the view meanwhile: take it back.
            guard board !== view || view.superview !== self else { return }
            clear()
            board = view
            view.removeFromSuperview()
            addSubview(view)
            needsLayout = true
        }

        func clear() {
            if let board, board.superview === self { board.removeFromSuperview() }
            board = nil
        }

        override func layout() {
            super.layout()
            if let board, board.frame != bounds { board.frame = bounds }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Hosts the presented board's view: unlike the canvas's, it takes events, so a click reaches the
/// page (its handlers, and its links, which come back to the host as `.link`).
private struct InteractiveDesignBoard: NSViewRepresentable {
    let view: DesignBoardView
    let zoom: CGFloat
    let setZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.show(view)
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.show(view)
        setZoom(zoom)
        container.needsLayout = true
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.clear()
    }

    final class Container: NSView {
        private weak var board: DesignBoardView?

        override var isFlipped: Bool { true }

        func show(_ view: DesignBoardView) {
            guard board !== view || view.superview !== self else { return }
            clear()
            board = view
            view.removeFromSuperview()
            addSubview(view)
            needsLayout = true
        }

        func clear() {
            if let board, board.superview === self { board.removeFromSuperview() }
            board = nil
        }

        override func layout() {
            super.layout()
            if let board, board.frame != bounds { board.frame = bounds }
        }
    }
}
