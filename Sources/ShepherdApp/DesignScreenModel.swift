import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The design chat pane's tabs (DZCanvas). Tweak comes with its own change.
enum DesignPaneTab: String {
    case chat
    case comments
}

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
    /// What a comment on it is on: its `data-el` name, else its words ("Checkout funnel").
    var words: String? = nil
}

/// What a design's canvas asks its host about comments (`SessionServer`'s comment mutations).
/// `add` and `reply` answer the comment as kept and why it didn't reach the agent, if it didn't.
struct DesignCommentActions {
    var list: (DesignID) async throws -> DesignComments
    var add: (DesignID, DesignCommentDraft, UInt64?) async throws -> (DesignComment, String?)
    var reply: (DesignID, UUID, String, UInt64?) async throws -> (DesignComment, String?)
    var resolve: (DesignID, UUID, UInt64?) async throws -> DesignComment
    /// Says what went wrong (the app's error dialog).
    var report: (String) -> Void
}

/// A comment's card as the chat and the Comments tab draw it.
struct DesignCommentCardValue: Equatable, Identifiable {
    let id: UUID
    let number: Int
    /// "A · Checkout funnel".
    let target: String
    /// "You · 2m".
    let meta: String
    let text: String
}

/// The comments' cards by comment, for the design's chat: a message whose origin names a comment
/// draws its card (`ThreadView`). One per design, kept by its screen.
@MainActor @Observable
final class DesignCommentCards {
    private(set) var cards: [UUID: DesignCommentCardValue] = [:]

