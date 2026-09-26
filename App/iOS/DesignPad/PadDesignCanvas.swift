import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// One remote design's canvas on iPad (iPadDesign): its files as the host last served them,
/// where the canvas looks, the tool, what is selected, its comments, and the renderer drawing
/// its boards on this device. Everything that changes the design goes to the host through
/// `designs.v1` (`RemoteDesignLibrary.request`), the same server paths and checks as the host's
/// own canvas; a stale revision reads the design again and goes once more.
///
/// The Mac's `DesignScreenModel` for touch: a tap names the element under it (the board's hit
/// test), a tap on a board's label or where nothing is named picks the board whole, a tap on the
/// empty canvas clears it. What the canvas shows goes with every message the chat sends
/// (`viewRecord`).
@MainActor
@Observable
final class PadDesignCanvas {
    let ref: PadDesignRef
    var viewport = NWCanvasViewport() {
        didSet { if viewport != oldValue { viewportMoved() } }
    }
    var tool: NWCanvasTool = .select
    /// What is selected, most recent last: boards picked whole, and elements.
    private(set) var picks: [Pick] = []
    private(set) var snapshot: DesignSnapshot?
    /// The last pull failed (the canvas keeps what it drew).
    private(set) var loadError: String?
    /// The chat pane's tab (iPadDesign): Chat, Tweak or Comments.
    var paneTab: PadDesignPaneTab = .chat
    /// A narrow window stacks the page's boards in one column, in canvas order (iPadSplitView),
    /// wherever the canvas puts them; the design's own layout is untouched.
    var column = false {
        didSet {
            guard column != oldValue else { return }
            fitted = false
            fitIfNeeded()
            planLive()
        }
    }

    // Comments
    private(set) var comments: [DesignComment] = []
    /// The comment whose thread is open beside its pin.
    private(set) var openComment: UUID?
    /// The element a new comment is being written on (the Comment tool's tap).
    private(set) var draftElement: PadDesignPick?
    var draftText = ""
    var replyText = ""
    private(set) var pinRects: [UUID: CGRect] = [:]
    private(set) var sendingComment = false
    /// A change to the design that didn't go (shown once, then cleared).
    var problem: String?

    /// The page the canvas shows; nil on a canvas without pages.
    private(set) var page: String?
    /// The board shown focused (Present, Play); nil on the canvas.
    private(set) var presented: DesignPath?

    @ObservationIgnored let library: RemoteDesignLibrary
    @ObservationIgnored let source: RemoteDesignSource
    @ObservationIgnored let host: PadDesignHost
    @ObservationIgnored private(set) var commentsRevision: UInt64 = 0
    @ObservationIgnored private var canvasSize: CGSize = .zero
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var rest: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var labelRooms: [String: NWLabelRoom] = [:]
    @ObservationIgnored private var picking: Task<Void, Never>?
    /// The Tweak tab's model (DZTweak's, shared with the Mac): its writes go to the host.
    @ObservationIgnored let tweak: DesignTweakModel

    static let restDelay: Duration = .milliseconds(120)

    init(ref: PadDesignRef, library: RemoteDesignLibrary) {
        self.ref = ref
        self.library = library
        let source = library.source(ref.design)
        self.source = source
        host = PadDesignRendering.shared.host(for: ref, source: source)
        tweak = DesignTweakModel(designID: ref.design, io: Self.tweakIO(library, source: source, design: ref.design), host: host)
        host.source = { path in try await source.source(path) }
        host.redrawn = { [weak self] path in self?.relocate(on: path) }
        host.linked = { [weak self] from, to in self?.follow(link: to, from: from) }
        tweak.previewed = { [weak self] path in self?.remeasure(path) }
    }

