import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// An element picked on a board: its id as a view record names it, where the board draws it (in
/// the board's own points), and what it is.
struct DesignElementPick: Equatable {
    let board: DesignPath
    let id: DesignElementID
    var rect: CGRect
    var kind: DesignElementKind
    var label: String?
    /// "card · Checkout funnel".
    var tag: String
}

/// One design's canvas (DZCanvas): its files as the host last served them, where the canvas
/// looks, the tool, what is selected, and the renderer drawing its boards. Kept per design for
/// the app's run, so coming back to a design finds it as it was left (a visibility flip).
///
/// Selection (Select): a click names the element under it (the board's hit test), a click on a
/// board's label or on nothing named picks the board whole, shift adds or takes away, and a click
/// on the empty canvas clears it. The element under the pointer is ringed as it moves. What the
/// screen shows goes with every message the chat sends (`viewRecord`).
///
/// Live reload: a pushed revision (`SessionServer.onDesignRevision`) pulls the snapshot, and
/// only the boards whose hash changed reload (`DesignHost.update`); new boards appear and
/// removed ones leave.
@MainActor @Observable
final class DesignScreenModel {
    typealias Snapshot = (DesignID) async throws -> DesignSnapshot
    typealias Source = (DesignID, DesignPath) async throws -> String

    let designID: DesignID
    var viewport = NWCanvasViewport() {
        didSet { if viewport != oldValue { viewportMoved() } }
    }
    var tool: NWCanvasTool = .select {
        didSet { if tool != .select { pointer(nil) } }
    }
    /// What is selected, most recent last: boards picked whole, and elements.
    private(set) var picks: [Pick] = []
    /// The element under the pointer with Select.
    private(set) var hover: DesignElementPick?
    private(set) var snapshot: DesignSnapshot?
    /// The last pull failed (the canvas keeps what it drew).
    private(set) var loadError: String?
    /// The chat pane's tab (DZCanvas, DZTweak).
    var paneTab: DesignPaneTab = .chat
    /// The Tweak tab's model; nil where nothing may write (previews of other screens).
    @ObservationIgnored let tweak: DesignTweakModel?

    @ObservationIgnored let host: DesignHost?
    @ObservationIgnored private let fetchSnapshot: Snapshot
    @ObservationIgnored private var canvasSize: CGSize = .zero
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var rest: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    /// Each board's room for its label among the others, worked out once per index.
    @ObservationIgnored private var labelRooms: [String: NWLabelRoom] = [:]
    /// The pointer's latest place while a hit test for an earlier one runs.
    @ObservationIgnored private var pendingHover: (board: DesignPath, point: CGPoint)?
    @ObservationIgnored private var hovering: Task<Void, Never>?
    /// The latest click still being resolved (its board asked what is under it).
    @ObservationIgnored private var picking: Task<Void, Never>?
    @ObservationIgnored private var pickSerial = 0
    /// Moves when the pointer leaves, so a late answer for where it was is dropped.
    @ObservationIgnored private var hoverGeneration = 0
    /// Tests: pulls made.
    @ObservationIgnored private(set) var pulls = 0
    @ObservationIgnored private var remeasureNext: Set<DesignPath> = []
    @ObservationIgnored private var remeasuring: Task<Void, Never>?
    /// Tests: a click is still being resolved.
    var isPicking: Bool { picking != nil }

    /// How long the canvas stays still before live views follow it.
    static let restDelay: Duration = .milliseconds(120)

    init(designID: DesignID, host: DesignHost?, snapshot: @escaping Snapshot, source: @escaping Source, tweak: DesignTweakIO? = nil) {
        self.designID = designID
        self.host = host
        fetchSnapshot = snapshot
        self.tweak = tweak.map { DesignTweakModel(designID: designID, io: $0, host: host) }
        host?.source = { path in try await source(designID, path) }
        host?.redrawn = { [weak self] path in self?.relocate(on: path) }
        self.tweak?.previewed = { [weak self] path in self?.remeasure(path) }
    }

    // MARK: Boards

    /// Every board as the canvas draws it, back to front.
    var boards: [NWCanvasBoard] {
        guard let snapshot else { return [] }
        let tokens = host?.tokens ?? [:]
        return Self.boards(snapshot.index, selected: selectedWhole, tokens: tokens, rooms: labelRooms)
    }

