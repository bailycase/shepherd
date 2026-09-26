import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
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

/// What a design's canvas asks its host to do to the design (the board actions, a board moved):
/// the server's mutations, and a message to the design agent carrying a view record.
struct DesignCanvasActions {
    var snapshot: (DesignID) async throws -> DesignSnapshot
    var duplicate: (DesignID, DesignPath, UInt64?) async throws -> DesignDuplicate
    var updateIndex: (DesignID, JSONValue, UInt64?) async throws -> DesignWriteResult
    /// Sends the design agent a message with a view record; false when the design has no agent.
    var ask: (DesignID, String, DesignViewRecord) async -> Bool
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
/// The board actions work on the board picked whole last: Comment, Tweak, Variations and
/// "Ask for another direction" (messages to the design agent, the board named in their view
/// record), and Duplicate. A board dragged by its label moves, written once when it lands. Present
/// (and Play on an interactive board) shows one board focused, its in-project links moving
/// between boards. A canvas with pages shows one page's boards and notes at a time.
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
    /// The chat pane's tab (DZCanvas, DZTweak): Chat, Comments or Tweak.
    var paneTab: DesignPaneTab = .chat
    /// The Tweak tab's model; nil where nothing may write (previews of other screens).
    @ObservationIgnored let tweak: DesignTweakModel?

    // Comments
    /// Every comment, open and resolved, in the order they were made.
    private(set) var comments: [DesignComment] = []
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

    // Pages, moving, presenting
    /// The page the canvas shows (canvas.json's page id); nil on a canvas without pages.
    private(set) var page: String?
    /// A board being dragged, and how far it has come (canvas points).
    private(set) var moving: NWBoardMove?
    /// Boards moved and written, where they now stand, until the snapshot says so.
    private(set) var movedTo: [DesignPath: CGPoint] = [:]
    /// The board shown focused (Present, Play); nil on the canvas.
    private(set) var presented: DesignPath?
    @ObservationIgnored private let canvasActions: DesignCanvasActions?
    /// Tests: index writes made for moves.
    @ObservationIgnored private(set) var moveWrites = 0

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
    @ObservationIgnored private var remeasureNext: Set<DesignPath> = []
    @ObservationIgnored private var remeasuring: Task<Void, Never>?
    /// Tests: a click is still being resolved.
    var isPicking: Bool { picking != nil }

    /// How long the canvas stays still before live views follow it.
    static let restDelay: Duration = .milliseconds(120)

    init(designID: DesignID, host: DesignHost?, snapshot: @escaping Snapshot, source: @escaping Source,
         comments: DesignCommentActions? = nil, tweak: DesignTweakIO? = nil, actions: DesignCanvasActions? = nil) {
        self.designID = designID
        self.host = host
        fetchSnapshot = snapshot
        commentActions = comments
        canvasActions = actions
        self.tweak = tweak.map { DesignTweakModel(designID: designID, io: $0, host: host) }
        host?.source = { path in try await source(designID, path) }
        host?.redrawn = { [weak self] path in self?.relocate(on: path) }
        host?.linked = { [weak self] from, to in self?.follow(link: to, from: from) }
        self.tweak?.previewed = { [weak self] path in self?.remeasure(path) }
    }

    // MARK: Boards

    /// Every board of the page as the canvas draws it, back to front, a board being dragged where
    /// it has come to.
    var boards: [NWCanvasBoard] {
        guard let snapshot else { return [] }
        let tokens = host?.tokens ?? [:]
        var boards = Self.boards(snapshot.index, page: page, selected: selectedWhole, tokens: tokens, rooms: labelRooms)
        if !movedTo.isEmpty || moving != nil {
            for index in boards.indices {
                guard let path = DesignPath(boards[index].id) else { continue }
                if let point = movedTo[path] { boards[index].frame.origin = point }
                if let moving, moving.board == boards[index].id {
                    boards[index].frame.origin.x += moving.offset.width
                    boards[index].frame.origin.y += moving.offset.height
                }
            }
        }
        return boards
    }

