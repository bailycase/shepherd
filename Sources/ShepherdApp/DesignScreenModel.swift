import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// One design's canvas (DZCanvas): its files as the host last served them, where the canvas
/// looks, the tool, the selected board, and the renderer drawing its boards. Kept per design for
/// the app's run, so coming back to a design finds it as it was left (a visibility flip).
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
    var tool: NWCanvasTool = .select
    private(set) var selection: DesignPath?
    private(set) var snapshot: DesignSnapshot?
    /// The last pull failed (the canvas keeps what it drew).
    private(set) var loadError: String?

    @ObservationIgnored let host: DesignHost?
    @ObservationIgnored private let fetchSnapshot: Snapshot
    @ObservationIgnored private var canvasSize: CGSize = .zero
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var rest: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    /// Tests: pulls made.
    @ObservationIgnored private(set) var pulls = 0

    /// How long the canvas stays still before live views follow it.
    static let restDelay: Duration = .milliseconds(120)

    init(designID: DesignID, host: DesignHost?, snapshot: @escaping Snapshot, source: @escaping Source) {
        self.designID = designID
        self.host = host
        fetchSnapshot = snapshot
        host?.source = { path in try await source(designID, path) }
    }

    // MARK: Boards

    /// Every board as the canvas draws it, back to front.
    var boards: [NWCanvasBoard] {
        guard let snapshot else { return [] }
        let tokens = host?.tokens ?? [:]
        return Self.boards(snapshot.index, selection: selection, tokens: tokens)
    }

    static func boards(_ index: DesignIndex, selection: DesignPath?, tokens: [DesignPath: Int]) -> [NWCanvasBoard] {
        let listed = index.order.filter { index.boards[$0] != nil }
        let rest = index.boards.keys.filter { !listed.contains($0) }.sorted()
        return (listed + rest).compactMap { path in
            guard let board = index.boards[path] else { return nil }
            let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NWCanvasBoard(id: path.rawValue, frame: CGRect(x: board.x, y: board.y, width: board.w, height: board.h),
                                 title: title?.isEmpty == false ? title! : path.stem,
                                 size: NWCanvasBoard.sizeLabel(CGSize(width: board.w, height: board.h)),
                                 isSelected: path == selection, content: tokens[path] ?? 0)
        }
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
        snapshot = next
        if let selection, next.index.boards[selection] == nil { self.selection = nil }
        var boards: [DesignPath: DesignHost.Board] = [:]
        for (path, board) in next.index.boards {
            guard let sha = next.boards[path] else { continue }
            boards[path] = DesignHost.Board(size: CGSize(width: board.w, height: board.h), sha: sha)
        }
        host?.update(boards)
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

    func select(_ id: String?) {
        let path = id.flatMap(DesignPath.init)
        guard selection != path else { return }
        selection = path
        planLive()
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
        host.show(visible: visibleBoards, selected: selection, zoom: viewport.zoom)
    }
}
