import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Design references in a thread (DesignRefStates): the composer's @ mention and its picker, a
/// pasted reference becoming a chip, the chip's words, and the "Looked at…" line's rows.
@Suite("Design references in a thread")
@MainActor
struct DesignReferenceThreadTests {
    static let checkout = DesignID(rawValue: "checkout")
    static let events = DesignID(rawValue: "events")
    static let a = DesignPath("A.dc.html")!
    static let card = DesignElementID(board: "A.dc.html", tid: 7, path: [1, 1, 0])!

    static var catalog: DesignMentionCatalog {
        let checkout = DesignMentionItem(kind: .design, reference: DesignReference(designID: checkout, board: nil)!,
                                         title: "Checkout funnel dashboard", breadcrumb: [], system: "acme-web", boardCount: 2, activeAt: 1_000)
        let events = DesignMentionItem(kind: .design, reference: DesignReference(designID: events, board: nil)!,
                                       title: "Events explorer", breadcrumb: [], boardCount: 1, activeAt: 500)
        let a = DesignMentionItem(kind: .board, reference: DesignReference(designID: Self.checkout, board: Self.a)!, title: "A · Funnel first",
                                  breadcrumb: ["Checkout funnel dashboard"], width: 1280, height: 800, elementCount: 1)
        let b = DesignMentionItem(kind: .board, reference: DesignReference(designID: Self.checkout, board: DesignPath("B.dc.html")!)!,
                                  title: "B · Step table", breadcrumb: ["Checkout funnel dashboard"], width: 1280, height: 800, elementCount: 0)
        let card = DesignMentionItem(kind: .element, reference: DesignReference(designID: Self.checkout, board: Self.a, element: Self.card)!,
                                     title: "card “Checkout funnel”", breadcrumb: ["Checkout funnel dashboard", "A · Funnel first"],
                                     tag: "div", inside: 12, detail: "funnel bars · 5 steps")
        return DesignMentionCatalog(designs: [checkout, events], boards: [Self.checkout: [a, b]], elements: [a.id: [card]])
    }

    @Test func hidingAMountedPickerReleasesPictureDemandAndRestoresOnlyItsVisibleRows() throws {
        var requests: [(String, Bool, String)] = []
        let chips = DesignReferenceChips(agentID: AgentID(), io: .init(rowVisibility: { requests.append(($0.id, $1, $2)) }))
        let row = try #require(Self.catalog.designs.first)
        chips.rowAppeared(row, rowID: row.id)
        chips.setPictureDemandActive(false)
        chips.setPictureDemandActive(true)
        chips.rowDisappeared(row.id)
        chips.setPictureDemandActive(false)
        chips.setPictureDemandActive(true)
        #expect(requests.map(\.1) == [true, false, true, false])
        #expect(Set(requests.map(\.2)).count == 1, "One picker owns its own demand")
        #expect(requests.allSatisfy { $0.0 == row.id })
    }

