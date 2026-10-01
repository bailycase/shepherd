import AppKit
import SwiftUI
import DesignSurfaceKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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
        self.init(board: board, id: id, rect: hit.rect, kind: hit.kind, label: hit.label, tag: hit.tag, words: hit.name ?? hit.label,
                  piece: hit.piece)
    }
}

// MARK: Rendering

/// Tweak's live previews go to the board's live view.
extension DesignHost: DesignTweakPreviews {}

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
/// thumbnails. Owned by the view model: one for this Mac's designs, and one per remote host for
/// the designs it serves (their files fetched by hash, rendered here).
@MainActor
final class DesignRendering {
    let rasterizer: DesignRasterizer
    private var hosts: [DesignID: DesignHost] = [:]
    private let makeSurface: (DesignID, DesignSandbox.Network) -> DesignSurface?
    private let network: DesignSandbox.Network
    /// The Designs page's cards' first boards.
    let thumbnails: DesignThumbnails
    /// Design systems' component specimens (DZSystem).
    let specimens: DesignSpecimens
    /// Boards' small pictures for the @ picker's rows and the composer's chips.
    let boardPictures: DesignBoardPictures
    /// The @ picker's element pictures, cut from their boards.
    let elementCrops: DesignElementCrops
    /// A design agent's `board_render` pictures, one drawing at a time.
    let agentRenders = DesignRenderQueue()

    /// Live views a design on screen may hold (previews take none: their captures can't draw a
    /// web view, so every board draws its snapshot).
    let liveCap: Int

    /// This Mac's designs, from their folders.
    convenience init(folder: @escaping (DesignID) -> URL?, network: DesignRenderingNetwork = .googleFonts, liveCap: Int = DesignLivePlan.liveCap) {
        self.init(surface: { id, network in folder(id).map { DesignSurface(designID: id, folder: $0, network: network) } },
                  network: network, liveCap: liveCap, rasterizer: nil)
    }

    /// A remote host's designs, from their files as this Mac cached them. Shares `rasterizer`
    /// (this Mac's), so the off-screen views stay one at a time across every host.
    convenience init(remote source: @escaping (DesignID) -> (any DesignFileSource)?, network: DesignRenderingNetwork,
                     liveCap: Int, rasterizer: DesignRasterizer) {
        self.init(surface: { id, network in source(id).map { DesignSurface(designID: id, source: $0, network: network) } },
                  network: network, liveCap: liveCap, rasterizer: rasterizer)
    }

    private init(surface: @escaping (DesignID, DesignSandbox.Network) -> DesignSurface?, network: DesignRenderingNetwork, liveCap: Int,
                 rasterizer shared: DesignRasterizer?) {
        makeSurface = surface
        self.network = network.sandbox
        self.liveCap = liveCap
        rasterizer = shared ?? DesignRasterizer()
        thumbnails = DesignThumbnails(rasterizer: rasterizer)
        specimens = DesignSpecimens(rasterizer: rasterizer, network: network.sandbox)
        boardPictures = DesignBoardPictures(rasterizer: rasterizer)
        elementCrops = DesignElementCrops(rasterizer: rasterizer)
        thumbnails.surface = { [weak self] id in self?.surface(for: id) }
        boardPictures.surface = { [weak self] id in self?.surface(for: id) }
        elementCrops.surface = { [weak self] id in self?.surface(for: id) }
        if shared == nil { rasterizer.countWebViews = { [weak self] in self?.webViews ?? 0 } }
    }

    private var surfaces: [DesignID: DesignSurface] = [:]