    static func boards(_ index: DesignIndex, selected: Set<DesignPath>, tokens: [DesignPath: Int],
                       rooms: [String: NWLabelRoom] = [:]) -> [NWCanvasBoard] {
        canvasOrder(index).compactMap { path in
            guard let board = index.boards[path] else { return nil }
            let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NWCanvasBoard(id: path.rawValue, frame: CGRect(x: board.x, y: board.y, width: board.w, height: board.h),
                                 title: title?.isEmpty == false ? title! : path.stem,
                                 size: NWCanvasBoard.sizeLabel(CGSize(width: board.w, height: board.h)),
                                 isSelected: selected.contains(path), content: tokens[path] ?? 0,
                                 labelRoom: rooms[path.rawValue] ?? .open)
        }
    }

    /// The boards back to front: canvas.json's `order`, then any it doesn't list by path.
    static func canvasOrder(_ index: DesignIndex) -> [DesignPath] {
        let listed = index.order.filter { index.boards[$0] != nil }
        let rest = index.boards.keys.filter { !listed.contains($0) }.sorted()
        return listed + rest
    }

    static func labelRooms(_ index: DesignIndex) -> [String: NWLabelRoom] {
        NWLabelRoom.rooms(Dictionary(index.boards.map { ($0.key.rawValue, CGRect(x: $0.value.x, y: $0.value.y, width: $0.value.w, height: $0.value.h)) },
                                     uniquingKeysWith: { a, _ in a }))
    }