    @Test(arguments: [false, true])
    func wholeRowsReleaseTheirActualDisplayedIdentity(board: Bool) throws {
        let catalog = Self.catalog
        let scope: MentionScope = board
            ? .board(try #require(catalog.boards[Self.checkout]?.first?.reference), design: "Checkout", board: "A")
            : .design(Self.checkout, name: "Checkout")
        let content = MentionPickerContent.make(catalog: catalog, scope: scope, filter: "")
        let row = try #require(content.rows.first)
        let item = try #require(content.items[row.id])
        #expect(row.id == MentionPickerContent.wholeID(item))
        var active: Set<String> = []
        let io = DesignReferenceChips.IO(rowVisibility: { _, shown, consumer in
            if shown { active.insert(consumer) } else { active.remove(consumer) }
        })
        let chips = DesignReferenceChips(agentID: AgentID(), io: io)
        let other = DesignReferenceChips(agentID: AgentID(), io: io)
        chips.rowAppeared(item, rowID: row.id)
        chips.rowAppeared(item, rowID: item.id)
        other.rowAppeared(item, rowID: row.id)
        #expect(active.count == 3, "Aliases and separate pickers own distinct demands")
        chips.rowDisappeared(row.id)
        #expect(active.count == 2)
        chips.releasePictureDemand()
        #expect(active.count == 1, "Picker teardown cannot release another picker's demand")
        chips.setPictureDemandActive(false)
        chips.setPictureDemandActive(true)
        #expect(active.count == 1, "A released whole row cannot be restored by switching agents")
        other.rowDisappeared(row.id)
        #expect(active.isEmpty)
    }

    // MARK: The mention

    @Test(arguments: [
        ("Match the funnel in @", "Match the funnel in ", ""),
        ("@", "", ""),
        ("@funnel", "", "funnel"),
        ("see\n@Checkout funnel dashboard › ", "see\n", "Checkout funnel dashboard › "),
    ])
    func aDraftEndingInAnAtMentionOpensIt(draft: String, before: String, text: String) throws {
        let mention = try #require(ComposerMention.token(in: draft))
        #expect(mention.before == before && mention.text == text)
    }

    @Test(arguments: ["mail me at baily@example.com", "@funnel\nand more", "plain words", "@ spaced", "@ ", "see @\u{00A0}", "@\tx"])
    func anAddressALineBreakOrNoAtIsNoMention(draft: String) {
        #expect(ComposerMention.token(in: draft) == nil)
    }

    /// The rule the walk back replaced, word for word: the last "@" anywhere in the draft.
    private static func wholeDraftMention(in draft: String) -> (before: String, text: String)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let text = draft[draft.index(after: at)...]
        guard !text.contains(where: \.isNewline), text.count <= ComposerMention.maxLength,
              text.first?.isWhitespace != true else { return nil }
        return (String(draft[..<at]), String(text))
    }

    @Test func theMentionWalkFindsWhatTheWholeDraftScanFound() {
        let symbols = ["a", "/", "$", "@", " ", "\n", "é", "e\u{301}", "\r\n", "\u{00A0}", "🚀"]
        var drafts = [""], level = [""]
        for _ in 1...4 {
            level = level.flatMap { draft in symbols.map { draft + $0 } }
            drafts += level
        }
        // Past the corpus: an "@" with 159, 160 and 161 Characters after it, plain and joined
        // (a Character of two scalars, one of four bytes, one of eight), with a line break at either end or
        // in the middle, and after words.
        let limit = ComposerMention.maxLength
        for count in [limit - 1, limit, limit + 1] {
            for unit in ["x", "e\u{301}", "🚀", "🇫🇷"] {
                let run = String(repeating: unit, count: count)
                let broken = String(repeating: unit, count: count / 2) + "\n" + String(repeating: unit, count: count - count / 2 - 1)
                for text in [run, "\n" + run, run + "\n", broken, " " + run] {
                    drafts += ["@" + text, "see @" + text, "see\n@" + text, "me@" + text]
                }
            }
        }
        var differing: [String] = []
        for draft in drafts {
            let walked = ComposerMention.token(in: draft)
            let scanned = Self.wholeDraftMention(in: draft)
            if walked?.before != scanned?.before || walked?.text != scanned?.text
                || walked?.draft(with: "Z") != scanned.map({ $0.before + "@Z" }) {
                differing.append(draft)
            }
        }
        #expect(differing.isEmpty, "differs for \(differing.count), first \(differing.prefix(3).map { String(reflecting: $0.prefix(24)) })")
    }

    @Test func theWordsOfAMentionSpellItsScope() {
        let catalog = Self.catalog
        #expect(MentionScope.spelled(by: "Checkout funnel dashboard › ", in: catalog) == .design(Self.checkout, name: "Checkout funnel dashboard"))
        let board = MentionScope.spelled(by: "Checkout funnel dashboard › A · Funnel first › card", in: catalog)
        #expect(board.crumbs == ["Checkout funnel dashboard", "A · Funnel first"])
        #expect(board.filter(in: "Checkout funnel dashboard › A · Funnel first › card") == "card")
        #expect(MentionScope.spelled(by: "Nothing › ", in: catalog) == .designs)
        #expect(board.parent == .design(Self.checkout, name: "Checkout funnel dashboard"))
    }