    func surface(for id: DesignID) -> DesignSurface? {
        if let surface = surfaces[id] { return surface }
        guard let surface = makeSurface(id, network) else { return nil }
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
        boardPictures.prune(keeping: ids)
        elementCrops.prune(keeping: ids)
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
        /// What the boards it imports (through theirs) were when it was read, by path and file hash;
        /// nil when it imports none. A piece that changes redraws the boards that import it, though
        /// their own files didn't.
        var deps: String?

        init(size: CGSize, sha: String, props: String? = nil, deps: String? = nil) {
            self.size = size
            self.sha = sha
            self.props = props
            self.deps = deps
        }

        /// What the board draws: its file, its props and the pieces it imports. Snapshots and live
        /// views are kept by it.
        var drawing: String {
            var out = props.map { sha + "+" + $0 } ?? sha
            if let deps { out += "@" + deps }
            return out
        }
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
                if old.size != board.size || (old.deps != board.deps && slot.sha != board.drawing) {
                    // A new size lays the page out again, and a piece it imports that changed is
                    // fetched again only by a fresh load (a live reload keeps what it imported): load it afresh.
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
        /// Elements to find on the board once it renders, and where it draws them (in the
        /// board's points), told before `done`.
        let locate: [Int]
        let located: ([Int: CGRect]) -> Void

        init(key: String, surface: DesignSurface, path: DesignPath, size: CGSize, sha: String, priority: Priority,
             wanted: @escaping () -> Bool, locate: [Int] = [], located: @escaping ([Int: CGRect]) -> Void = { _ in },
             done: @escaping (CGImage?) -> Void) {
            self.key = key
            self.surface = surface
            self.path = path
            self.size = size
            self.sha = sha
            self.priority = priority
            self.wanted = wanted
            self.locate = locate
            self.located = located
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
            var rects: [Int: CGRect] = [:]
            do {
                try await view.load()
                image = try await view.snapshot()
                if !job.locate.isEmpty { rects = await view.elements(tids: job.locate).mapValues(\.rect) }
            } catch {
                image = nil
            }
            guard let self else { return }
            self.webViews = 0
            self.running = false
            if image != nil, !job.locate.isEmpty { job.located(rects) }
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
            self.landed?()
        })
    }

    /// Told when an image lands (the @ picker's rows draw it).
    @ObservationIgnored var landed: (() -> Void)?

    func prune(keeping ids: Set<DesignID>) {
        for id in Set(entries.keys).subtracting(ids) { entries.removeValue(forKey: id) }
        for id in Set(images.keys).subtracting(ids) { images.removeValue(forKey: id) }
    }
}

/// Boards' small pictures (the @ picker's rows, the composer's reference chips): each board a
/// design lists, rendered by the shared rasterizer when its hash is new, at thumbnail priority.
@MainActor
final class DesignBoardPictures {
    private var images: [String: (sha: String, image: CGImage)] = [:]
    private var wanted: [String: String] = [:]
    private let rasterizer: DesignRasterizer
    var surface: ((DesignID) -> DesignSurface?)?
    /// Told when an image lands.
    var landed: (() -> Void)?
    /// A design's boards are asked for at most this many at once.
    static let perDesign = 24

    init(rasterizer: DesignRasterizer) {
        self.rasterizer = rasterizer
    }

    nonisolated static func key(_ id: DesignID, _ path: DesignPath) -> String { id.rawValue + "/" + path.rawValue }

    func image(_ id: DesignID, _ path: DesignPath) -> CGImage? { images[Self.key(id, path)]?.image }

    /// Renders a design's boards whose pictures are missing or out of date.
    func request(_ id: DesignID, snapshot: DesignSnapshot) {
        guard let surface = surface?(id) else { return }
        let order = DesignReferenceReading.canvasOrder(snapshot.index).prefix(Self.perDesign)
        for path in order {
            guard let board = snapshot.index.boards[path], let sha = snapshot.boards[path] else { continue }
            let key = Self.key(id, path)
            guard images[key]?.sha != sha, wanted[key] != sha else { continue }
            wanted[key] = sha
            let size = CGSize(width: board.w, height: board.h)
            rasterizer.enqueue(DesignRasterizer.Job(key: "picture/" + key, surface: surface, path: path, size: size, sha: sha,
                                                    priority: .thumbnail, wanted: { [weak self] in self?.wanted[key] == sha }) { [weak self] image in
                guard let self, self.wanted[key] == sha else { return }
                self.wanted[key] = nil
                guard let image else { return }
                self.images[key] = (sha, image.scaled(toWidth: AppLayout.referenceRowPicturePixels))
                self.landed?()
            })
        }
    }

    func prune(keeping ids: Set<DesignID>) {
        let keep = Set(ids.map(\.rawValue))
        images = images.filter { keep.contains(String($0.key.prefix { $0 != "/" })) }
        wanted = wanted.filter { keep.contains(String($0.key.prefix { $0 != "/" })) }
    }
}