    func set(_ next: [UUID: DesignCommentCardValue]) {
        if next != cards { cards = next }
    }
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
        didSet { if tool == .pan { pointer(nil) } }
    }
    /// What is selected, most recent last: boards picked whole, and elements.
    private(set) var picks: [Pick] = []
    /// The element under the pointer with Select.
    private(set) var hover: DesignElementPick?
    private(set) var snapshot: DesignSnapshot?
    /// The last pull failed (the canvas keeps what it drew).
    private(set) var loadError: String?

    // Comments
    /// Every comment, open and resolved, in the order they were made.
    private(set) var comments: [DesignComment] = []
    /// The chat pane's tab: `chat` or `comments`.
    var paneTab = DesignPaneTab.chat
    /// The comment whose thread is open beside its pin.
    private(set) var openComment: UUID?
    /// The element a new comment is being written on (the Comment tool's click).
    private(set) var draftElement: DesignElementPick?
    var draftText = ""
    var replyText = ""
    /// Where live boards draw commented elements now, by comment: a rewrite may have moved them
    /// since the comment kept its rect.
    private(set) var pinRects: [UUID: CGRect] = [:]
    /// A comment or reply is on its way to the host.
    private(set) var sendingComment = false
    /// The chat's cards, by comment.
    let commentCards = DesignCommentCards()

    @ObservationIgnored let host: DesignHost?
    @ObservationIgnored private let fetchSnapshot: Snapshot
    @ObservationIgnored private let commentActions: DesignCommentActions?
    /// The comments' revision as last read: a change names it, and a stale one is read again.
    @ObservationIgnored private(set) var commentsRevision: UInt64 = 0
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
    /// Tests: a click is still being resolved.
    var isPicking: Bool { picking != nil }

    /// How long the canvas stays still before live views follow it.
    static let restDelay: Duration = .milliseconds(120)

    init(designID: DesignID, host: DesignHost?, snapshot: @escaping Snapshot, source: @escaping Source,
         comments: DesignCommentActions? = nil) {
        self.designID = designID
        self.host = host
        fetchSnapshot = snapshot
        commentActions = comments
        host?.source = { path in try await source(designID, path) }
        host?.redrawn = { [weak self] path in self?.relocate(on: path) }
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
            if let list = commentActions?.list, let next = try? await list(designID) { applyComments(next) }
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

    /// A click (`NWDesignCanvas`). With Select: an element when the board names one under it,
    /// the board whole on its label or where nothing is named, nothing on the empty canvas. With
    /// Comment: a new comment on the element under it. Either closes the thread that was open.
    func pick(_ pick: NWCanvasPick) {
        let board = pick.board.flatMap(DesignPath.init)
        let asks = board != nil && pick.point != nil && host != nil
        let commenting = tool == .comment
        closeComment()
        guard asks || picking != nil else {
            resolve(pick, on: board, element: nil, commenting: commenting)
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
            self.resolve(pick, on: board, element: element, commenting: commenting)
            if self.pickSerial == serial { self.picking = nil }
        }
    }

    private func resolve(_ pick: NWCanvasPick, on board: DesignPath?, element: DesignElementPick?, commenting: Bool = false) {
        if commenting {
            // A comment goes on an element; a board's label or nothing named takes none.
            if let element { beginComment(on: element) }
            return
        }
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

    /// Where the pointer is with Select or Comment: the element under it is ringed once its board
    /// names it.
    func pointer(_ pick: NWCanvasPick?) {
        guard tool != .pan, let pick, let id = pick.board, let board = DesignPath(id), let point = pick.point, let host else {
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
    /// now, and one it no longer draws leaves the selection. Its comments' pins move to where
    /// their elements are drawn now.
    func relocate(on board: DesignPath) {
        let tids = picks.compactMap { $0.board == board ? $0.element?.id.tid : nil }
        if hover?.board == board { hover = nil }
        locatePins(on: board)
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

    var hoverRing: NWCanvasElement? {
        hover.map { NWCanvasElement(id: $0.id.description, board: $0.board.rawValue, rect: $0.rect) }
    }

    // MARK: Comments

    /// The open comments, in the order they were made.
    var openComments: [DesignComment] { comments.filter(\.isOpen) }

    /// The canvas's pins: each open comment on a board the canvas holds, where a live view last
    /// found its element, else where it was when the comment was made; and the pin of the comment
    /// being written.
    var pins: [NWCanvasPin] {
        guard let snapshot else { return [] }
        var pins = openComments.compactMap { comment -> NWCanvasPin? in
            guard snapshot.index.boards[comment.board] != nil else { return nil }
            return NWCanvasPin(id: comment.id.uuidString, board: comment.board.rawValue, rect: pinRect(comment), number: comment.number)
        }
        if let draft = draftElement {
            pins.append(NWCanvasPin(id: Self.draftPin, board: draft.board.rawValue, rect: draft.rect, number: nextNumber))
        }
        return pins
    }

    static let draftPin = "draft"

    private var nextNumber: Int { (comments.map(\.number).max() ?? 0) + 1 }

    private func pinRect(_ comment: DesignComment) -> CGRect {
        if let rect = pinRects[comment.id] { return rect }
        guard let rect = comment.rect else { return .zero }
        return CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    /// What the canvas's popover opens under: the element a comment is being written on, else the
    /// open comment's.
    var popoverAnchor: NWCanvasElement? {
        if let draft = draftElement {
            return NWCanvasElement(id: Self.draftPin, board: draft.board.rawValue, rect: draft.rect)
        }
        guard let id = openComment, let comment = comments.first(where: { $0.id == id }) else { return nil }
        return NWCanvasElement(id: id.uuidString, board: comment.board.rawValue, rect: pinRect(comment))
    }

    /// The comment whose thread is open.
    var openThread: DesignComment? { openComment.flatMap { id in comments.first { $0.id == id } } }

    /// The Comment tool's click on an element: it takes the selection ring and the next pin, and
    /// the editor opens beside it.
    func beginComment(on element: DesignElementPick) {
        take(Pick(board: element.board, element: element), extending: false)
        draftElement = element
        draftText = ""
        openComment = nil
    }

    /// Closes the editor, or the open thread.
    func closeComment() {
        if draftElement != nil { draftElement = nil }
        if openComment != nil { openComment = nil }
    }

    /// A pin (or a card in the Comments tab): its thread opens beside it.
    func openThread(_ id: String) {
        guard let id = UUID(uuidString: id), comments.contains(where: { $0.id == id }) else { return }
        draftElement = nil
        replyText = ""
        openComment = id
    }

    /// Keeps the comment being written: the host checks its element and hands it to the design
    /// agent as a turn of its own. An empty comment is no comment.
    @discardableResult
    func submitComment() -> Task<Void, Never>? {
        guard let element = draftElement, let actions = commentActions, !sendingComment else { return nil }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { closeComment(); return nil }
        let draft = DesignCommentDraft(
            board: element.board, tid: element.id.tid, path: element.id.path, label: element.label, target: element.words,
            rect: DesignCommentRect(x: element.rect.minX, y: element.rect.minY, w: element.rect.width, h: element.rect.height), text: text)
        sendingComment = true
        return Task {
            defer { sendingComment = false }
            do {
                let (comment, undelivered) = try await actions.add(designID, draft, commentsRevision)
                comments.append(comment)
                pinRects[comment.id] = element.rect
                if draftElement == element { draftElement = nil }
                draftText = ""
                openComment = comment.id
                rebuildCards()
                if let undelivered { actions.report("The comment is saved, but it didn't reach the design agent: \(undelivered)") }
            } catch {
                actions.report("Couldn't keep the comment: \(error)")
            }
            await refreshComments()
        }
    }

    /// The Reply… field under the open thread: the answer joins the thread and goes to the
    /// design agent like a comment.
    @discardableResult
    func sendReply() -> Task<Void, Never>? {
        guard let id = openComment, let actions = commentActions, !sendingComment else { return nil }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        sendingComment = true
        return Task {
            defer { sendingComment = false }
            do {
                let (comment, undelivered) = try await actions.reply(designID, id, text, commentsRevision)
                replace(comment)
                replyText = ""
                if let undelivered { actions.report("The reply is saved, but it didn't reach the design agent: \(undelivered)") }
            } catch {
                actions.report("Couldn't keep the reply: \(error)")
            }
            await refreshComments()
        }
    }

    /// Resolve: only the viewer resolves a comment. Its pin and thread leave the canvas.
    @discardableResult
    func resolve(_ id: UUID) -> Task<Void, Never>? {
        guard let actions = commentActions else { return nil }
        return Task {
            do {
                replace(try await actions.resolve(designID, id, commentsRevision))
                if openComment == id { openComment = nil }
            } catch {
                actions.report("Couldn't resolve the comment: \(error)")
            }
            await refreshComments()
        }
    }

    /// Reads the comments again (a push, or after a change of our own).
    func refreshComments() async {
        guard let list = commentActions?.list, let next = try? await list(designID) else { return }
        applyComments(next)
    }

    /// Previews and tests: comments as the host would serve them.
    func applyComments(_ next: DesignComments) {
        // An answer older than one already applied (two reads crossing) changes nothing.
        guard next.revision >= commentsRevision else { return }
        commentsRevision = next.revision
        if next.comments != comments { comments = next.comments }
        if let id = openComment, comments.first(where: { $0.id == id })?.isOpen != true { openComment = nil }
        let known = Set(comments.map(\.id))
        if pinRects.keys.contains(where: { !known.contains($0) }) { pinRects = pinRects.filter { known.contains($0.key) } }
        rebuildCards()
        for board in Set(openComments.map(\.board)) { locatePins(on: board) }
    }

    private func replace(_ comment: DesignComment) {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        if comments[index] != comment { comments[index] = comment }
        rebuildCards()
    }

    /// Asks a live board where its open comments' elements are drawn now.
    private func locatePins(on board: DesignPath) {
        let onBoard = openComments.filter { $0.board == board && !$0.detached }
        guard !onBoard.isEmpty, let host, host.liveBoards.contains(board) else { return }
        Task {
            guard let found = await host.locate(board, tids: onBoard.map(\.tid)) else { return }
            var next = pinRects
            for comment in onBoard {
                if let pick = found[comment.tid], pick.id.path == comment.path { next[comment.id] = pick.rect }
            }
            if next != pinRects { pinRects = next }
        }
    }

    /// The chat's and the Comments tab's cards.
    private func rebuildCards(now: Date = Date()) {
        commentCards.set(Dictionary(uniqueKeysWithValues: comments.map { ($0.id, Self.card($0, now: now)) }))
    }

    /// "on A · Checkout funnel", "You · 2m", and a detached comment's "element changed".
    static func card(_ comment: DesignComment, now: Date = Date()) -> DesignCommentCardValue {
        let board = nativeBoardName(comment.board.rawValue)
        let target = comment.target.map { "\(board) · \($0)" } ?? board
        let meta = ["You · \(nwCommentAge(since: comment.createdAt, now: now))", comment.detached ? "element changed" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return DesignCommentCardValue(id: comment.id, number: comment.number, target: target, meta: meta, text: comment.text)
    }

    /// The open comments' cards, for the Comments tab.
    var openCards: [DesignCommentCardValue] {
        openComments.compactMap { commentCards.cards[$0.id] }
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