    static func boards(_ index: DesignIndex, page: String? = nil, selected: Set<DesignPath>, tokens: [DesignPath: Int],
                       rooms: [String: NWLabelRoom] = [:]) -> [NWCanvasBoard] {
        canvasOrder(index).compactMap { path in
            guard let board = index.boards[path], index.isOnPage(path, page) else { return nil }
            let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NWCanvasBoard(id: path.rawValue, frame: CGRect(x: board.x, y: board.y, width: board.w, height: board.h),
                                 title: title?.isEmpty == false ? title! : path.stem,
                                 size: NWCanvasBoard.sizeLabel(CGSize(width: board.w, height: board.h)),
                                 isSelected: selected.contains(path), content: tokens[path] ?? 0,
                                 labelRoom: rooms[path.rawValue] ?? .open)
        }
    }

    /// The page's title and sticky notes (drawings aren't drawn yet).
    var notes: [NWCanvasNote] {
        guard let snapshot else { return [] }
        return Self.notes(snapshot.index, page: page)
    }

    static func notes(_ index: DesignIndex, page: String?) -> [NWCanvasNote] {
        (index.notes ?? [:]).sorted { $0.key < $1.key }.compactMap { id, note in
            guard index.page(of: note) == page, let x = note.x, let y = note.y,
                  let text = note.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let kind: NWCanvasNote.Kind
            switch note.shown {
            case .title: kind = .title
            case .sticky: kind = .sticky
            case .drawing: return nil
            }
            return NWCanvasNote(id: id, kind: kind, origin: CGPoint(x: x, y: y), width: note.width.map { CGFloat($0) }, text: text)
        }
    }

    /// The boards back to front: canvas.json's `order`, then any it doesn't list by path.
    static func canvasOrder(_ index: DesignIndex) -> [DesignPath] {
        let listed = index.order.filter { index.boards[$0] != nil }
        let rest = index.boards.keys.filter { !listed.contains($0) }.sorted()
        return listed + rest
    }