/// The @ picker's element pictures (RefAtElements): each element cut from its board as the
/// rasterizer drew it at the design's revision, only for the rows on screen. A board is drawn
/// once per revision, finding every element the picker lists on it; the few most recent boards
/// are kept to cut from as more rows come on screen, and the cuts are made off the main thread.
@MainActor
final class DesignElementCrops {
    /// A board as drawn at a revision, and where it draws its elements.
    struct Source {
        let revision: UInt64
        let image: CGImage
        /// Pixels per board point.
        let scale: CGFloat
        let rects: [Int: CGRect]
    }

    struct Board: Equatable {
        let design: DesignID
        let path: DesignPath
        let size: CGSize
        let revision: UInt64
        /// Every element the picker lists on it.
        let tids: [Int]

        var key: String { DesignBoardPictures.key(design, path) }
    }

    private var sources: [String: Source] = [:]
    /// Most recently used last.
    private var recent: [String] = []
    private var crops: [String: CGImage] = [:]
    private var cropOrder: [String] = []
    /// Elements asked for while their board draws or is cut, by board.
    private var waiting: [String: Set<Int>] = [:]
    /// The revision each board is being drawn at.
    private var drawing: [String: UInt64] = [:]
    private var cutting: Set<String> = []
    private let rasterizer: DesignRasterizer
    var surface: ((DesignID) -> DesignSurface?)?
    /// Told when pictures land.
    var landed: (() -> Void)?
    /// Boards kept to cut from.
    static let keptSources = 2
    /// Pictures kept, the oldest going first.
    static let keptCrops = 600
    /// Tests: boards drawn, and pictures cut.
    private(set) var drawn = 0
    private(set) var cut = 0

    init(rasterizer: DesignRasterizer) {
        self.rasterizer = rasterizer
    }

    nonisolated static func key(_ board: String, revision: UInt64, tid: Int) -> String { "\(board)@\(revision)#\(tid)" }

    /// Element `tid`'s picture on `path` at `revision`, once it is cut.
    func crop(_ design: DesignID, _ path: DesignPath, revision: UInt64, tid: Int) -> CGImage? {
        crops[Self.key(DesignBoardPictures.key(design, path), revision: revision, tid: tid)]
    }

    /// A row came on screen: its element's picture is cut, from the board drawn at its revision
    /// (drawn first when it isn't yet).
    func want(_ tid: Int, on board: Board) {
        let key = board.key
        guard crops[Self.key(key, revision: board.revision, tid: tid)] == nil else { return }
        waiting[key, default: []].insert(tid)
        if let source = sources[key], source.revision == board.revision {
            touch(key)
            cutWaiting(key, source: source)
            return
        }
        guard drawing[key] != board.revision, let surface = surface?(board.design) else { return }
        drawing[key] = board.revision
        var rects: [Int: CGRect] = [:]
        rasterizer.enqueue(DesignRasterizer.Job(
            key: "crops/" + key, surface: surface, path: board.path, size: board.size, sha: "\(board.revision)", priority: .thumbnail,
            wanted: { [weak self] in self?.drawing[key] == board.revision }, locate: board.tids, located: { rects = $0 }) { [weak self] image in
                guard let self, self.drawing[key] == board.revision else { return }
                self.drawing[key] = nil
                guard let image else { return }
                self.drawn += 1
                Task { await self.keep(image, rects: rects, for: board) }
            })
    }

    /// Keeps a board drawn at `board.revision`, made smaller off the main thread, then cuts what waits.
    private func keep(_ image: CGImage, rects: [Int: CGRect], for board: Board) async {
        let limit = AppLayout.referenceCropSourcePixels
        let width = board.size.width
        let kept = await Task.detached(priority: .utility) { image.scaled(toWidth: limit) }.value
        let source = Source(revision: board.revision, image: kept, scale: width > 0 ? CGFloat(kept.width) / width : 1, rects: rects)
        let key = board.key
        if let old = sources[key], old.revision != board.revision { forget(key, before: board.revision) }
        sources[key] = source
        touch(key)
        cutWaiting(key, source: source)
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > Self.keptSources { sources.removeValue(forKey: recent.removeFirst()) }
    }

