import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdUI
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
                                     tag: "div", inside: 12)
        return DesignMentionCatalog(designs: [checkout, events], boards: [Self.checkout: [a, b]], elements: [a.id: [card]])
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

    @Test(arguments: ["mail me at baily@example.com", "@funnel\nand more", "plain words", "@ spaced"])
    func anAddressALineBreakOrNoAtIsNoMention(draft: String) {
        #expect(ComposerMention.token(in: draft) == nil)
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
        #expect(elements.rows.map(\.subtitle) == ["1280 × 800 · 1 element", "div · 12 inside"])
        #expect(elements.sections.map(\.title) == ["", "Elements"])

        let search = MentionPickerContent.make(catalog: catalog, scope: .designs, filter: "funnel")
        #expect(search.rows.map(\.title) == ["Checkout funnel dashboard", "A · Funnel first", "card “Checkout funnel”"])
        #expect(search.rows[2].crumbs == ["Checkout funnel dashboard", "A · Funnel first"] && search.rows[2].trailing == .pick)
        #expect(search.sections.first?.trailing == "3 matches" && search.rows.allSatisfy { $0.matched == ["funnel"] })
    }

    @Test func thePickersEmptyStagesSayWhy() {
        #expect(MentionPickerContent.make(catalog: DesignMentionCatalog(), scope: .designs, filter: "").empty == .noDesigns)
        let none = MentionPickerContent.make(catalog: Self.catalog, scope: .designs, filter: "pricng")
        #expect(none.empty == .nothingMatches(query: "pricng", searched: MentionPickerContent.searched) && none.rows.isEmpty)
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

    // MARK: The chip and the agent's line

    @Test func aChipsWordsComeFromWhatTheHostKept() {
        let record = DesignReferenceRecord(ref: "x", design: "Checkout funnel dashboard", board: "A.dc.html", boardTitle: "A · Funnel first",
                                           element: Self.card.description, elementLabel: "Checkout funnel", revision: 23)
        #expect(DesignReferenceChips.crumbs(record) == ["Checkout funnel dashboard", "A · Funnel first", "“Checkout funnel”"])
        #expect(DesignReferenceChips.crumbs(label: "Checkout › A · Funnel first › button “Pay”") == ["Checkout", "A · Funnel first", "button “Pay”"])
        #expect(DesignReferenceChips.state(.current) == .current)
        #expect(DesignReferenceChips.state(.updatedSince(latest: 26, changes: [])) == .updated("updated since · now v26"))
        #expect(DesignReferenceChips.state(.deleted) == .deleted("design deleted · the copy sent here is kept"))
        #expect(DesignReferenceChips.changes(.updatedSince(latest: 26, changes: ["padding 24px → 20px"]), version: 23)
            == NWReferenceChanges(title: "Changed since v23 · now v26", lines: ["padding 24px → 20px"]))
        #expect(DesignReferenceChips.changes(.current, version: 23) == nil)
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