    // MARK: The picker

    @Test func thePickerListsDesignsThenABoardsElementsAndSearchesEveryLevel() {
        let catalog = Self.catalog
        let designs = MentionPickerContent.make(catalog: catalog, scope: .designs, filter: "")
        #expect(designs.sections.map(\.title) == ["Designs"] && designs.rows.map(\.title) == ["Checkout funnel dashboard", "Events explorer"])
        #expect(designs.rows.allSatisfy { $0.trailing == .drill } && designs.sections.first?.trailing == "2 on this Mac")

        let inside = MentionPickerContent.make(catalog: catalog, scope: .design(Self.checkout, name: "Checkout funnel dashboard"), filter: "")
        #expect(inside.crumbs == ["Checkout funnel dashboard"])
        #expect(inside.rows.map(\.title) == ["Whole design", "A · Funnel first", "B · Step table"])
        #expect(inside.rows.first?.trailing == .pick && inside.rows.dropFirst().allSatisfy { $0.trailing == .drill })

        let board = MentionScope.board(DesignReference(designID: Self.checkout, board: Self.a)!, design: "Checkout funnel dashboard",
                                       board: "A · Funnel first")
        let elements = MentionPickerContent.make(catalog: catalog, scope: board, filter: "")
        #expect(elements.rows.map(\.title) == ["Whole board", "card “Checkout funnel”"])
        #expect(elements.rows.map(\.subtitle) == ["1280 × 800 · 1 element", "funnel bars · 5 steps"])
        #expect(elements.sections.map(\.title) == ["", "Elements"])
        #expect(elements.sections[1].trailing == "1", "Elements counts what Whole board says the board lists")

        let search = MentionPickerContent.make(catalog: catalog, scope: .designs, filter: "funnel")
        #expect(search.rows.map(\.title) == ["Checkout funnel dashboard", "A · Funnel first", "card “Checkout funnel”"])
        #expect(search.rows[2].crumbs == ["Checkout funnel dashboard", "A · Funnel first"] && search.rows[2].trailing == .pick)
        #expect(search.sections.first?.trailing == "3 matches" && search.rows.allSatisfy { $0.matched == ["funnel"] })
    }

    @Test func pagesHaveTheirOwnSectionAndPickAllBoardsWithoutReplacingBoardDrilling() throws {
        var catalog = Self.catalog
        let reference = try #require(DesignReference(designID: Self.checkout, board: nil, page: "funnel"))
        let page = DesignMentionItem(kind: .page, reference: reference, title: "A · Funnel first", breadcrumb: ["Checkout funnel dashboard"], boardCount: 2)
        catalog.pages[Self.checkout] = [page]
        let content = MentionPickerContent.make(catalog: catalog, scope: .design(Self.checkout, name: "Checkout funnel dashboard"), filter: "")
        #expect(content.sections.map(\.title) == ["", "Pages", "Boards"])
        let row = try #require(content.rows.first { $0.kind == .page })
        #expect(row.trailing == .pick && row.subtitle == "Page · 2 boards · attaches all boards")
        #expect(content.rows.filter { $0.kind == .board }.allSatisfy { $0.trailing == .drill })
        var picker = MentionPickerState()
        picker.update(draft: "Build @Checkout funnel dashboard › ", catalog: catalog)
        #expect(picker.choose(row) == .pick(reference, draft: "Build "))
        #expect(!picker.isOpen)
        let searched = MentionPickerContent.make(catalog: catalog, scope: .designs, filter: "first")
        #expect(searched.rows.map(\.kind) == [.page, .board], "a page and board with the same name remain distinct")
        #expect(searched.rows.map(\.trailing) == [.pick, .drill])
    }

    @Test func thePickersEmptyStagesSayWhy() {
        #expect(MentionPickerContent.make(catalog: DesignMentionCatalog(), scope: .designs, filter: "").empty == .noDesigns)
        let none = MentionPickerContent.make(catalog: Self.catalog, scope: .designs, filter: "pricng")
        #expect(none.empty == .nothingMatches(query: "pricng", searched: MentionPickerContent.searched) && none.rows.isEmpty)
    }