    /// A board's pictures from before `revision` go.
    private func forget(_ key: String, before revision: UInt64) {
        let prefix = key + "@"
        let current = Self.key(key, revision: revision, tid: 0).prefix { $0 != "#" }
        crops = crops.filter { !$0.key.hasPrefix(prefix) || $0.key.hasPrefix(current + "#") }
        cropOrder.removeAll { crops[$0] == nil }
    }

    /// Cuts the pictures waiting on a board, in one pass off the main thread.
    private func cutWaiting(_ key: String, source: Source) {
        guard !cutting.contains(key), let tids = waiting[key], !tids.isEmpty else { return }
        waiting[key] = nil
        cutting.insert(key)
        let size = AppLayout.referenceCropPixels
        Task {
            let pieces = await Task.detached(priority: .utility) {
                tids.compactMap { tid in source.rects[tid].flatMap { Self.cut(source, rect: $0, to: size) }.map { (tid, $0) } }
            }.value
            cutting.remove(key)
            for (tid, image) in pieces {
                let cropKey = Self.key(key, revision: source.revision, tid: tid)
                crops[cropKey] = image
                cropOrder.append(cropKey)
            }
            while cropOrder.count > Self.keptCrops { crops.removeValue(forKey: cropOrder.removeFirst()) }
            cut += pieces.count
            if !pieces.isEmpty { landed?() }
            // Rows that came on screen meanwhile.
            if let current = sources[key], current.revision == source.revision { cutWaiting(key, source: current) }
        }
    }

    /// An element's rect cut from its board and drawn at `size` as its row's thumbnail shows it:
    /// filling the width from the top-leading corner.
    nonisolated static func cut(_ source: Source, rect: CGRect, to size: CGSize) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        var pixels = CGRect(x: rect.minX * source.scale, y: rect.minY * source.scale, width: rect.width * source.scale,
                            height: rect.height * source.scale).integral.intersection(bounds)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        // Only the part the thumbnail shows: its aspect, from the top-leading corner.
        let aspect = size.height / size.width
        if pixels.height > pixels.width * aspect { pixels.size.height = max(1, (pixels.width * aspect).rounded()) }
        else { pixels.size.width = max(1, (pixels.height / aspect).rounded()) }
        guard let piece = source.image.cropping(to: pixels),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    func prune(keeping ids: Set<DesignID>) {
        let keep = Set(ids.map(\.rawValue))
        func kept(_ key: String) -> Bool { keep.contains(String(key.prefix { $0 != "/" })) }
        sources = sources.filter { kept($0.key) }
        recent = recent.filter(kept)
        crops = crops.filter { kept($0.key) }
        cropOrder = cropOrder.filter(kept)
        waiting = waiting.filter { kept($0.key) }
        drawing = drawing.filter { kept($0.key) }
    }
}

/// Design systems' component specimens (DZSystem's tiles), drawn by the shared rasterizer from
/// each system's files held in memory (`DesignSurface(designID:files:)`), never from a copy on
/// disk. A system's specimens are drawn again only when its revision moves.
@MainActor @Observable
final class DesignSpecimens {
    /// Moves when an image lands.
    private(set) var version = 0
    @ObservationIgnored private var images: [String: [Int: CGImage]] = [:]
    /// The revision each system's specimens were asked for at.
    @ObservationIgnored private var revisions: [String: String] = [:]
    @ObservationIgnored private let rasterizer: DesignRasterizer
    @ObservationIgnored private let network: DesignSandbox.Network

    init(rasterizer: DesignRasterizer, network: DesignSandbox.Network) {
        self.rasterizer = rasterizer
        self.network = network
    }

    func image(_ namespace: String, _ component: Int) -> CGImage? { images[namespace]?[component] }

    /// Whether `namespace`'s specimens are asked for at `revision` already.
    func has(_ namespace: String, revision: String) -> Bool { revisions[namespace] == revision }