    /// The boards on screen, nearest the middle of the view first.
    static func visible(_ boards: [NWCanvasBoard], viewport: NWCanvasViewport, size: CGSize) -> [DesignPath] {
        let middle = viewport.canvas(CGPoint(x: size.width / 2, y: size.height / 2))
        return boards.visible(in: viewport, size: size)
            .sorted { distance($0.frame, middle) < distance($1.frame, middle) }
            .compactMap { DesignPath($0.id) }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    // MARK: Pulling

    /// Reads the design's snapshot and hands the renderer the boards that changed. A pull asked
    /// for while one runs runs once more after it.
    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            pulls += 1
            do {
                let next = try await fetchSnapshot(designID)
                apply(next)
                loadError = nil
            } catch {
                loadError = String(describing: error)
            }
        } while refreshAgain
    }

    private func apply(_ next: DesignSnapshot) {
        guard snapshot != next else { return }
        if snapshot?.index.boards != next.index.boards { labelRooms = Self.labelRooms(next.index) }
        snapshot = next
        let kept = picks.filter { next.index.boards[$0.board] != nil }
        if kept != picks { picks = kept }
        if let hover, next.index.boards[hover.board] == nil { self.hover = nil }
        var boards: [DesignPath: DesignHost.Board] = [:]
        for (path, board) in next.index.boards {
            guard let sha = next.boards[path] else { continue }
            let tweaks = next.index.tweaks(for: path)
            boards[path] = DesignHost.Board(size: CGSize(width: board.w, height: board.h), sha: sha,
                                            props: tweaks.isEmpty ? nil : DesignTweakModel.json(.object(tweaks)))
        }
        host?.update(boards)
        if let tweak { Task { await tweak.snapshotChanged(next) } }
        fitIfNeeded()
        planLive()
    }

    // MARK: The canvas

    func resized(_ size: CGSize) {
        guard canvasSize != size else { return }
        canvasSize = size
        fitIfNeeded()
        planLive()
    }

    /// The first time the canvas has both a size and boards, it frames them.
    private func fitIfNeeded() {
        guard !fitted, canvasSize.width > 0, canvasSize.height > 0, let snapshot, !snapshot.index.boards.isEmpty else { return }
        fitted = true
        viewport = .fitting(boards.bounds, in: canvasSize)
    }

    // MARK: Selection

    /// One thing selected: a board whole (`element` nil), or an element on it.
    struct Pick: Equatable {
        let board: DesignPath
        var element: DesignElementPick?
    }

    /// The most selected elements (and boards) kept, as a view record carries.
    static let pickLimit = DesignViewRecord.maxSelected

    /// Boards selected whole.
    var selectedWhole: Set<DesignPath> { Set(picks.filter { $0.element == nil }.map(\.board)) }

    /// The selected elements, most recent last.
    var selectedElements: [DesignElementPick] { picks.compactMap(\.element) }

    /// The board the latest pick is on: it stays live, so its selection can be found again.
    var focusBoard: DesignPath? { picks.last?.board }

    /// Picks a board whole, or clears the selection (nil): what a click on a label does.
    func select(_ id: String?) {
        guard let path = id.flatMap(DesignPath.init) else { clearSelection(); return }
        take(Pick(board: path), extending: false)
    }

    /// A click with Select (`NWDesignCanvas`): an element when the board names one under it, the
    /// board whole on its label or where nothing is named, nothing on the empty canvas.
    func pick(_ pick: NWCanvasPick) {
        let board = pick.board.flatMap(DesignPath.init)
        let asks = board != nil && pick.point != nil && host != nil
        guard asks || picking != nil else {
            resolve(pick, on: board, element: nil)
            return
        }
        // Clicks land in order: one whose board is still being asked never overtakes a later one
        // (a click on the empty canvas after it stays cleared).
        let previous = picking
        pickSerial += 1
        let serial = pickSerial
        picking = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var element: DesignElementPick?
            if asks, let board, let point = pick.point, let host = self.host { element = await host.hitTest(board, at: point) }
            self.resolve(pick, on: board, element: element)
            if self.pickSerial == serial { self.picking = nil }
        }
    }

    private func resolve(_ pick: NWCanvasPick, on board: DesignPath?, element: DesignElementPick?) {
        guard let board else {
            if !pick.extending { clearSelection() }
            return
        }
        take(Pick(board: board, element: element), extending: pick.extending)
    }

    private func take(_ pick: Pick, extending: Bool) {
        var next = picks
        if extending {
            if let index = next.firstIndex(where: { $0.board == pick.board && $0.element?.id == pick.element?.id }) {
                next.remove(at: index)
            } else {
                next.append(pick)
            }
        } else {
            next = [pick]
        }
        if next.count > Self.pickLimit { next.removeFirst(next.count - Self.pickLimit) }
        guard next != picks else { return }
        picks = next
        planLive()
    }

    /// Previews: what is selected and hovered, as the boards would have reported it.
    func setSelection(_ picks: [Pick], hover: DesignElementPick? = nil) {
        self.picks = Array(picks.suffix(Self.pickLimit))
        self.hover = hover
        planLive()
    }

    func clearSelection() {
        guard !picks.isEmpty else { return }
        picks = []
        planLive()
    }

    /// Where the pointer is with Select: the element under it is ringed once its board names it.
    func pointer(_ pick: NWCanvasPick?) {
        guard tool == .select, let pick, let id = pick.board, let board = DesignPath(id), let point = pick.point, let host else {
            hoverGeneration += 1
            pendingHover = nil
            host?.hover(nil)
            if hover != nil { hover = nil }
            return
        }
        host.hover(board)
        pendingHover = (board, point)
        guard hovering == nil else { return }
        // One hit test at a time; the pointer's latest place goes next.
        hovering = Task { [weak self] in
            while let next = self?.pendingHover, let generation = self?.hoverGeneration {
                self?.pendingHover = nil
                let found = await host.hitTest(next.board, at: next.point)
                guard let self else { return }
                if self.hoverGeneration == generation, self.pendingHover == nil, self.hover != found { self.hover = found }
            }
            self?.hovering = nil
        }
    }

    /// A live board drew new source: its selected elements are found again where it draws them
    /// now, and one it no longer draws leaves the selection.
    func relocate(on board: DesignPath) {
        let tids = picks.compactMap { $0.board == board ? $0.element?.id.tid : nil }
        if hover?.board == board { hover = nil }
        guard !tids.isEmpty, let host else { return }
        Task {
            guard let found = await host.locate(board, tids: tids) else { return }
            let next = picks.compactMap { pick -> Pick? in
                guard pick.board == board, let element = pick.element else { return pick }
                guard let now = found[element.id.tid], now.id.path == element.id.path else { return nil }
                return Pick(board: board, element: now)
            }
            if next != picks { picks = next }
        }
    }

    /// The canvas's rings: every selected element, the latest wearing its tag.
    var selectionRings: [NWCanvasElement] {
        let elements = selectedElements
        return elements.enumerated().map { index, element in
            NWCanvasElement(id: element.id.description, board: element.board.rawValue, rect: element.rect,
                            tag: index == elements.count - 1 ? element.tag : nil)
        }
    }

    /// What the Tweak tab edits: the latest pick.
    var tweakTarget: DesignTweakTarget? {
        guard let pick = picks.last else { return nil }
        guard let element = pick.element else { return DesignTweakTarget(board: pick.board, element: nil, kind: .other, tag: nil) }
        return DesignTweakTarget(board: pick.board, element: element.id, kind: element.kind, tag: element.tag)
    }

    /// A tweak previewed on a board: its selected elements are measured again where they are
    /// drawn now (a padding moves the ring). One measure runs at a time; the latest waits.
    func remeasure(_ board: DesignPath) {
        guard picks.contains(where: { $0.board == board && $0.element != nil }) else { return }
        remeasureNext.insert(board)
        guard remeasuring == nil, let host else { return }
        remeasuring = Task { [weak self] in
            while let self, let next = self.remeasureNext.popFirst() {
                let tids = self.picks.compactMap { $0.board == next ? $0.element?.id.tid : nil }
                guard !tids.isEmpty, let found = await host.locate(next, tids: tids) else { continue }
                let updated = self.picks.map { pick -> Pick in
                    guard pick.board == next, let element = pick.element, let now = found[element.id.tid],
                          now.id.path == element.id.path else { return pick }
                    return Pick(board: next, element: now)
                }
                if updated != self.picks { self.picks = updated }
            }
            self?.remeasuring = nil
        }
    }

    var hoverRing: NWCanvasElement? {
        hover.map { NWCanvasElement(id: $0.id.description, board: $0.board.rawValue, rect: $0.rect) }
    }

    // MARK: The view record

    /// What this screen shows, as the chat's messages carry it (view-state.md): the boards on
    /// screen in canvas order, the boards selected whole or holding a selected element, and the
    /// selected elements, most recent last.
    var viewRecord: DesignViewRecord? {
        guard let snapshot else { return nil }
        let visible = Set(Self.onScreen(boards, viewport: viewport, size: canvasSize))
        return Self.viewRecord(order: Self.canvasOrder(snapshot.index), visible: visible, picks: picks)
    }

    /// The boards whose frames a view of `size` shows.
    static func onScreen(_ boards: [NWCanvasBoard], viewport: NWCanvasViewport, size: CGSize) -> [DesignPath] {
        guard size.width > 0, size.height > 0 else { return [] }
        let shown = viewport.visibleRect(in: size)
        return boards.filter { $0.frame.intersects(shown) }.compactMap { DesignPath($0.id) }
    }

    static func viewRecord(order: [DesignPath], visible: Set<DesignPath>, picks: [Pick]) -> DesignViewRecord {
        let elements = Array(picks.compactMap(\.element).suffix(DesignViewRecord.maxSelected))
        let holding = Set(elements.map(\.board))
        let whole = Set(picks.filter { $0.element == nil }.map(\.board))
        var selectedBoards = order.filter { holding.contains($0) }
        for path in order where whole.contains(path) && !holding.contains(path) && selectedBoards.count < DesignViewRecord.maxBoards {
            selectedBoards.append(path)
        }
        selectedBoards = order.filter(Set(selectedBoards).contains)
        return DesignViewRecord(
            mode: .canvas,
            visibleBoards: Array(order.filter(visible.contains).prefix(DesignViewRecord.maxBoards)).map(\.viewName),
            selectedBoards: selectedBoards.map(\.viewName),
            selected: elements.map(\.id),
            selection: elements.suffix(DesignViewRecord.maxSelection).map { .init(id: $0.id, kind: $0.kind, label: $0.label) },
            dirty: false)
    }

    func setZooming(_ zooming: Bool) {
        host?.setZooming(zooming)
        if !zooming { planLive() }
    }

    /// On screen, the design takes live views and pulls what changed while it was away.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        host?.setActive(active)
        if active {
            planLive()
            Task { await refresh() }
        }
    }

    private func viewportMoved() {
        rest?.cancel()
        rest = Task { [weak self] in
            try? await Task.sleep(for: Self.restDelay)
            guard !Task.isCancelled else { return }
            self?.planLive()
        }
    }

    /// The boards on screen now, nearest the middle first.
    var visibleBoards: [DesignPath] { Self.visible(boards, viewport: viewport, size: canvasSize) }

    /// Every board on screen draws its current version (tests and previews wait on it).
    var isDrawn: Bool {
        guard let host, snapshot != nil, canvasSize.width > 0 else { return false }
        return host.isDrawn(visibleBoards)
    }

    /// Tells the renderer what is on screen now.
    func planLive() {
        guard isActive, let host, !host.zooming, canvasSize.width > 0 else { return }
        host.show(visible: visibleBoards, selected: focusBoard, zoom: viewport.zoom)
    }
}

/// The chat pane's tabs (DZCanvas): Chat, and Tweak for the selection.
enum DesignPaneTab: String, Hashable, Sendable {
    case chat, tweak
}