    /// Each board's room for its label among the other boards of its page.
    static func labelRooms(_ index: DesignIndex, page: String? = nil) -> [String: NWLabelRoom] {
        let shown = index.boards.filter { index.isOnPage($0.key, page) }
        return NWLabelRoom.rooms(Dictionary(shown.map { ($0.key.rawValue, CGRect(x: $0.value.x, y: $0.value.y, width: $0.value.w, height: $0.value.h)) },
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
        let previous = snapshot?.index
        if page == nil || next.index.pages?.contains(where: { $0.id == page }) != true {
            let opening = next.index.openingPage
            if page != opening { page = opening }
        }
        if previous?.boards != next.index.boards || previous?.pages != next.index.pages {
            labelRooms = Self.labelRooms(next.index, page: page)
        }
        snapshot = next
        // A move shows where it went until the index has it (or has moved on without it).
        let landed = movedTo.filter { path, point in
            guard let board = next.index.boards[path] else { return false }
            return CGPoint(x: board.x, y: board.y) != point
        }
        if landed != movedTo { movedTo = landed }
        let kept = picks.filter { next.index.boards[$0.board] != nil && next.index.isOnPage($0.board, page) }
        if kept != picks { picks = kept }
        if let hover, next.index.boards[hover.board] == nil { self.hover = nil }
        if let presented, next.index.boards[presented] == nil { present(nil) }
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

    // MARK: Pages

    /// The canvas's pages in its order: id and name (the id where it has none).
    var pages: [(id: String, name: String)] {
        (snapshot?.index.pages ?? []).map { ($0.id, $0.name?.isEmpty == false ? $0.name! : $0.id) }
    }

    /// The page shown's name; nil on a canvas without pages.
    var pageName: String? {
        guard let page else { return nil }
        return pages.first { $0.id == page }?.name
    }

    /// Shows another page: its boards and notes, fitted as a design opens; what was selected on
    /// the page left goes.
    func showPage(_ id: String) {
        guard id != page, let index = snapshot?.index, index.pages?.contains(where: { $0.id == id }) == true else { return }
        page = id
        labelRooms = Self.labelRooms(index, page: id)
        let kept = picks.filter { index.isOnPage($0.board, id) }
        if kept != picks { picks = kept }
        hover = nil
        closeComment()
        fitted = false
        fitIfNeeded()
        planLive()
    }

    // MARK: Moving a board

    /// A board dragged by its label (or while selected whole): it follows the pointer, and where
    /// it lands is written once, as its `x` and `y` in canvas.json, when the drag ends.
    /// Answers the write when the drag ends somewhere new.
    @discardableResult
    func move(_ move: NWBoardMove) -> Task<Void, Never>? {
        guard let path = DesignPath(move.board), let board = snapshot?.index.boards[path] else { moving = nil; return nil }
        guard move.ended else {
            if moving != move { moving = move }
            return nil
        }
        moving = nil
        let start = movedTo[path] ?? CGPoint(x: board.x, y: board.y)
        let to = CGPoint(x: (start.x + move.offset.width).rounded(), y: (start.y + move.offset.height).rounded())
        guard to != start, let actions = canvasActions else { return nil }
        movedTo[path] = to
        let patch = JSONValue.object(["boards": .object([path.rawValue: .object(["x": .number(to.x), "y": .number(to.y)])])])
        return Task {
            do {
                try await writeIndex(patch, actions: actions)
                await refresh()
            } catch {
                actions.report("Couldn't move \(nativeBoardName(path.rawValue)): \(error)")
            }
            if movedTo[path] == to { movedTo[path] = nil }
        }
    }

    /// Writes an index change at the revision the canvas read; a stale one reads the design again
    /// and goes once more.
    private func writeIndex(_ patch: JSONValue, actions: DesignCanvasActions) async throws {
        moveWrites += 1
        do {
            _ = try await actions.updateIndex(designID, patch, snapshot?.revision)
        } catch DesignStoreError.stale {
            let fresh = try await actions.snapshot(designID)
            moveWrites += 1
            _ = try await actions.updateIndex(designID, patch, fresh.revision)
        }
    }

    // MARK: Board actions

    /// The board the actions float over: the last pick when it is a board picked whole, while
    /// nothing is presented and the canvas can act.
    var actionsBoard: DesignPath? {
        guard canvasActions != nil, presented == nil, moving == nil, let pick = picks.last, pick.element == nil,
              snapshot?.index.boards[pick.board] != nil else { return nil }
        return pick.board
    }

    /// Whether a board runs as a prototype (`is_interactive`): it offers Play.
    func isInteractive(_ path: DesignPath) -> Bool {
        snapshot?.index.boards[path]?.isInteractive == true
    }

    /// Whether the canvas can ask the design agent for more ("Ask for another direction").
    var canAsk: Bool { canvasActions != nil && !(snapshot?.index.boards.isEmpty ?? true) }

    /// The words Variations and "Ask for another direction" send; the board they are about goes
    /// in the message's view record, as data.
    static let variationsMessage = "Draw variations of the selected board as new boards beside it."
    static let anotherDirectionMessage = "Draw another direction as a new board."

    /// Variations: asks the design agent for variations of `path`, the record naming it selected.
    @discardableResult
    func askForVariations(of path: DesignPath) -> Task<Void, Never>? {
        ask(Self.variationsMessage, record: record(selecting: [Pick(board: path)]))
    }

    /// "Ask for another direction": one more direction, nothing selected in the record.
    @discardableResult
    func askForAnotherDirection() -> Task<Void, Never>? {
        ask(Self.anotherDirectionMessage, record: record(selecting: []))
    }

    private func ask(_ text: String, record: DesignViewRecord?) -> Task<Void, Never>? {
        guard let actions = canvasActions, let record else { return nil }
        let designID = designID
        return Task {
            if !(await actions.ask(designID, text, record)) {
                actions.report("The design has no agent to ask. Open it again to start one.")
            }
        }
    }

    /// The record this screen shows, with `picks` in place of its selection.
    private func record(selecting picks: [Pick]) -> DesignViewRecord? {
        guard let snapshot else { return nil }
        let visible = Set(Self.onScreen(boards, viewport: viewport, size: canvasSize))
        return Self.viewRecord(order: Self.canvasOrder(snapshot.index), visible: visible, picks: picks,
                               page: page, pageName: pageName)
    }

    /// Duplicate: a copy of the board beside it, picked whole once it is there.
    @discardableResult
    func duplicate(_ path: DesignPath) -> Task<Void, Never>? {
        guard let actions = canvasActions else { return nil }
        return Task {
            do {
                let copy: DesignDuplicate
                do {
                    copy = try await actions.duplicate(designID, path, snapshot?.revision)
                } catch DesignStoreError.stale {
                    copy = try await actions.duplicate(designID, path, try await actions.snapshot(designID).revision)
                }
                await refresh()
                if snapshot?.index.boards[copy.path] != nil { take(Pick(board: copy.path), extending: false) }
            } catch {
                actions.report("Couldn't duplicate \(nativeBoardName(path.rawValue)): \(error)")
            }
        }
    }

    // MARK: Present and Play

    /// Whether Present has a board to show.
    var canPresent: Bool { !(snapshot?.index.boards.isEmpty ?? true) }

    /// Present: the last picked board focused, else the one nearest the middle of the view, else
    /// the page's first; Present again goes back to the canvas.
    func togglePresent() {
        if presented != nil { present(nil); return }
        let target = focusBoard ?? visibleBoards.first ?? boards.first.flatMap { DesignPath($0.id) }
        present(target)
    }

    /// Shows `path` focused over the canvas (nil: back to the canvas). Its links move between the
    /// design's boards.
    func present(_ path: DesignPath?) {
        let path = path.flatMap { snapshot?.index.boards[$0] != nil ? $0 : nil }
        guard presented != path else { return }
        presented = path
        if path != nil {
            hover = nil
            closeComment()
        }
        host?.present(path)
        if path == nil { planLive() }
    }

    /// A presented board's link: another board of this design takes its place; anything else is
    /// left alone (the board never navigates).
    func follow(link: DesignPath, from: DesignPath) {
        guard presented == from, let snapshot, let target = Self.playTarget(link, in: snapshot.index) else { return }
        present(target)
    }

    /// Where a Play link goes: a board the design lists; nil for anything else.
    static func playTarget(_ link: DesignPath, in index: DesignIndex) -> DesignPath? {
        index.boards[link] != nil ? link : nil
    }

    // MARK: The view record

    /// What this screen shows, as the chat's messages carry it (view-state.md): the boards on
    /// screen in canvas order, the boards selected whole or holding a selected element, and the
    /// selected elements, most recent last.
    /// While a board is presented, the record is `focused` on it, with nothing selected.
    var viewRecord: DesignViewRecord? {
        guard let snapshot else { return nil }
        if let presented {
            let page = Self.recordPage(page)
            return DesignViewRecord(mode: .focused, page: page, pageName: page == nil ? nil : pageName.flatMap(DesignViewRecord.label),
                                    visibleBoards: [presented.viewName])
        }
        return record(selecting: picks)
    }

    /// A page id as a record carries it: nil when it breaks the id grammar.
    private static func recordPage(_ page: String?) -> String? {
        page.flatMap { DesignPath.isIndexID($0) ? $0 : nil }
    }

    /// The boards whose frames a view of `size` shows.
    static func onScreen(_ boards: [NWCanvasBoard], viewport: NWCanvasViewport, size: CGSize) -> [DesignPath] {
        guard size.width > 0, size.height > 0 else { return [] }
        let shown = viewport.visibleRect(in: size)
        return boards.filter { $0.frame.intersects(shown) }.compactMap { DesignPath($0.id) }
    }

    static func viewRecord(order: [DesignPath], visible: Set<DesignPath>, picks: [Pick], page: String? = nil,
                           pageName: String? = nil) -> DesignViewRecord {
        let elements = Array(picks.compactMap(\.element).suffix(DesignViewRecord.maxSelected))
        let holding = Set(elements.map(\.board))
        let whole = Set(picks.filter { $0.element == nil }.map(\.board))
        var selectedBoards = order.filter { holding.contains($0) }
        for path in order where whole.contains(path) && !holding.contains(path) && selectedBoards.count < DesignViewRecord.maxBoards {
            selectedBoards.append(path)
        }
        selectedBoards = order.filter(Set(selectedBoards).contains)
        let page = recordPage(page)
        return DesignViewRecord(
            mode: .canvas,
            page: page,
            pageName: page == nil ? nil : pageName.flatMap(DesignViewRecord.label),
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

/// The chat pane's tabs (DZCanvas): Chat, Comments, and Tweak for the selection.
enum DesignPaneTab: String, Hashable, Sendable {
    case chat, comments, tweak
}