    /// Draws a system's specimens at `revision`: `boards` (by component) among its `files`.
    func update(_ namespace: String, revision: String, files: [String: Data], boards: [Int: (path: String, source: String)]) {
        guard revisions[namespace] != revision else { return }
        revisions[namespace] = revision
        images[namespace] = images[namespace]?.filter { boards[$0.key] != nil }
        guard !boards.isEmpty else { return }
        var all = files
        for board in boards.values { all[board.path] = Data(board.source.utf8) }
        let surface = DesignSurface(designID: DesignID(), files: all, network: network)
        let size = DesignSpecimenBoard.size
        for (index, board) in boards.sorted(by: { $0.key < $1.key }) {
            guard let path = DesignPath(board.path) else { continue }
            rasterizer.enqueue(DesignRasterizer.Job(key: "specimen/\(namespace)/\(index)", surface: surface, path: path, size: size,
                                                    sha: revision, priority: .thumbnail, wanted: { [weak self] in
                                                        self?.revisions[namespace] == revision
                                                    }) { [weak self] image in
                guard let self, let image, self.revisions[namespace] == revision else { return }
                self.images[namespace, default: [:]][index] = image
                self.version += 1
            })
        }
    }

    /// Systems that are gone give up their specimens.
    func prune(keeping namespaces: Set<String>) {
        for namespace in Set(revisions.keys).subtracting(namespaces) {
            revisions.removeValue(forKey: namespace)
            images.removeValue(forKey: namespace)
        }
    }
}

extension CGImage {
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

// MARK: Export

/// A design's boards leaving the app (Export, Attach to a thread): each board rendered off screen
/// by a view of its own, one at a time, at zoom 1, and written as `DesignExportFormat` says. Only
/// what the user picked is written: a staged copy under the temporary folder, moved whole into
/// the save panel's place (or the drop folder, for a thread) once every board is done.
extension DesignRendering {
    /// Writes `files`' boards as `format` at `destination`: the file the save panel named, or a
    /// folder holding one file per board (`DesignExportNames.destination`). What is there already
    /// is replaced, as the save panel confirmed.
    func export(_ format: DesignExportFormat, files: DesignExportFiles, designID: DesignID, name: String,
                tokens: DesignTokens, to destination: URL) async throws {
        guard let surface = surface(for: designID) else { throw DesignExportFailure("The design's folder is gone.") }
        let outputs = try await DesignExporter.outputs(format, files: files, surface: surface, name: name, tokens: tokens)
        try await DesignExporter.place(outputs, format: format, boards: files.boards, name: name, at: destination)
    }

    /// Writes `files`' boards as standalone pages, and a note of the tokens they use, into a new
    /// folder under `folder` (the drop folder), for a thread's composer.
    func attachments(files: DesignExportFiles, designID: DesignID, name: String, tokens: DesignTokens,
                     into folder: URL) async throws -> [NativeAttachedFile] {
        guard let surface = surface(for: designID) else { throw DesignExportFailure("The design's folder is gone.") }
        var outputs: [String: Data] = [:]
        for path in files.boards {
            let page = try await DesignExporter.page(path, files: files, surface: surface, assets: .inline)
            outputs[DesignExportNames.html(path)] = Data(page.utf8)
        }
        let sources = files.members.compactMap { files.sources[$0] }
        let used = DesignExportTokens.used(tokens, in: sources)
        outputs["tokens.css"] = Data(DesignExportTokens.css(used.isEmpty ? tokens : used,
                                                            heading: "The design tokens the attached boards of \(name) use").utf8)
        let target = folder.appendingPathComponent("design-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try await DesignExporter.write(outputs, into: target)
        let order = files.boards.map(DesignExportNames.html) + ["tokens.css"]
        return order.map { relative in
            NativeAttachedFile(name: relative.split(separator: "/").last.map(String.init) ?? relative,
                               path: target.appendingPathComponent(relative).path)
        }
    }
}

/// A design reference's copy (docs/designs.md › Design references › The copy), drawn off screen
/// when the message goes, each board by a view of its own at zoom 1 from the version pinned: the
/// board (or the element cut from it) as a PNG at twice its size, the board's standalone page,
/// and the element's markup and computed styles, written into the copy's folder.
extension DesignRendering {
    func capture(_ request: DesignReferenceCaptureRequest, files: DesignExportFiles) async throws -> DesignReferenceCaptured {
        let surface = DesignSurface(designID: request.reference.designID, source: files, network: network)
        var outputs: [String: Data] = [:]
        var captured = DesignReferenceCaptured(boards: [])
        for (index, board) in request.boards.enumerated() {
            let element = index == 0 ? request.reference.element : nil
            let drawn = try await DesignExporter.reference(board, element: element, files: files, surface: surface)
            outputs[board.picture] = drawn.image.data
            outputs[board.html] = Data(drawn.page.utf8)
            captured.boards.append(.init(
                picture: .init(name: board.picture, bytes: drawn.image.data.count, pixelWidth: drawn.image.width, pixelHeight: drawn.image.height),
                html: .init(name: board.html, bytes: drawn.page.utf8.count)))
            if let detail = drawn.element, let markup = request.elementHTML, let styles = request.elementStyles {
                outputs[markup] = Data(detail.html.utf8)
                outputs[styles] = detail.styles
                captured.element = .init(name: markup, bytes: detail.html.utf8.count)
                captured.elementStyles = .init(name: styles, bytes: detail.styles.count)
                captured.computedStyles = Self.ownStyles(detail.styles)
            }
        }
        try await DesignExporter.write(outputs, into: request.folder)
        return captured
    }