    /// A host thread's picker says whose designs it lists and searched.
    @Test func aHostThreadsPickerNamesTheHost() {
        let listed = MentionPickerContent.make(catalog: Self.catalog, scope: .designs, filter: "", place: "Studio")
        #expect(listed.sections.first?.trailing == "\(Self.catalog.designs.count) on Studio")
        let none = MentionPickerContent.make(catalog: Self.catalog, scope: .designs, filter: "pricng", place: "Studio")
        #expect(none.empty == .nothingMatches(query: "pricng", searched: "Searches Studio’s designs, pages, boards and elements."))
    }

    @Test func drillingWritesTheWayInAndPickingTakesTheMentionOut() throws {
        var state = MentionPickerState()
        state.update(draft: "Match the funnel in @", catalog: Self.catalog)
        #expect(state.isOpen && state.highlighted == DesignReference(designID: Self.checkout, board: nil)!.string)
        state.move(1)
        #expect(state.highlightedRow?.title == "Events explorer")
        state.move(5)
        #expect(state.highlightedRow?.title == "Events explorer", "stops at the end")
        state.move(-1)

        guard case .drill(let draft)? = state.choose(try #require(state.highlightedRow)) else { Issue.record("a design drills"); return }
        #expect(draft == "Match the funnel in @Checkout funnel dashboard › ")
        state.update(draft: draft, catalog: Self.catalog)
        let board = try #require(state.content.rows.first { $0.title == "A · Funnel first" })
        guard case .drill(let deeper)? = state.choose(board) else { Issue.record("a board drills"); return }
        state.update(draft: deeper, catalog: Self.catalog)
        #expect(state.content.crumbs == ["Checkout funnel dashboard", "A · Funnel first"] && state.filterIsEmpty)

        #expect(state.back() == "Match the funnel in @Checkout funnel dashboard › ")
        state.update(draft: deeper, catalog: Self.catalog)
        let card = try #require(state.content.rows.first { $0.title == "card “Checkout funnel”" })
        guard case .pick(let reference, let words)? = state.choose(card) else { Issue.record("an element picks"); return }
        #expect(words == "Match the funnel in " && reference.element == Self.card && reference.revision == nil)
        #expect(!state.isOpen)
    }

    @Test func escClosesThePickerForTheDraftAsTypedAndTypingOpensItAgain() {
        var state = MentionPickerState()
        state.update(draft: "@fun", catalog: Self.catalog)
        state.dismissed = "@fun"
        state.close()
        state.update(draft: "@fun", catalog: Self.catalog)
        #expect(!state.isOpen)
        state.update(draft: "@funn", catalog: Self.catalog)
        #expect(state.isOpen && state.dismissed == nil)
    }

    @Test(arguments: [(0.5, "edited 30m ago"), (30, "yesterday"), (80, "3d ago")])
    func aDesignsLineSaysWhenItWasEdited(hoursAgo: Double, words: String) throws {
        // Noon, so "yesterday" is the calendar's.
        let now = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000)))
        let active = now.timeIntervalSince1970 * 1000 - hoursAgo * 3_600_000
        #expect(MentionPickerContent.activeText(active, now: now) == words)
    }

    // MARK: Paste

    @Test func aPastedReferenceBecomesAChipAndTheWordsStay() throws {
        let reference = try #require(DesignReference(designID: Self.checkout, board: Self.a, element: Self.card, revision: 23))
        let pasted = try #require(ComposerReferencePaste.extract("Build this \(reference.string) please", previous: "Build this  please"))
        #expect(pasted.references == [reference] && pasted.draft == "Build this please")
        let wrapped = try #require(ComposerReferencePaste.extract("<\(reference.string)>", previous: ""))
        #expect(wrapped.references.map(\.string) == [reference.string] && wrapped.draft.isEmpty)
    }

    @Test func typingAndPlainTextStayText() throws {
        let reference = try #require(DesignReference(designID: Self.checkout, board: Self.a))
        #expect(ComposerReferencePaste.extract(reference.string, previous: String(reference.string.dropLast())) == nil, "one keystroke")
        #expect(ComposerReferencePaste.extract("Plain words pasted in", previous: "") == nil)
        #expect(ComposerReferencePaste.extract("shepherd-design-ref://not a ref", previous: "") == nil)
        #expect(ComposerReferencePaste.extract(reference.string + " and more", previous: reference.string) == nil,
                "a reference already in the words is left as it was")
    }

    /// A scalar of one to four bytes typed after a reference is a keystroke, however wide.
    @Test(arguments: ["é", "日", "🚀"])
    func aOneScalarKeystrokeIsNoPaste(key: String) throws {
        let reference = try #require(DesignReference(designID: Self.checkout, board: Self.a))
        #expect(ComposerReferencePaste.extract(reference.string + key, previous: reference.string) == nil)
        #expect(ComposerReferencePaste.extract(reference.string + " " + key, previous: reference.string + " ") == nil)
    }

    /// A flag or a skin tone is one Character of several scalars: eight bytes, still one keystroke.
    @Test(arguments: ["🇫🇷", "👍🏽"])
    func aMultiScalarKeystrokeStaysText(key: String) throws {
        let reference = try #require(DesignReference(designID: Self.checkout, board: Self.a))
        #expect(ComposerReferencePaste.extract(reference.string + key, previous: reference.string) == nil)
        #expect(ComposerReferencePaste.extract(reference.string + " " + key, previous: reference.string + " ") == nil)
    }

    // MARK: The chip and the agent's line

    @Test func aChipsWordsComeFromWhatTheHostKept() {
        let record = DesignReferenceRecord(ref: "x", design: "Checkout funnel dashboard", board: "A.dc.html", boardTitle: "A · Funnel first",
                                           element: Self.card.description, elementLabel: "Checkout funnel", revision: 23)
        #expect(DesignReferenceChips.crumbs(record) == ["Checkout funnel dashboard", "A · Funnel first", "“Checkout funnel”"])
        let page = DesignReferenceRecord(ref: "shepherd-design-ref://local/checkout?page=funnel@23", design: "Checkout", page: "funnel", pageTitle: "Checkout flow")
        #expect(DesignReferenceChips.crumbs(page) == ["Checkout", "Page · Checkout flow"])
        #expect(DesignReferenceChips.crumbs(label: "Checkout › A · Funnel first › button “Pay”") == ["Checkout", "A · Funnel first", "button “Pay”"])
        #expect(DesignReferenceChips.state(.current) == .current)
        #expect(DesignReferenceChips.state(.updatedSince(latest: 26, changes: [])) == .updated("updated since · now v26"))
        #expect(DesignReferenceChips.state(.deleted) == .deleted("design deleted · the copy sent here is kept"))
        #expect(DesignReferenceChips.changes(.updatedSince(latest: 26, changes: ["padding 24px → 20px"]), version: 23)
            == SHReferenceChanges(title: "Changed since v23 · now v26", lines: ["padding 24px → 20px"]))
        #expect(DesignReferenceChips.changes(.current, version: 23) == nil)
    }

    /// ThreadBoardShown and ThreadBoardStale: a board card reads the copy the agent showed, its
    /// picture at half its pixels, and says so once the design moved on; "Show v14" and "Open in
    /// design" open the board as it is now and as it was.
    @Test func aBoardCardReadsTheCopyAndSaysWhenTheDesignMovedOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("board-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 112, pixelsHigh: 82, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("A@2x.png"))
        let reference = DesignReference(designID: Self.checkout, board: Self.a, revision: 13)!
        var payload = DesignReferencePayload(agentID: AgentID(rawValue: "t"), reference: reference, design: "Checkout redesign",
                                             boardTitle: "A · Funnel first", revision: 13, capturedAt: 0, width: 560, height: 410,
                                             picture: .init(name: "A@2x.png", bytes: 1, pixelWidth: 112, pixelHeight: 82))
        payload.boardPageTitle = "Checkout"
        var freshness = DesignReferenceFreshness.current
        var opened: [DesignReference] = []
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "t"), io: DesignReferenceChips.IO(
            payload: { $0 == payload.id ? (payload, folder) : nil }, freshness: { _ in freshness }, open: { opened.append($0) }))

        await chips.loadBoard(payload.id)
        let shown = try #require(chips.boards[payload.id])
        #expect(shown.design == "Checkout redesign" && shown.board == "A · Funnel first")
        #expect(shown.meta == ["Checkout", "560 × 410", "revision 13"] && shown.note == nil && shown.showLatest == nil)
        #expect(shown.size == CGSize(width: 56, height: 41) && shown.picture != nil)

        freshness = .updatedSince(latest: 14, changes: ["padding 24px → 20px"])
        chips.designsChanged()
        await chips.loadBoard(payload.id)
        let stale = try #require(chips.boards[payload.id])
        #expect(stale.meta.last == "shown at revision 13" && stale.showLatest == "Show v14")
        #expect(stale.note == "The design moved on since the agent showed this. It shows what the agent saw.")
        chips.io.open(stale.reference.unpinned)
        chips.io.open(stale.reference)
        #expect(opened.map(\.revision) == [nil, 13])

        await chips.loadBoard(UUID())
        #expect(chips.boards.count == 1, "a copy the thread no longer has draws no card")
    }

    /// ThreadBoardDraft: a drawn board is never stale, its card offers Discard and Add to design,
    /// and settling it reads the copy again; a refusal comes back as words for the card.
    @Test func aDrawnBoardSettlesFromItsCard() async throws {
        let reference = DesignReference(designID: Self.checkout, board: DesignPath("B.dc.html")!, revision: 13)!
        var payload = DesignReferencePayload(agentID: AgentID(rawValue: "t"), reference: reference, design: "Checkout redesign",
                                             boardTitle: "B · Pay on phone", revision: 13, capturedAt: 0, width: 320, height: 480)
        payload.proposal = .init(kind: .draft)
        let kept = Locked(payload)
        var settled: [Bool] = []
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "t"), io: DesignReferenceChips.IO(
            payload: { $0 == payload.id ? (kept.current, URL(fileURLWithPath: "/nonexistent")) : nil },
            freshness: { _ in .deleted },
            settle: { _, accept in
                settled.append(accept)
                if accept { throw DesignReferenceError("board_changed", "B changed since the agent drew this.") }
                kept.withValue { $0.proposal?.state = .discarded }
            }))
        await chips.loadBoard(payload.id)
        let card = try #require(chips.boards[payload.id])
        #expect(card.proposal?.state == .pending && card.copy == payload.id && card.note?.hasPrefix("Drawn in this thread") == true)
        #expect(card.meta.last == "not on the canvas yet" && card.showLatest == nil, "a draft isn't on the canvas to be stale")
        #expect(card.lineLabel == "Drew a board" && card.lineMeta == "B · Pay on phone · draft in Checkout redesign")

        #expect(await chips.settle(payload.id, accept: true) == "B changed since the agent drew this.")
        #expect(await chips.settle(payload.id, accept: false) == nil)
        #expect(settled == [true, false] && chips.boards[payload.id]?.proposal?.state == .discarded)
    }

    /// RefAtElements: an element's row on screen asks for its own picture, with its board and the
    /// elements listed on it; a design's or a board's row asks for none.
    @Test func anElementRowOnScreenAsksForItsOwnPicture() throws {
        var asked: [(String, String, [Int])] = []
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "t"), io: DesignReferenceChips.IO(
            wantCrop: { element, board, tids in asked.append((element.id, board.id, tids)) }))
        chips.seed(catalog: Self.catalog)
        let board = try #require(Self.catalog.boards[Self.checkout]?.first)
        let card = try #require(Self.catalog.elements[board.id]?.first)
        let design = try #require(Self.catalog.designs.first)
        chips.rowAppeared(design, rowID: design.id)
        chips.rowAppeared(board, rowID: board.id)
        #expect(asked.isEmpty)
        chips.rowAppeared(card, rowID: card.id)
        #expect(asked.map(\.0) == [card.id] && asked.map(\.1) == [board.id] && asked.map(\.2) == [[7]])
    }

    /// RefPasted: ⌫ takes the last chip back with the caret at the start of the words, and
    /// deletes a character anywhere else.
    @Test(arguments: [
        ("", nil, nil, true),
        ("", 0, 0, true),
        ("Build this", 0, 0, true),
        ("Build this", 3, 3, false),
        ("Build this", 10, 10, false),
        ("Build this", 0, 5, false),
        ("Build this", nil, nil, false),
    ] as [(String, Int?, Int?, Bool)])
    func backspaceAtTheStartOfTheWordsTakesTheLastChipBack(draft: String, from: Int?, to: Int?, takesBack: Bool) {
        let selection = from.flatMap { from in
            to.map { to in
                TextSelection(range: draft.index(draft.startIndex, offsetBy: from)..<draft.index(draft.startIndex, offsetBy: to))
            }
        }
        #expect(ComposerCaret.takesBackChip(draft: draft, selection: selection) == takesBack)
    }

    @Test func aCaretTheDraftOutgrewReadsAsNone() {
        let caret = ComposerCaret()
        let long = "Build this in the checkout page"
        caret.selection = TextSelection(insertionPoint: long.endIndex)
        #expect(caret.selection(in: long) != nil)
        #expect(caret.selection(in: "Build") == nil, "a draft replaced from outside the field leaves no caret to read")
    }

    /// RefChipHover and RefChipUpdated open the preview 8pt above the chip; it opens below only
    /// when the thread's top is nearer the chip than the preview and its gap.
    @Test(arguments: [
        (CGFloat(455), CGFloat(343), true),
        (CGFloat(351), CGFloat(343), true),
        (CGFloat(350), CGFloat(343), false),
        (CGFloat(120), CGFloat(343), false),
        (CGFloat.infinity, CGFloat(251), true),
    ])
    func aSentChipsPreviewOpensAboveItWheneverItFits(room: CGFloat, previewHeight: CGFloat, above: Bool) {
        #expect(DesignReferenceChips.previewFitsAbove(room: room, previewHeight: previewHeight) == above)
    }

    @Test func aSentMessagesChipsStandForItsReferencesLine() throws {
        let record = DesignReferenceRecord(ref: "shepherd-design-ref://local/checkout/A.dc.html@3", design: "Checkout", payload: UUID().uuidString)
        let message = NativeThreadMessage(entryID: "u", role: "user",
                                          blocks: [NativeThreadBlock(kind: .text, text: "Build this.\n\n1 design reference attached.")],
                                          timestamp: 1_000, designReferences: [record])
        let turn = try #require(nativeTurns([message]).first)
        let view = UserTurn(turn: turn)
        #expect(view.bubbles.map(\.text) == ["Build this."] && view.bubbles.first?.references == [record])
    }

    @Test func theLookedAtLineOpensToWhatTheAgentGot() {
        let found = DesignReferenceLookedAt(
            ref: "r", title: "Checkout › A", aspects: [.image, .html, .element, .tokens],
            picture: .init(label: "A › card “Checkout funnel” @2x", pixelWidth: 756, pixelHeight: 612), html: .init(name: "card.html", bytes: 6_349),
            styles: .init(count: 11, names: ["padding", "gap", "border-radius", "background"]),
            tokens: .init(names: ["--accent", "--text", "--muted", "--border", "--space-4", "--space-6"], sources: ["web/static/tokens.css:4–16"]))
        let rows = LookedAtWords.rows(found)
        #expect(rows.map(\.label) == ["pic", "html", "css", "tok"])
        #expect(rows[0].trailing == "756 × 612" && rows[1].trailing == "6.3 KB")
        #expect(rows[2].detail == "11 properties · padding, gap, border-radius, background…")
        #expect(rows[3].detail == "--accent --text --muted --border +2" && rows[3].trailing == "web/static/tokens.css:4–16")
    }

    @Test(arguments: [(812, "812 B"), (6_349, "6.3 KB"), (48_200, "48 KB"), (1_400_000, "1.4 MB")])
    func aPagesWeightReadsShort(bytes: Int, words: String) {
        #expect(LookedAtWords.size(bytes) == words)
    }
}