    /// Tweak's reads and writes through `designs.v1`: the same server mutations and checks as the
    /// host's own canvas. The project's stylesheets are on the host, so a tweak snaps to the
    /// board's own tokens and the system's.
    private static func tweakIO(_ library: RemoteDesignLibrary, source: RemoteDesignSource, design: DesignID) -> DesignTweakIO {
        DesignTweakIO(
            snapshot: { try await source.sync().snapshot },
            board: { path in
                let text = try await source.source(path)
                let index = source.index
                return DesignBoardSource(path: path, source: text, sha256: index?.snapshot.boards[path] ?? "",
                                         revision: index?.snapshot.revision ?? 0)
            },
            writeBoards: { sources, base in
                let raw = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) })
                guard case .boardsWritten(let write) = try await library.request(.writeBoards(designID: design, sources: raw,
                                                                                               baseRevision: base)) else {
                    throw PadDesignCanvas.unexpected
                }
                return write.write
            },
            updateIndex: { patch, base in
                guard case .written(let result) = try await library.request(.updateIndex(designID: design, patch: patch,
                                                                                          baseRevision: base)) else {
                    throw PadDesignCanvas.unexpected
                }
                return result
            },
            restore: { versions, current in
                let raw = Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, $0.value) })
                let ifCurrent = current.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
                guard case .boardsWritten(let write) = try await library.request(.restoreVersions(designID: design, versions: raw,
                                                                                                   ifCurrent: ifCurrent)) else {
                    throw PadDesignCanvas.unexpected
                }
                return write.write
            },
            projectTokens: { DesignTokens() },
            isStale: { PadDesignCanvas.isStale($0) })
    }

    // MARK: Boards

    /// Every board of the page as the canvas draws it, back to front.
    var boards: [NWCanvasBoard] {
        guard let snapshot else { return [] }
        let tokens = host.tokens
        let whole = selectedWhole
        var top: Double = 0
        return Self.canvasOrder(snapshot.index).compactMap { path in
            guard let board = snapshot.index.boards[path], snapshot.index.isOnPage(path, page) else { return nil }
            let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            var frame = CGRect(x: board.x, y: board.y, width: board.w, height: board.h)
            if column {
                frame.origin = CGPoint(x: 0, y: top)
                top += board.h + Self.columnGap
            }
            return NWCanvasBoard(id: path.rawValue, frame: frame,
                                 title: title?.isEmpty == false ? title! : path.stem,
                                 size: NWCanvasBoard.sizeLabel(CGSize(width: board.w, height: board.h)),
                                 isSelected: whole.contains(path), content: tokens[path] ?? 0,
                                 labelRoom: column ? .open : labelRooms[path.rawValue] ?? .open)
        }
    }

    /// Between boards stacked in a column, in canvas points: room for the next board's label.
    static let columnGap: Double = 120

    /// The page's title and sticky notes (drawings aren't drawn yet).
    var notes: [NWCanvasNote] {
        guard let index = snapshot?.index else { return [] }
        return (index.notes ?? [:]).sorted { $0.key < $1.key }.compactMap { id, note in
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

    /// A board's title as its label reads ("A · Funnel first").
    func title(_ path: DesignPath) -> String {
        let title = snapshot?.index.boards[path]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : path.stem
    }

    static func canvasOrder(_ index: DesignIndex) -> [DesignPath] {
        let listed = index.order.filter { index.boards[$0] != nil }
        let rest = index.boards.keys.filter { !listed.contains($0) }.sorted()
        return listed + rest
    }

    /// The boards on screen, nearest the middle of the view first.
    var visibleBoards: [DesignPath] {
        let middle = viewport.canvas(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        return boards.visible(in: viewport, size: canvasSize)
            .sorted { Self.distance($0.frame, middle) < Self.distance($1.frame, middle) }
            .compactMap { DesignPath($0.id) }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Every board on screen draws its current version (the fixtures wait on it).
    var isDrawn: Bool {
        snapshot != nil && canvasSize.width > 0 && host.isDrawn(visibleBoards)
    }

    // MARK: Pulling

    /// Reads the design (only files whose hash changed travel) and hands the renderer the
    /// boards that changed, then its comments. A pull asked for while one runs runs again after.
    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            do {
                apply(try await source.sync().snapshot)
                if loadError != nil { loadError = nil }
            } catch {
                loadError = Self.message(error)
            }
            await refreshComments()
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
            let shown = next.index.boards.filter { next.index.isOnPage($0.key, page) }
            labelRooms = NWLabelRoom.rooms(Dictionary(shown.map { ($0.key.rawValue, CGRect(x: $0.value.x, y: $0.value.y,
                                                                                          width: $0.value.w, height: $0.value.h)) },
                                                      uniquingKeysWith: { a, _ in a }))
        }
        snapshot = next
        let kept = picks.filter { next.index.boards[$0.board] != nil && next.index.isOnPage($0.board, page) }
        if kept != picks { picks = kept }
        if let presented, next.index.boards[presented] == nil { present(nil) }
        var boards: [DesignPath: PadDesignHost.Board] = [:]
        for (path, board) in next.index.boards {
            guard let sha = next.boards[path] else { continue }
            let tweaks = next.index.tweaks(for: path)
            boards[path] = PadDesignHost.Board(size: CGSize(width: board.w, height: board.h), sha: sha,
                                               props: tweaks.isEmpty ? nil : DesignTweakModel.json(.object(tweaks)))
        }
        host.update(boards)
        Task { await tweak.snapshotChanged(next) }
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

    private func fitIfNeeded() {
        guard !fitted, canvasSize.width > 0, canvasSize.height > 0, let snapshot, !snapshot.index.boards.isEmpty else { return }
        fitted = true
        guard column else {
            viewport = .fitting(boards.bounds, in: canvasSize)
            return
        }
        // A column opens at its top, its widest board filling the window's width.
        let inset = MobileLayout.gutter
        let widest = boards.map(\.frame.width).max() ?? canvasSize.width
        let zoom = NWCanvasViewport.clamp(min(1, (canvasSize.width - 2 * inset) / max(1, widest)))
        viewport = NWCanvasViewport(offset: CGPoint(x: inset, y: NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap + inset), zoom: zoom)
    }

    // MARK: Selection

    struct Pick: Equatable {
        let board: DesignPath
        var element: PadDesignPick?
    }

    var selectedWhole: Set<DesignPath> { Set(picks.filter { $0.element == nil }.map(\.board)) }
    var selectedElements: [PadDesignPick] { picks.compactMap(\.element) }
    var focusBoard: DesignPath? { picks.last?.board }

    /// A tap (`NWDesignCanvas`). With Select: an element when the board names one under it, the
    /// board whole on its label or where nothing is named, nothing on the empty canvas. With
    /// Comment: a new comment on the element under it. Either closes the thread that was open.
    func pick(_ pick: NWCanvasPick) {
        let board = pick.board.flatMap(DesignPath.init)
        let commenting = tool == .comment
        closeComment()
        guard let board, let point = pick.point else {
            resolve(pick, on: board, element: nil, commenting: commenting)
            return
        }
        let previous = picking
        picking = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let element = await self.host.hitTest(board, at: point)
            self.resolve(pick, on: board, element: element, commenting: commenting)
        }
    }

    private func resolve(_ pick: NWCanvasPick, on board: DesignPath?, element: PadDesignPick?, commenting: Bool) {
        if commenting {
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
        if next.count > DesignViewRecord.maxSelected { next.removeFirst(next.count - DesignViewRecord.maxSelected) }
        guard next != picks else { return }
        picks = next
        planLive()
    }

    func clearSelection() {
        guard !picks.isEmpty else { return }
        picks = []
        planLive()
    }

    /// Fixtures: what is selected, as the boards would have reported it.
    func setSelection(_ picks: [Pick]) {
        self.picks = Array(picks.suffix(DesignViewRecord.maxSelected))
        planLive()
    }

    /// A live board drew new source: its selected elements are found again where it draws them
    /// now, and its comments' pins move with their elements.
    func relocate(on board: DesignPath) {
        locatePins(on: board)
        let tids = picks.compactMap { $0.board == board ? $0.element?.id.tid : nil }
        guard !tids.isEmpty else { return }
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

    /// Where a tweak previewed on a board moved its selected elements.
    func remeasure(_ board: DesignPath) {
        relocate(on: board)
    }

    // MARK: Comments

    var openComments: [DesignComment] { comments.filter(\.isOpen) }

    var pins: [NWCanvasPin] {
        guard let snapshot else { return [] }
        var pins = openComments.compactMap { comment -> NWCanvasPin? in
            guard snapshot.index.boards[comment.board] != nil else { return nil }
            return NWCanvasPin(id: comment.id.uuidString, board: comment.board.rawValue, rect: pinRect(comment), number: comment.number)
        }
        if let draft = draftElement {
            pins.append(NWCanvasPin(id: Self.draftPin, board: draft.board.rawValue, rect: draft.rect,
                                    number: (comments.map(\.number).max() ?? 0) + 1))
        }
        return pins
    }

    static let draftPin = "draft"

    private func pinRect(_ comment: DesignComment) -> CGRect {
        if let rect = pinRects[comment.id] { return rect }
        guard let rect = comment.rect else { return .zero }
        return CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
    }

    var popoverAnchor: NWCanvasElement? {
        if let draft = draftElement {
            return NWCanvasElement(id: Self.draftPin, board: draft.board.rawValue, rect: draft.rect)
        }
        guard let id = openComment, let comment = comments.first(where: { $0.id == id }) else { return nil }
        return NWCanvasElement(id: id.uuidString, board: comment.board.rawValue, rect: pinRect(comment))
    }

    var openThread: DesignComment? { openComment.flatMap { id in comments.first { $0.id == id } } }

    func beginComment(on element: PadDesignPick) {
        take(Pick(board: element.board, element: element), extending: false)
        draftElement = element
        draftText = ""
        openComment = nil
    }

    func closeComment() {
        if draftElement != nil { draftElement = nil }
        if openComment != nil { openComment = nil }
    }

    /// A pin, or a card in the Comments tab: its thread opens beside it.
    func openThread(_ id: String) {
        guard let id = UUID(uuidString: id), comments.contains(where: { $0.id == id }) else { return }
        draftElement = nil
        replyText = ""
        openComment = id
    }

    /// Keeps the comment being written: the host checks its element and hands it to the design
    /// agent fenced as data, as a turn of its own.
    @discardableResult
    func submitComment() -> Task<Void, Never>? {
        guard let element = draftElement, !sendingComment else { return nil }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { closeComment(); return nil }
        let draft = DesignCommentDraft(
            board: element.board, tid: element.id.tid, path: element.id.path, label: element.label, target: element.words,
            rect: DesignCommentRect(x: element.rect.minX, y: element.rect.minY, w: element.rect.width, h: element.rect.height), text: text)
        sendingComment = true
        let design = ref.design
        return Task {
            defer { sendingComment = false }
            do {
                let (comment, undelivered) = try await commentWrite { .addComment(designID: design, draft: draft, baseRevision: $0) }
                comments.append(comment)
                pinRects[comment.id] = element.rect
                if draftElement == element { draftElement = nil }
                draftText = ""
                openComment = comment.id
                if let undelivered { problem = "The comment is saved, but it didn't reach the design agent: \(undelivered)" }
            } catch {
                problem = "Couldn't keep the comment: \(Self.message(error))"
            }
            await refreshComments()
        }
    }

    @discardableResult
    func sendReply() -> Task<Void, Never>? {
        guard let id = openComment, !sendingComment else { return nil }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        sendingComment = true
        let design = ref.design
        return Task {
            defer { sendingComment = false }
            do {
                let (comment, undelivered) = try await commentWrite {
                    .replyToComment(designID: design, commentID: id, text: text, baseRevision: $0)
                }
                replace(comment)
                replyText = ""
                if let undelivered { problem = "The reply is saved, but it didn't reach the design agent: \(undelivered)" }
            } catch {
                problem = "Couldn't keep the reply: \(Self.message(error))"
            }
            await refreshComments()
        }
    }

    /// Resolve: only the viewer resolves a comment. Its pin and thread leave the canvas.
    @discardableResult
    func resolve(_ id: UUID) -> Task<Void, Never>? {
        let design = ref.design
        return Task {
            do {
                let (comment, _) = try await commentWrite {
                    .resolveComment(designID: design, commentID: id, resolved: true, baseRevision: $0)
                }
                replace(comment)
                if openComment == id { openComment = nil }
            } catch {
                problem = "Couldn't resolve the comment: \(Self.message(error))"
            }
            await refreshComments()
        }
    }

    /// A comment change at the comments' revision; a stale one reads them again and goes once more.
    private func commentWrite(_ body: (UInt64?) -> RemoteDesignRequest) async throws -> (DesignComment, String?) {
        let result: RemoteDesignResult
        do {
            result = try await library.request(body(commentsRevision))
        } catch let error where Self.isStale(error) {
            guard case .comments(let fresh) = try await library.request(.comments(designID: ref.design)) else { throw Self.unexpected }
            result = try await library.request(body(fresh.revision))
        }
        guard case .comment(let comment, let undelivered) = result else { throw Self.unexpected }
        return (comment, undelivered)
    }

    func refreshComments() async {
        guard case .comments(let next)? = try? await library.request(.comments(designID: ref.design)) else { return }
        applyComments(next)
    }

    func applyComments(_ next: DesignComments) {
        guard next.revision >= commentsRevision else { return }
        commentsRevision = next.revision
        if next.comments != comments { comments = next.comments }
        if let id = openComment, comments.first(where: { $0.id == id })?.isOpen != true { openComment = nil }
        for board in Set(openComments.map(\.board)) { locatePins(on: board) }
    }

    private func replace(_ comment: DesignComment) {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        if comments[index] != comment { comments[index] = comment }
    }

    private func locatePins(on board: DesignPath) {
        let onBoard = openComments.filter { $0.board == board && !$0.detached }
        guard !onBoard.isEmpty, host.liveBoards.contains(board) else { return }
        Task {
            guard let found = await host.locate(board, tids: onBoard.map(\.tid)) else { return }
            var next = pinRects
            for comment in onBoard {
                if let pick = found[comment.tid], pick.id.path == comment.path { next[comment.id] = pick.rect }
            }
            if next != pinRects { pinRects = next }
        }
    }

    /// The open comments' cards, for the Comments tab: "on A · Checkout funnel", "You · 2m".
    func cards(now: Date = Date()) -> [PadDesignCommentCard] {
        openComments.map { comment in
            let board = nativeBoardName(comment.board.rawValue)
            let target = comment.target.map { "\(board) · \($0)" } ?? board
            let meta = ["You · \(nwCommentAge(since: comment.createdAt, now: now))", comment.detached ? "element changed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            return PadDesignCommentCard(id: comment.id, number: comment.number, target: target, meta: meta, text: comment.text)
        }
    }

    // MARK: Pages

    var pages: [(id: String, name: String)] {
        (snapshot?.index.pages ?? []).map { ($0.id, $0.name?.isEmpty == false ? $0.name! : $0.id) }
    }

    var pageName: String? {
        guard let page else { return nil }
        return pages.first { $0.id == page }?.name
    }

    // MARK: Board actions

    /// The board the actions float over: the last pick when it is a board picked whole.
    var actionsBoard: DesignPath? {
        guard presented == nil, let pick = picks.last, pick.element == nil, snapshot?.index.boards[pick.board] != nil else { return nil }
        return pick.board
    }

    func isInteractive(_ path: DesignPath) -> Bool {
        snapshot?.index.boards[path]?.isInteractive == true
    }

    /// Duplicate: a copy of the board beside it, through the host, picked whole once it is there.
    @discardableResult
    func duplicate(_ path: DesignPath) -> Task<Void, Never>? {
        let design = ref.design
        return Task {
            do {
                let result: RemoteDesignResult
                do {
                    result = try await library.request(.duplicateBoard(designID: design, path: path.rawValue, baseRevision: snapshot?.revision))
                } catch let error where Self.isStale(error) {
                    let fresh = try await source.sync().snapshot
                    result = try await library.request(.duplicateBoard(designID: design, path: path.rawValue, baseRevision: fresh.revision))
                }
                guard case .duplicated(let copy, _) = result else { throw Self.unexpected }
                await refresh()
                if snapshot?.index.boards[copy] != nil { take(Pick(board: copy), extending: false) }
            } catch {
                problem = "Couldn't duplicate \(nativeBoardName(path.rawValue)): \(Self.message(error))"
            }
        }
    }

    /// Sends the design agent a message with a view record (the chat's thread); false when the
    /// design has no agent. Set by the screen.
    @ObservationIgnored var ask: ((String, DesignViewRecord) async -> Bool)?

    static let variationsMessage = "Draw variations of the selected board as new boards beside it."

    /// Variations: asks the design agent for variations of `path`, the record naming it selected.
    @discardableResult
    func askForVariations(of path: DesignPath) -> Task<Void, Never>? {
        guard let ask, var record = viewRecord, record.mode == .canvas else { return nil }
        record.selectedBoards = [path.viewName]
        record.selected = []
        record.selection = []
        return Task {
            if !(await ask(Self.variationsMessage, record)) {
                problem = "The design has no agent to ask. Open it on its host to start one."
            }
        }
    }

    // MARK: The design system

    /// The system's colors on the header's chip, read from the host once per namespace.
    private(set) var systemSwatches: [DesignSystemPresentation.Swatch] = []
    @ObservationIgnored private var systemRead: String?

    /// The chip's name: the design's system; nil while it is drawn in none (no chip, as on the
    /// Mac: a design belongs to no project).
    func systemName(_ design: Design?) -> String? {
        design?.systemNamespace ?? snapshot?.index.designSystems?.first?.namespace
    }

    func loadSystem(_ namespace: String?) async {
        guard let namespace, systemRead != namespace,
              case .system(let read)? = try? await library.request(.system(namespace: namespace)) else { return }
        systemRead = namespace
        let swatches = DesignSystemPresentation.swatches(read.tokens, count: 3)
        if swatches != systemSwatches { systemSwatches = swatches }
    }

    // MARK: Export

    /// The page's boards as this iPad drew them, as PNG files in a temporary folder of their own:
    /// what Export shares. Boards not drawn yet are left out.
    func exportPNGs(name: String) -> [URL]? {
        let paths = boards.compactMap { DesignPath($0.id) }
        let images = host.pngs(paths)
        guard !images.isEmpty else {
            problem = "Nothing is drawn yet to export."
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DesignExport-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try images.map { image in
                let url = folder.appendingPathComponent(DesignExportNames.fileName(name) + " - " + image.name)
                try image.data.write(to: url, options: .atomic)
                return url
            }
        } catch {
            problem = "Couldn't export the boards: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Present and Play

    var canPresent: Bool { !(snapshot?.index.boards.isEmpty ?? true) }

    func present(_ path: DesignPath?) {
        let path = path.flatMap { snapshot?.index.boards[$0] != nil ? $0 : nil }
        guard presented != path else { return }
        presented = path
        if path != nil { closeComment() }
        host.present(path)
        if path == nil { planLive() }
    }

    /// A presented board's link: another board of this design takes its place.
    func follow(link: DesignPath, from: DesignPath) {
        guard presented == from, snapshot?.index.boards[link] != nil else { return }
        present(link)
    }

    // MARK: The view record

    /// What this screen shows, as the chat's messages carry it (view-state.md).
    var viewRecord: DesignViewRecord? {
        guard let snapshot else { return nil }
        if let presented {
            return DesignViewRecord(mode: .focused, visibleBoards: [presented.viewName])
        }
        let order = Self.canvasOrder(snapshot.index)
        let shown = viewport.visibleRect(in: canvasSize)
        let visible = Set(canvasSize.width > 0 ? boards.filter { $0.frame.intersects(shown) }.compactMap { DesignPath($0.id) } : [])
        let elements = Array(selectedElements.suffix(DesignViewRecord.maxSelected))
        let holding = Set(elements.map(\.board))
        let whole = selectedWhole
        let selectedBoards = order.filter { holding.contains($0) || whole.contains($0) }.prefix(DesignViewRecord.maxBoards)
        let page = page.flatMap { DesignPath.isIndexID($0) ? $0 : nil }
        return DesignViewRecord(
            mode: .canvas, page: page, pageName: page == nil ? nil : pageName.flatMap(DesignViewRecord.label),
            visibleBoards: Array(order.filter(visible.contains).prefix(DesignViewRecord.maxBoards)).map(\.viewName),
            selectedBoards: selectedBoards.map(\.viewName),
            selected: elements.map(\.id),
            selection: elements.suffix(DesignViewRecord.maxSelection).map { .init(id: $0.id, kind: $0.kind, label: $0.label) },
            dirty: false)
    }

    // MARK: Live views

    func setZooming(_ zooming: Bool) {
        host.setZooming(zooming)
        if !zooming { planLive() }
    }

    /// On screen, the design takes a live view and pulls what changed while it was away.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        host.setActive(active)
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

    func planLive() {
        guard isActive, !host.zooming, canvasSize.width > 0 else { return }
        host.show(visible: visibleBoards, selected: focusBoard, zoom: viewport.zoom)
    }

    // MARK: Errors

    static func isStale(_ error: any Error) -> Bool {
        if case RemoteHostClientError.rejected(let code, _) = error { return code == "stale_revision" }
        return false
    }

    static func message(_ error: any Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }

    static let unexpected = RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
}

/// The chat pane's tabs, in the iPadDesign board's order.
enum PadDesignPaneTab: String, Hashable, Sendable {
    case chat, tweak, comments
}

/// A comment's card in the Comments tab.
struct PadDesignCommentCard: Equatable, Identifiable {
    let id: UUID
    let number: Int
    let target: String
    let meta: String
    let text: String
}