    /// The element's own computed styles: the first entry of its detail's styles.
    static func ownStyles(_ json: Data) -> [String: String]? {
        guard let entries = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        return entries.first?["style"] as? [String: String]
    }
}

/// A design agent's `board_render` (docs/designs.md › Rendering for the agent): the board drawn off
/// screen from the files the host read for it, at its frame's size (or the size asked), by a view of
/// its own that is let go after, one at a time. Never a live canvas view, and nothing of the design
/// on screen is needed: the design need not be open.
extension DesignRendering {
    func picture(for job: DesignRenderJob) async throws -> DesignRendered {
        try await agentRenders.run { try await self.draw(job) }
    }

    private func draw(_ job: DesignRenderJob) async throws -> DesignRendered {
        let path = job.path, request = job.request, files = job.files
        guard let source = files.sources[path] else { throw DesignRenderFailure(code: "no_such_board", message: "\(path) isn't in this design") }
        var size: CGSize?
        if let frame = files.index.boards[path] {
            size = CGSize(width: frame.w, height: frame.h)
        } else if let preview = DesignBoardCheck.previewSize(of: source) {
            size = CGSize(width: preview.width, height: preview.height)
        }
        let width = request.width.map(CGFloat.init) ?? size?.width
        let height = request.height.map(CGFloat.init) ?? size?.height
        guard let width, let height else {
            throw DesignRenderFailure(code: "no_frame", message: "\(path) has no frame on the canvas and no $preview, so its size is unknown: give it a frame with canvas_update, or pass width and height")
        }
        let scale = CGFloat(min(max(request.scale ?? 1, DesignRenderRequest.scaleRange.lowerBound), DesignRenderRequest.scaleRange.upperBound))
        // Past what one picture may hold (64 million pixels, a bitmap's 256 MB) there is nothing to draw.
        guard width * height * scale * scale <= 64_000_000 else {
            throw DesignRenderFailure(code: "render_too_large", message: "\(Int(width))×\(Int(height)) at \(scale)x is more than a picture holds: pass a smaller width, height or scale")
        }
        // The board's Tweak values, then the call's props over them.
        var props = files.index.tweaks(for: path)
        if case .object(let given)? = request.props { for (key, value) in given { props[key] = value } }
        let surface = DesignSurface(designID: job.designID, source: files, network: network)
        let view = DesignBoardView(surface: surface, board: path, size: CGSize(width: width, height: height))
        let image: CGImage
        do {
            try await view.load()
            if request.props != nil, let json = DesignTweakModel.json(.object(props)) { try await view.replaceSource(source, props: json) }
            image = try await view.image(scale: scale)
        } catch {
            throw DesignRenderFailure(code: "render_failed", message: "\(path) couldn't be drawn: \(Self.describe(error))")
        }
        guard let encoded = DesignRenderImage.encode(image) else {
            throw DesignRenderFailure(code: "render_failed", message: "\(path) was drawn but its picture couldn't be encoded")
        }
        var words = "\(path) at \(Int(width))×\(Int(height))"
        if scale != 1 { words += ", \(scale.formatted())x" }
        if let given = request.props, case .object(let object) = given, !object.isEmpty { words += ", props \(object.keys.sorted().joined(separator: ", "))" }
        words += " · image \(encoded.width)×\(encoded.height) \(encoded.isPNG ? "PNG" : "JPEG"), \(DesignRenderImage.size(encoded.data.count))"
        if encoded.width != image.width || encoded.height != image.height { words += " (reduced from \(image.width)×\(image.height) to fit)" }
        return DesignRendered(image: BrowserImage(data: encoded.data.base64EncodedString(), mimeType: encoded.mimeType), text: words)
    }

