import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Design tool's pure rules: which boards get a live view and which views make room, the
/// Designs page's cards, the canvas's boards from a canvas.json, the sidebar's Designs
/// destination and design rows, and the experiment's switch.
@Suite("Design tool")
@MainActor
struct DesignToolTests {
    private static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }
    private static let paths = (0..<12).map { path("Board\($0).dc.html") }

    // MARK: Live views

    @Test func theSelectedBoardComesFirstThenTheVisibleOnesUpToTheCap() {
        let wanted = DesignLivePlan.wanted(visible: Array(Self.paths.prefix(8)), selected: Self.paths[9], zoom: 0.5)
        #expect(wanted == [Self.paths[9]] + Array(Self.paths.prefix(DesignLivePlan.liveCap - 1)))
        #expect(wanted.count == DesignLivePlan.liveCap)
    }

    /// Too small to read: snapshots, though the selected board stays live a while longer.
    @Test(arguments: [(CGFloat(0.2), 1), (0.05, 0), (0.25, 5)])
    func belowTheThresholdBoardsDrawFromSnapshots(zoom: CGFloat, live: Int) {
        let wanted = DesignLivePlan.wanted(visible: Self.paths, selected: Self.paths[0], zoom: zoom)
        #expect(wanted.count == live)
    }

    @Test func aCapOfNoneMakesEveryBoardASnapshot() {
        #expect(DesignLivePlan.wanted(visible: Self.paths, selected: Self.paths[0], zoom: 1, cap: 0).isEmpty)
    }

    @Test func boardsKeepTheirViewsAndNewOnesTakeFreeSlots() {
        let slots: [DesignPath: UInt64] = [Self.paths[0]: 1, Self.paths[1]: 1]
        let assignment = DesignLivePlan.assign(slots: slots, wanted: [Self.paths[0], Self.paths[2]])
        #expect(assignment == DesignLivePlan.Assignment(evict: [], create: [Self.paths[2]]))
    }

    @Test func aFullSetGivesUpTheLeastRecentlyWantedViewsFirst() {
        let slots: [DesignPath: UInt64] = [Self.paths[0]: 5, Self.paths[1]: 2, Self.paths[2]: 9, Self.paths[3]: 1, Self.paths[4]: 7]
        let assignment = DesignLivePlan.assign(slots: slots, wanted: [Self.paths[2], Self.paths[5], Self.paths[6]])
        #expect(assignment.create == [Self.paths[5], Self.paths[6]])
        #expect(assignment.evict == [Self.paths[3], Self.paths[1]])
    }

    /// Panning across a wide canvas keeps the views at the cap and moves them along with the view.
    @Test func panningRecyclesViewsWithinTheCap() {
        var slots: [DesignPath: UInt64] = [:]
        var created = 0
        for (stamp, start) in stride(from: 0, to: 8, by: 1).enumerated() {
            let visible = Array(Self.paths[start..<min(start + 4, Self.paths.count)])
            let wanted = DesignLivePlan.wanted(visible: visible, selected: nil, zoom: 1)
            for path in wanted where slots[path] != nil { slots[path] = UInt64(stamp + 1) }
            let assignment = DesignLivePlan.assign(slots: slots, wanted: wanted)
            for path in assignment.evict { slots.removeValue(forKey: path) }
            for path in assignment.create { slots[path] = UInt64(stamp + 1) }
            created += assignment.create.count
            #expect(slots.count <= DesignLivePlan.liveCap)
            #expect(Set(wanted).isSubset(of: slots.keys))
        }
        #expect(created == 11, "each board gets a view once as the view passes over it")
        #expect(slots[Self.paths[0]] == nil, "the first boards' views went to the later ones")
    }

    // MARK: The Designs page

    private static let web = Space(name: "acme-web", path: "/tmp/acme-web")
    private static let app = Space(name: "shepherd", path: "/tmp/shepherd")
    private static let now = Date(timeIntervalSince1970: 1_790_215_200)

    private func design(_ name: String, space: Space = web, edited: Double, boards: Int? = 4, system: String? = nil) -> Design {
        Design(name: name, spaceID: space.id, systemNamespace: system, createdAt: 1_000,
               lastActiveAt: (Self.now.timeIntervalSince1970 - edited) * 1000, boardCount: boards)
    }

    @Test func cardsAreMostRecentlyEditedFirstWithTheirSystemAndCounts() {
        let old = design("Onboarding", space: Self.app, edited: 3 * 3600, boards: 1)
        let new = design("Checkout funnel dashboard", edited: 7200)
        let model = DesignsPageModel.make(designs: [old, new], spaces: [Self.web, Self.app], firstBoards: [:], filter: "",
                                          selection: new.id, now: Self.now)
        #expect(model.cards.map(\.name) == ["Checkout funnel dashboard", "Onboarding"])
        #expect(model.cards.map(\.system) == ["acme-web", "shepherd"])
        #expect(model.cards.map(\.detail) == ["4 boards", "1 board"])
        #expect(model.cards.map(\.edited) == ["edited 2h ago", "edited 3h ago"])
        #expect(model.cards.map(\.selected) == [true, false])
        #expect(model.systems.isEmpty, "the systems are the host's, never the designs' projects")
    }

    @Test func aDesignsOwnSystemWinsOverItsProject() {
        let model = DesignsPageModel.make(designs: [design("A", edited: 60, system: "night-watch"), design("B", edited: 120)],
                                          spaces: [Self.web], firstBoards: [:], filter: "", selection: nil, now: Self.now)
        #expect(model.cards.map(\.system) == ["night-watch", "acme-web"])
    }

    @Test(arguments: [("checkout", ["Checkout funnel dashboard"]), ("SHEPHERD", ["Onboarding"]), ("  ", ["Checkout funnel dashboard", "Onboarding"]),
                      ("nothing", [])])
    func theFilterMatchesNamesAndSystems(filter: String, names: [String]) {
        let model = DesignsPageModel.make(designs: [design("Checkout funnel dashboard", edited: 60),
                                                    design("Onboarding", space: Self.app, edited: 120)],
                                          spaces: [Self.web, Self.app], firstBoards: [:], filter: filter, selection: nil, now: Self.now)
        #expect(model.cards.map(\.name) == names)
        #expect(model.noMatch == names.isEmpty)
    }

    @Test func cardsComeInRowsOfFour() {
        let designs = (0..<9).map { design("Design \($0)", edited: Double($0) * 60) }
        let model = DesignsPageModel.make(designs: designs, spaces: [Self.web], firstBoards: [:], filter: "", selection: nil, now: Self.now)
        #expect(model.rows.map(\.count) == [4, 4, 1])
    }

    @Test func aCardDrawsItsFirstBoardAsItWasLastRead() {
        let desktop = design("Desktop", edited: 60), phone = design("Phone", edited: 120), none = design("Nothing yet", edited: 180, boards: 0)
        let model = DesignsPageModel.make(designs: [desktop, phone, none], spaces: [Self.web],
                                          firstBoards: [desktop.id: .init(size: CGSize(width: 1280, height: 800), version: 3),
                                                        phone.id: .init(size: CGSize(width: 390, height: 844), version: 1)],
                                          filter: "", selection: nil, now: Self.now)
        #expect(model.cards.map(\.board) == [.desktop, .phone, .none])
        #expect(model.cards.map(\.thumbnail) == [3, 1, 0])
        #expect(model.cards.last?.detail == "0 boards")
    }

    // MARK: The canvas

    private static func index() throws -> DesignIndex {
        try DesignIndex.decode(Data("""
        {"v":3,"title":"Checkout","boards":{
          "A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"title":"A · Funnel first"},
          "B.dc.html":{"x":1360,"y":0,"w":1280,"h":800,"title":"  "},
          "A-phone.dc.html":{"x":0,"y":920,"w":390,"h":844,"title":"A · phone"}},
         "order":["B.dc.html","A.dc.html"]}
        """.utf8))
    }

    @Test func theCanvasDrawsTheIndexsBoardsBackToFront() throws {
        let boards = DesignScreenModel.boards(try Self.index(), selected: [Self.path("A.dc.html")], tokens: [Self.path("B.dc.html"): 4])
        // Listed boards in their order, then any the order leaves out.
        #expect(boards.map(\.id) == ["B.dc.html", "A.dc.html", "A-phone.dc.html"])
        #expect(boards.map(\.title) == ["B", "A · Funnel first", "A · phone"], "a blank title reads as the file's stem")
        #expect(boards.map(\.size) == ["1280 × 800", "1280 × 800", "390 × 844"])
        #expect(boards.map(\.isSelected) == [false, true, false])
        #expect(boards.map(\.content) == [4, 0, 0])
        #expect(boards[2].frame == CGRect(x: 0, y: 920, width: 390, height: 844))
    }

    /// canvas.json's `order` is read as written, so a board it lists twice (an imported or
    /// hand-edited canvas) is still one board: one frame, and one live view at most.
    @Test func aBoardTheOrderListsTwiceIsDrawnOnce() throws {
        let index = try DesignIndex.decode(Data("""
        {"v":3,"title":"Checkout","boards":{
          "A.dc.html":{"x":0,"y":0,"w":1280,"h":800},
          "B.dc.html":{"x":1360,"y":0,"w":1280,"h":800},
          "C.dc.html":{"x":0,"y":920,"w":390,"h":844}},
         "order":["B.dc.html","A.dc.html","B.dc.html","A.dc.html"]}
        """.utf8))
        #expect(DesignScreenModel.canvasOrder(index).map(\.rawValue) == ["B.dc.html", "A.dc.html", "C.dc.html"])
        let boards = DesignScreenModel.boards(index, selected: [], tokens: [:])
        #expect(boards.map(\.id) == ["B.dc.html", "A.dc.html", "C.dc.html"])
        let visible = DesignScreenModel.visible(boards, viewport: NWCanvasViewport(offset: .zero, zoom: 0.25),
                                                size: CGSize(width: 1600, height: 800))
        #expect(visible.count == Set(visible).count)
    }

    @Test func theBoardsOnScreenAreNearestTheMiddleFirst() throws {
        let boards = DesignScreenModel.boards(try Self.index(), selected: [], tokens: [:])
        let viewport = NWCanvasViewport(offset: .zero, zoom: 0.5)
        // The view's middle is canvas (1600, 400): inside B.
        let visible = DesignScreenModel.visible(boards, viewport: viewport, size: CGSize(width: 1600, height: 800))
        #expect(visible.map(\.rawValue) == ["B.dc.html", "A.dc.html", "A-phone.dc.html"])
    }

    // MARK: Selection and the view record

    static func element(_ name: String, _ tid: Int, _ steps: [Int], label: String? = "Checkout funnel") -> DesignElementPick {
        let board = path(name)
        return DesignElementPick(board: board, id: DesignElementID(board: board.viewName, tid: tid, path: steps)!,
                                 rect: CGRect(x: 40, y: 280, width: 640, height: 216), kind: .shape, label: label,
                                 tag: "card · \(label ?? "")")
    }

    /// The record lists the boards on screen in canvas order, the boards selected whole or holding
    /// a selected element, and the elements most recent last, the last five labelled.
    @Test func theViewRecordNamesWhatTheScreenShowsInTheGrammar() throws {
        let index = try Self.index()
        let order = DesignScreenModel.canvasOrder(index)
        let picks: [DesignScreenModel.Pick] = [
            .init(board: Self.path("A-phone.dc.html")),
            .init(board: Self.path("A.dc.html"), element: Self.element("A.dc.html", 12, [1, 0, 2])),
        ] + (0..<5).map { .init(board: Self.path("B.dc.html"), element: Self.element("B.dc.html", $0, [1, $0], label: "row \($0)")) }
        let record = DesignScreenModel.viewRecord(order: order, visible: [Self.path("A.dc.html"), Self.path("B.dc.html")], picks: picks)
        #expect(record.isValid)
        #expect(record.mode == .canvas && !record.dirty)
        #expect(record.visibleBoards == ["B.dc.html", "A.dc.html"], "canvas order, not the order found")
        #expect(record.selectedBoards == ["B.dc.html", "A.dc.html", "A-phone.dc.html"])
        #expect(record.selected.map(\.description) == ["A.dc.html#12:1/0/2"] + (0..<5).map { "B.dc.html#\($0):1/\($0)" })
        #expect(record.selection.map(\.id.description) == (0..<5).map { "B.dc.html#\($0):1/\($0)" })
        #expect(record.selection.last?.label == "row 4" && record.selection.last?.kind == .shape)
    }

    @Test func aRecordKeepsItsLimitsHoweverMuchIsSelected() throws {
        let boards = (0..<30).map { Self.path("B\($0).dc.html") }
        let picks = boards.map { DesignScreenModel.Pick(board: $0) }
            + (0..<25).map { DesignScreenModel.Pick(board: boards[0], element: Self.element("B0.dc.html", $0, [0, $0])) }
        let record = DesignScreenModel.viewRecord(order: boards, visible: Set(boards), picks: picks)
        #expect(record.isValid)
        #expect(record.visibleBoards.count == 20 && record.selectedBoards.count == 20 && record.selected.count == 20)
        #expect(record.selected.first?.tid == 5, "the latest twenty")
        #expect(record.selectedBoards.first == "B0.dc.html", "the board holding the elements stays")
    }

    @MainActor
    @Test func aClickPicksABoardShiftExtendsAndTheEmptyCanvasClears() throws {
        let screen = DesignScreenModel(designID: DesignID(), host: nil, snapshot: { _ in throw CancellationError() },
                                       source: { _, _ in "" })
        screen.pick(NWCanvasPick(board: "A.dc.html", point: CGPoint(x: 10, y: 10)))
        #expect(screen.picks == [.init(board: Self.path("A.dc.html"))], "without a board to ask, a click picks the board")
        screen.pick(NWCanvasPick(board: "B.dc.html", extending: true))
        #expect(screen.selectedWhole == [Self.path("A.dc.html"), Self.path("B.dc.html")])
        #expect(screen.focusBoard == Self.path("B.dc.html"))
        screen.pick(NWCanvasPick(board: "A.dc.html", extending: true))
        #expect(screen.picks == [.init(board: Self.path("B.dc.html"))], "shift takes a selected board back out")
        screen.pick(NWCanvasPick(extending: true))
        #expect(!screen.picks.isEmpty, "shift on the empty canvas keeps the selection")
        screen.pick(NWCanvasPick())
        #expect(screen.picks.isEmpty)
    }

    // MARK: Comments

    /// Stands in for the server's comment mutations, keeping what the canvas asked.
    final class CommentHost {
        var file = DesignComments()
        var drafts: [(draft: DesignCommentDraft, base: UInt64?)] = []
        var reports: [String] = []
        var undelivered: String?
        /// Runs once a change is kept and before its answer, as the host's push can.
        var beforeAnswer: (() async -> Void)?
        /// Whether a read answers: off, the refresh after a change can't tidy what its answer did.
        var readable = true

        func actions() -> DesignCommentActions {
            DesignCommentActions(
                list: { [self] _ in
                    guard readable else { throw CancellationError() }
                    return file
                },
                add: { [self] _, draft, base in
                    drafts.append((draft, base))
                    let comment = DesignComment(number: file.nextNumber, board: draft.board, tid: draft.tid, path: draft.path,
                                                label: draft.label, target: draft.target, rect: draft.rect, text: draft.text,
                                                createdAt: Date().timeIntervalSince1970 * 1000)
                    file.comments.append(comment)
                    file.revision += 1
                    await beforeAnswer?()
                    return (comment, undelivered)
                },
                reply: { [self] _, id, text, _ in
                    let index = try #require(file.comments.firstIndex { $0.id == id })
                    file.comments[index].replies.append(DesignCommentReply(author: .user, text: text, createdAt: 0))
                    file.revision += 1
                    await beforeAnswer?()
                    return (file.comments[index], nil)
                },
                resolve: { [self] _, id, _ in
                    let index = try #require(file.comments.firstIndex { $0.id == id })
                    file.comments[index].resolvedAt = 1
                    file.revision += 1
                    await beforeAnswer?()
                    return file.comments[index]
                },
                report: { [self] in reports.append($0) })
        }
    }

    private func commentScreen(_ host: CommentHost) async throws -> DesignScreenModel {
        let index = try Self.index()
        let snapshot = DesignSnapshot(designID: DesignID(), revision: 1, index: index,
                                      boards: Dictionary(uniqueKeysWithValues: index.boards.keys.map { ($0, "sha") }))
        let screen = DesignScreenModel(designID: snapshot.designID, host: nil, snapshot: { _ in snapshot }, source: { _, _ in "" },
                                       comments: host.actions())
        await screen.refresh()
        return screen
    }

    /// Comment on an element: it takes the selection ring and the next pin, the editor opens
    /// under it, and keeping the words sends the element as the board reported it; the thread
    /// opens once the host kept it, and the chat has its card.
    @Test func theCommentToolPinsANewCommentAndOpensItsThread() async throws {
        let host = CommentHost()
        host.undelivered = "The design agent is starting."
        let screen = try await commentScreen(host)
        var element = Self.element("A.dc.html", 12, [1, 0, 2], label: "Checkout funnel 48,210")
        element.words = "Checkout funnel"
        screen.tool = .comment
        screen.beginComment(on: element)
        #expect(screen.picks == [.init(board: Self.path("A.dc.html"), element: element)])
        #expect(screen.pins.map(\.id) == [DesignScreenModel.draftPin] && screen.pins.first?.number == 1)
        #expect(screen.popoverAnchor?.rect == element.rect && screen.popoverAnchor?.board == "A.dc.html")

        screen.draftText = "  Show the absolute counts.  "
        await screen.submitComment()?.value
        let sent = try #require(host.drafts.first)
        #expect(sent.draft.text == "Show the absolute counts." && sent.draft.tid == 12 && sent.draft.path == [1, 0, 2])
        #expect(sent.draft.target == "Checkout funnel" && sent.draft.rect == DesignCommentRect(x: 40, y: 280, w: 640, h: 216))
        #expect(sent.base == 0)
        let comment = try #require(host.file.comments.first)
        #expect(screen.draftElement == nil && screen.openComment == comment.id)
        #expect(screen.pins.map(\.id) == [comment.id.uuidString] && screen.pins.first?.rect == element.rect)
        #expect(screen.commentCards.cards[comment.id]?.target == "A · Checkout funnel")
        #expect(screen.commentCards.cards[comment.id]?.meta == "You · now")
        #expect(host.reports == ["The comment is saved, but it didn't reach the design agent: The design agent is starting."])
    }

    @Test func anEmptyCommentIsNoComment() async throws {
        let host = CommentHost()
        let screen = try await commentScreen(host)
        screen.beginComment(on: Self.element("A.dc.html", 12, [1, 0, 2]))
        screen.draftText = " \n "
        #expect(screen.submitComment() == nil)
        #expect(host.drafts.isEmpty && screen.draftElement == nil && screen.pins.isEmpty)
    }

    /// Select or Comment, a click elsewhere closes what is open beside a pin; a comment tool click
    /// that names no element starts none.
    @Test func aClickClosesTheOpenThreadAndCommentingNeedsAnElement() async throws {
        let host = CommentHost()
        host.file = DesignComments(revision: 3, comments: [
            DesignComment(number: 1, board: Self.path("A.dc.html"), tid: 12, path: [1, 0, 2], text: "Hi", createdAt: 0),
        ])
        let screen = try await commentScreen(host)
        let id = try #require(host.file.comments.first?.id)
        screen.openThread(id.uuidString)
        #expect(screen.openComment == id && screen.popoverAnchor?.id == id.uuidString)
        screen.tool = .comment
        screen.pick(NWCanvasPick(board: "A.dc.html", point: CGPoint(x: 10, y: 10)))
        #expect(screen.openComment == nil && screen.draftElement == nil, "without a board to ask, nothing is named")
        screen.openThread("draft")
        #expect(screen.openComment == nil)
    }

    /// Resolve takes a comment's pin, thread and card off the canvas and the Comments tab; the
    /// chat keeps its card.
    @Test func aResolvedCommentLeavesTheCanvasAndTheCommentsTab() async throws {
        let host = CommentHost()
        let a = Self.path("A.dc.html")
        host.file = DesignComments(revision: 2, comments: [
            DesignComment(number: 1, board: a, tid: 12, path: [1, 0, 2], rect: DesignCommentRect(x: 1, y: 2, w: 3, h: 4), text: "One", createdAt: 0),
            DesignComment(number: 2, board: Self.path("Gone.dc.html"), tid: 1, path: [0], text: "On a board the canvas lost", createdAt: 0),
        ])
        let screen = try await commentScreen(host)
        let first = host.file.comments[0].id
        #expect(screen.pins.map(\.number) == [1], "a comment on a board the canvas doesn't hold has no pin")
        #expect(screen.pins.first?.rect == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(screen.openCards.map(\.number) == [1, 2])
        screen.openThread(first.uuidString)
        await screen.resolve(first)?.value
        #expect(screen.openComment == nil && screen.pins.isEmpty)
        #expect(screen.openCards.map(\.number) == [2])
        #expect(screen.commentCards.cards[first] != nil, "the chat keeps the card")
    }

    @Test func aReplyGoesUnderTheOpenThread() async throws {
        let host = CommentHost()
        host.file = DesignComments(revision: 1, comments: [
            DesignComment(number: 1, board: Self.path("A.dc.html"), tid: 12, path: [1, 0, 2], text: "Hi", createdAt: 0),
        ])
        let screen = try await commentScreen(host)
        let id = host.file.comments[0].id
        #expect(screen.sendReply() == nil, "nothing open, nothing sent")
        screen.openThread(id.uuidString)
        screen.replyText = "And on the phone."
        await screen.sendReply()?.value
        #expect(screen.openThread?.replies.map(\.text) == ["And on the phone."] && screen.replyText.isEmpty)
    }

    /// The host pushes its revision before the agent has the comment, so the canvas can read the
    /// comment before `add` answers (Shepherd Nightly 132 trapped building the cards).
    @Test func aCommentThePushBroughtFirstIsKeptOnce() async throws {
        let host = CommentHost()
        let screen = try await commentScreen(host)
        host.beforeAnswer = {
            await screen.refreshComments()
            host.readable = false
        }
        let element = Self.element("A.dc.html", 12, [1, 0, 2])
        screen.beginComment(on: element)
        screen.draftText = "Show the absolute counts."
        await screen.submitComment()?.value
        let comment = try #require(host.file.comments.first)
        #expect(screen.comments.map(\.id) == [comment.id])
        #expect(screen.openCards.map(\.id) == [comment.id] && screen.pins.map(\.id) == [comment.id.uuidString])
        #expect(screen.openComment == comment.id && screen.draftElement == nil)
        #expect(host.reports.isEmpty)
    }

    /// A reply or a resolve the push brought before the answer leaves one copy of the comment.
    @Test(arguments: [false, true])
    func aChangeThePushBroughtFirstLeavesOneCopy(resolving: Bool) async throws {
        let host = CommentHost()
        host.file = DesignComments(revision: 1, comments: [
            DesignComment(number: 1, board: Self.path("A.dc.html"), tid: 12, path: [1, 0, 2], text: "Hi", createdAt: 0),
        ])
        let screen = try await commentScreen(host)
        let id = host.file.comments[0].id
        host.beforeAnswer = {
            await screen.refreshComments()
            host.readable = false
        }
        screen.openThread(id.uuidString)
        if resolving {
            await screen.resolve(id)?.value
            #expect(screen.comments.map(\.id) == [id] && screen.openCards.isEmpty)
        } else {
            screen.replyText = "And on the phone."
            await screen.sendReply()?.value
            #expect(screen.comments.map(\.id) == [id])
            #expect(screen.openThread?.replies.map(\.text) == ["And on the phone."])
        }
    }

    /// An answer for a comment no read has brought yet joins the list rather than going missing.
    @Test func anAnsweredCommentTheCanvasDidNotHoldJoinsIt() async throws {
        let host = CommentHost()
        let comment = DesignComment(number: 1, board: Self.path("A.dc.html"), tid: 12, path: [1, 0, 2], text: "Hi", createdAt: 0)
        host.file = DesignComments(revision: 1, comments: [comment])
        let actions = host.actions()
        var reachable = false
        // Reads fail until the answer is in.
        let gated = DesignCommentActions(
            list: { id in
                guard reachable else { throw CancellationError() }
                return try await actions.list(id)
            },
            add: actions.add, reply: actions.reply, resolve: actions.resolve, report: actions.report)
        let screen = DesignScreenModel(designID: DesignID(), host: nil, snapshot: { _ in throw CancellationError() },
                                       source: { _, _ in "" }, comments: gated)
        await screen.resolve(comment.id)?.value
        #expect(screen.comments.map(\.id) == [comment.id] && screen.comments.first?.isOpen == false)
        reachable = true
        await screen.refreshComments()
        #expect(screen.comments.map(\.id) == [comment.id])
    }

    /// A list holding a comment twice (a hand-edited comments.json) draws it once, as its later
    /// copy says, where it first appears.
    @Test func aServedListWithARepeatedCommentDrawsItOnce() async throws {
        let host = CommentHost()
        let a = Self.path("A.dc.html")
        let first = DesignComment(number: 1, board: a, tid: 12, path: [1, 0, 2], text: "Old words", createdAt: 0)
        var again = first
        again.text = "New words"
        let second = DesignComment(number: 2, board: a, tid: 3, path: [0], text: "Two", createdAt: 0)
        host.file = DesignComments(revision: 4, comments: [first, second, again])
        let screen = try await commentScreen(host)
        #expect(screen.comments.map(\.id) == [first.id, second.id])
        #expect(screen.comments.first?.text == "New words")
        #expect(screen.openCards.map(\.text) == ["New words", "Two"])
        #expect(screen.pins.map(\.number) == [1, 2])
    }

    @Test func cardsForARepeatedCommentKeepItsLaterCopy() {
        let first = DesignComment(number: 1, board: Self.path("A.dc.html"), tid: 12, path: [1, 0, 2], text: "Old", createdAt: 0)
        var later = first
        later.text = "New"
        let cards = DesignScreenModel.cards([first, later], now: Date(timeIntervalSince1970: 0))
        #expect(cards.count == 1 && cards[first.id]?.text == "New")
    }

    @Test(arguments: [
        ("A-phone.dc.html", "Checkout funnel" as String?, false, "A · phone · Checkout funnel", "You · 2m"),
        ("flows/Cart.dc.html", nil, true, "Cart", "You · 2m · element changed"),
    ])
    func aCommentsCardNamesItsBoardAndElement(board: String, target: String?, detached: Bool, on: String, meta: String) {
        let now = Date(timeIntervalSince1970: 1_000)
        let comment = DesignComment(number: 3, board: Self.path(board), tid: 1, path: [0], target: target, text: "Bigger",
                                    createdAt: (1_000 - 150) * 1000, detached: detached)
        let card = DesignScreenModel.card(comment, now: now)
        #expect(card.number == 3 && card.target == on && card.meta == meta && card.text == "Bigger")
    }

    // MARK: The sidebar

    private func sidebar(designs: Bool) -> (SidebarSource, Agent, Design) {
        var drawer = Fixture.agent("Checkout funnel dashboard", in: Self.web).agent
        let design = Design(name: "Checkout funnel dashboard", spaceID: Self.web.id, agentID: drawer.id, createdAt: 1_000,
                            lastActiveAt: 55, boardCount: 4)
        drawer.designID = design.id
        drawer.lastActiveAt = 60
        var others: [Agent] = []
        for index in 0..<10 {
            var agent = Fixture.agent("thread \(index)", in: Self.web).agent
            agent.lastActiveAt = Double(100 - index * 10)
            others.append(agent)
        }
        let state = ShepherdState(spaces: [Self.web], agents: [drawer] + others, designs: [design])
        return (SidebarSource(local: state, designs: designs), drawer, design)
    }

    @Test func aDesignIsARecentsRowWithTheNibAndItsBoardCountAndItsAgentIsNot() {
        let (source, drawer, design) = sidebar(designs: true)
        let lists = SidebarDerivation.lists(source)
        let row = try? #require(lists.recents.first { $0.id == .design(design.id) })
        #expect(row?.leading == .glyph("pencil.tip", attention: false))
        #expect(row?.accessory == .text("4 boards"))
        #expect(row?.accessibilityLabel == "Checkout funnel dashboard, design, 4 boards")
        #expect(!lists.all.contains { $0.id == .local(drawer.id) })
        // By the design's own last change, among the threads.
        #expect(lists.recents.firstIndex { $0.id == .design(design.id) } == 5)
    }

    @Test func withTheToolOffDesignsHaveNoRowsAndTheirAgentsStillDont() {
        let (source, drawer, _) = sidebar(designs: false)
        let lists = SidebarDerivation.lists(source)
        #expect(!lists.all.contains { if case .design = $0.id { true } else { false } })
        #expect(!lists.all.contains { $0.id == .local(drawer.id) })
        #expect(lists.recents.count == 10)
    }

    @Test func designsTakeNoDigit() {
        let (source, _, design) = sidebar(designs: true)
        let lists = SidebarDerivation.lists(source)
        #expect(lists.shortcutRows.count == 10)
        #expect(!lists.shortcutRows.contains { $0.id == .design(design.id) })
        let presented = lists.presented(selected: .design(design.id), shortcuts: true)
        let designRow = presented.recents.first { $0.id == .design(design.id) }
        #expect(designRow?.selected == true)
        #expect(designRow?.accessory == .text("4 boards"))
        #expect(presented.recents.compactMap { if case .shortcut(let key) = $0.accessory { key } else { nil } }
                == (1...9).map { "⌘\($0)" })
    }

    @Test func theDesignsDestinationSitsBetweenNewThreadAndAutomationsWhileTheToolIsOn() {
        let off = SidebarDerivation.destinations(shown: nil, moreOpen: false, offlineHosts: 0, newThreadChord: "⌘N")
        #expect(off.map(\.title) == ["New thread", "Automations", "More"])
        for shown in [MainDestination.designs, .newDesign] {
            let on = SidebarDerivation.destinations(shown: shown, moreOpen: false, offlineHosts: 0, newThreadChord: "⌘N", designs: true)
            #expect(on.map(\.title) == ["New thread", "Designs", "Automations", "More"])
            #expect(on[1].icon == .symbol("pencil.tip"))
            #expect(on.map(\.selected) == [false, true, false, false])
        }
    }

    // MARK: The experiment

    @Test func theDesignToolIsOffUntilTurnedOnAndAResetTurnsItOff() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        #expect(!settings.designToolEnabled)
        settings.designToolEnabled = true
        #expect(AppSettings(store: defaults).designToolEnabled)
        settings.resetToDefaults()
        #expect(!settings.designToolEnabled)
        #expect(!AppSettings(store: defaults).designToolEnabled)
    }
}