    private static func describe(_ error: any Error) -> String {
        if let problem = error as? DesignBoardProblem { return problem.description }
        if let board = error as? DesignBoardError { return String(describing: board) }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

struct DesignExportFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
enum DesignExporter {
    enum Assets {
        /// Uploads inlined as data URLs: a standalone page.
        case inline
        /// Uploads beside the page in `assets/`: a ZIP.
        case folder
    }

    /// Every file the export writes, by its path under what the save panel names.
    static func outputs(_ format: DesignExportFormat, files: DesignExportFiles, surface: DesignSurface, name: String,
                        tokens: DesignTokens) async throws -> [String: Data] {
        var outputs: [String: Data] = [:]
        switch format {
        case .html:
            for path in files.boards {
                outputs[DesignExportNames.html(path)] = Data(try await page(path, files: files, surface: surface, assets: .inline).utf8)
            }
        case .png:
            for path in files.boards {
                let image = try await render(path, files: files, surface: surface) { try await $0.image(scale: 2) }
                outputs[DesignExportNames.png(path)] = try DesignImageFile.png(image)
            }
        case .pdf:
            var documents: [Data] = []
            for path in files.boards {
                let mode = files.index.boards[path].map(DesignPrint.of) ?? .fixed
                documents.append(try await render(path, files: files, surface: surface) { try await $0.pdf(mode) })
            }
            outputs[DesignExportNames.destination(.pdf, boards: files.boards, design: name).name] = try DesignPDF.merge(documents)
        case .zip:
            // The pages, tokens.css and the uploads they use, beside the canvas as a project
            // folder (format.md), narrowed to these boards and the ones they import.
            for path in files.boards {
                outputs[DesignExportNames.html(path)] = Data(try await page(path, files: files, surface: surface, assets: .folder).utf8)
            }
            outputs["tokens.css"] = Data(DesignExportTokens.css(tokens, heading: "The design tokens of \(name)").utf8)
            for asset in files.assets.values { outputs["assets/" + asset.name] = asset.data }
            outputs["project/canvas.json"] = try DesignBundle.index(files.index, keeping: Set(files.members)).encoded()
            for path in files.members { outputs["project/" + path.rawValue] = files.sources[path].map { Data($0.utf8) } }
            for (path, data) in files.support { outputs["project/" + path] = data }
        }
        return outputs
    }

    /// A board baked to a standalone page: its uploads inlined or pointed at `assets/`, its links
    /// to other exported boards pointed at their pages.
    static func page(_ path: DesignPath, files: DesignExportFiles, surface: DesignSurface, assets: Assets) async throws -> String {
        let raw = try await render(path, files: files, surface: surface) { try await $0.staticPage() }
        return baked(raw, path: path, files: files, assets: assets)
    }

    /// A board's static page with its uploads inlined or pointed at `assets/`, and its links to
    /// other exported boards pointed at their pages.
    static func baked(_ raw: String, path: DesignPath, files: DesignExportFiles, assets: Assets) -> String {
        let page = DesignExportNames.html(path)
        let withAssets = DesignBundle.rewritingBlobs(raw) { id in
            guard let asset = files.assets[id] else { return nil }
            switch assets {
            case .inline: return DesignBundle.dataURI(asset.data, type: asset.type)
            case .folder: return DesignExportNames.relative("assets/" + asset.name, from: page)
            }
        }
        return DesignBundle.rewritingBoardLinks(withAssets, page: path, exported: Set(files.boards))
    }

    /// What a reference's copy holds of one board, from one view of it showing `board.source`
    /// (loaded from immutable pinned inputs, never the current design folder): the PNG
    /// (the element cut from the board where it names one), the standalone page, and the
    /// element's detail.
    static func reference(_ board: DesignReferenceCaptureRequest.Board, element: DesignElementID?, files: DesignExportFiles,
                          surface: DesignSurface) async throws -> (image: (data: Data, width: Int, height: Int), page: String,
                                                                  element: DesignElementDetail?) {
        let path = board.path
        return try await render(path, files: files, surface: surface) { view in
            try await view.replaceSource(board.source, props: DesignTweakModel.json(.object(files.index.tweaks(for: path))) ?? "{}")
            var drawn = try await view.image(scale: 2)
            if let tid = element?.tid {
                guard let hit = await view.element(tid: tid) else { throw DesignExportFailure("The element isn't drawn on \(path).") }
                let crop = CGRect(x: hit.rect.minX * 2, y: hit.rect.minY * 2, width: hit.rect.width * 2, height: hit.rect.height * 2)
                    .integral.intersection(CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height))
                guard !crop.isEmpty, let cut = drawn.cropping(to: crop) else { throw DesignExportFailure("The element has no size on \(path).") }
                drawn = cut
            }
            let image = (data: try DesignImageFile.png(drawn), width: drawn.width, height: drawn.height)
            let page = Self.baked(try await view.staticPage(), path: path, files: files, assets: .inline)
            var detail: DesignElementDetail?
            if let tid = element?.tid {
                detail = try await view.elementDetail(tid: tid)
                guard detail != nil else { throw DesignExportFailure("The element isn't drawn on \(path).") }
            }
            return (image, page, detail)
        }
    }

    /// Loads `path` in a view of its own at its canvas size and reads it with `body`.
    private static func render<T>(_ path: DesignPath, files: DesignExportFiles, surface: DesignSurface,
                                  _ body: (DesignBoardView) async throws -> T) async throws -> T {
        guard let board = files.index.boards[path] else { throw DesignExportFailure("\(path) isn't on the canvas.") }
        let view = DesignBoardView(surface: surface, board: path, size: CGSize(width: board.w, height: board.h))
        do {
            try await view.load()
            return try await body(view)
        } catch {
            throw DesignExportFailure("\(path) couldn't be drawn: \(error)")
        }
    }

    /// Stages `outputs` and moves them into `destination`: the one file a single-file export
    /// writes, a ZIP of the staged folder, or the staged folder itself.
    static func place(_ outputs: [String: Data], format: DesignExportFormat, boards: [DesignPath], name: String,
                      at destination: URL,
                      replace: @escaping @Sendable (URL, URL) throws -> Void = { destination, result in
                          _ = try FileManager.default.replaceItemAt(destination, withItemAt: result)
                      }) async throws {
        // Complete the replacement on the destination volume before touching the old export.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".shepherd-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(DesignExportNames.fileName(name), isDirectory: true)
        try await write(outputs, into: folder)
        let isFolder = DesignExportNames.destination(format, boards: boards, design: name).isFolder
        try await Task.detached(priority: .userInitiated) {
            let result: URL
            if format == .zip {
                result = staging.appendingPathComponent("export.zip")
                try Self.zip(folder, to: result)
            } else if isFolder {
                result = folder
            } else {
                guard let only = outputs.keys.first, outputs.count == 1 else { throw DesignExportFailure("Nothing to export.") }
                result = folder.appendingPathComponent(only)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try replace(destination, result)
            } else {
                try FileManager.default.moveItem(at: result, to: destination)
            }
        }.value
    }

    /// Writes each output at its path under `folder`, off the main thread.
    static func write(_ outputs: [String: Data], into folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (path, data) in outputs {
                let url = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }.value
    }

    /// `folder` as a ZIP holding it by name, with ditto (no library).
    nonisolated static func zip(_ folder: URL, to file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, file.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DesignExportFailure("The ZIP couldn't be made: \(String(decoding: message, as: UTF8.self))")
        }
    }
}
