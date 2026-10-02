import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// Deleting and importing designs as values (DesignLifecycleStates): each menu's items where it
/// opens, what each dialog and toast says, the importing card, and Remove from Recents.
@Suite("Design lifecycle words")
@MainActor
struct DesignLifecycleWordsTests {
    // MARK: Menus

    @Test(arguments: [
        (DesignMenuContext.card, [DesignMenuAction.open, .rename, .duplicate, .export]),
        (.recents, [.open, .rename, .duplicate, .export, .removeFromRecents]),
        (.toolbar, [.rename, .duplicate, .export, .showSystem]),
    ])
    func eachPlaceHasItsItemsThenDelete(_ context: DesignMenuContext, _ main: [DesignMenuAction]) {
        let menu = DesignMenu.design(context, hasSystem: true)
        #expect(menu.sections.count == 2)
        #expect(menu.sections[0].map(\.action) == main)
        #expect(menu.sections[1].map(\.action) == [.delete])
        #expect(menu.sections[1][0].destructive && menu.sections[1][0].title == "Delete Design…")
        #expect(menu.items.filter(\.destructive).count == 1, "Delete is the only red thing")
    }

    @Test func aDesignDrawnInNoSystemHasNoShowDesignSystem() {
        #expect(!DesignMenu.design(.toolbar, hasSystem: false).items.contains { $0.action == .showSystem })
    }

    /// A host's design: what the host does for this Mac, Delete off with why when it can't.
    @Test func aHostsDesignOffersWhatItsHostDoes() {
        let deletes = DesignMenu.design(.card, hasSystem: true, remote: "build-01", hostDeletes: true)
        #expect(deletes.items.map(\.action) == [.open, .rename, .delete])
        #expect(deletes.items.last?.enabled == true)
        let older = DesignMenu.design(.card, hasSystem: true, remote: "build-01", hostDeletes: false)
        let delete = try? #require(older.items.last)
        #expect(delete?.enabled == false && delete?.destructive == false)
        #expect(delete?.disabledReason?.hasPrefix("build-01 doesn’t delete designs") == true)
    }

    @Test func aSystemsMenuFollowsWhatItIs() {
        #expect(DesignMenu.system(name: "acme-web", builtIn: false, repo: "dashboard-web", building: false).sections.map { $0.map(\.title) }
            == [["Open", "Re-sync from dashboard-web", "Rename…", "Duplicate"], ["Delete Design System…"]])
        #expect(DesignMenu.system(name: "Checkout DS", builtIn: false, repo: nil, building: false).items.map(\.action)
            == [.open, .rename, .duplicateSystem, .deleteSystem])
        #expect(DesignMenu.system(name: "acme-mobile", builtIn: false, repo: "mobile-app", building: true).items.map(\.action)
            == [.open, .deleteSystem])
        let builtIn = DesignMenu.system(name: "Night Watch", builtIn: true, repo: nil, building: false)
        #expect(builtIn.items.map(\.title) == ["Open", "Duplicate as a New System", "Delete Design System…"])
        let delete = builtIn.items.last
        #expect(delete?.enabled == false, "Delete stays in the menu, off")
        #expect(delete?.disabledReason == "Night Watch is built into Shepherd. Duplicate it to make one you can change or delete.")
    }

    // MARK: Delete design

    @Test func theDeleteDialogSaysWhatGoesAndWhatStays() {
        let words = DeleteDesignWords(name: "Checkout funnel dashboard", boards: 4, versions: 23, comments: 2, system: "acme-web",
                                      agentWorking: false, drawing: 0)
        #expect(words.title == "Delete “Checkout funnel dashboard”?")
        #expect(words.lines.map(\.role) == [.goes, .goes, .stays])
        #expect(words.lines.map(\.symbol) == ["trash", "text.bubble", "checkmark"], "the boards, the chat, what stays")
        #expect(words.lines[0].lead == "4 boards" && words.lines[0].text == ", their 23 versions and 2 comments")
        #expect(words.lines[1].text == "The design agent’s chat for this design")
        #expect(words.lines[2].mono == "acme-web" && words.lines[2].tail == ", the design system it uses")
        #expect(words.note == "You can undo right after.")
        #expect(words.warning == nil && words.confirm == "Delete")
    }

    @Test func whileTheAgentDrawsTheDialogWarnsAndStopsIt() {
        let words = DeleteDesignWords(name: "Checkout funnel dashboard", boards: 4, versions: 23, comments: 2, system: nil,
                                      agentWorking: true, drawing: 2)
        #expect(words.warning == "The design agent is drawing 2 boards right now. Deleting stops it, and what it’s drawing is lost.")
        #expect(words.confirm == "Stop and delete")
        #expect(words.lines.count == 2, "a design drawn in no system names none")
        #expect(DeleteDesignWords(name: "x", boards: 1, versions: nil, comments: nil, system: nil, agentWorking: true, drawing: 0).warning
            == "The design agent is drawing right now. Deleting stops it, and what it’s drawing is lost.")
    }

    @Test(arguments: [
        (4, 23 as Int?, 2 as Int?, ", their 23 versions and 2 comments"),
        (4, 23, 0, " and their 23 versions"),
        (4, nil, 1, " and 1 comment"),
        (1, 1, nil, " and its 1 version"),
        (3, 0, 0, ""),
    ])
    func whatFollowsTheBoardsCountsWhatThereIs(_ boards: Int, _ versions: Int?, _ comments: Int?, _ text: String) {
        #expect(DeleteDesignWords.after(boards: boards, versions: versions, comments: comments) == text)
    }

    /// "Drawing 2 boards": the distinct boards the agent writes in the turn it is on, since the
    /// viewer's last message.
    @Test func theBoardsBeingDrawnAreThoseOfTheTurnUnderWay() {
        func write(_ path: String, _ id: String, tool: String = "board_write") -> NativeThreadMessage {
            NativeThreadMessage(entryID: id, role: "toolResult", blocks: [], toolName: tool, argumentsText: #"{"path":"\#(path)"}"#)
        }
        let messages = [write("A.dc.html", "1"), NativeThreadMessage(entryID: "u", role: "user", blocks: []),
                        write("B.dc.html", "2"), write("C.dc.html", "3", tool: "board_edit"), write("B.dc.html", "4", tool: "board_edit"),
                        NativeThreadMessage(entryID: "r", role: "toolResult", blocks: [], toolName: "design_read", argumentsText: "{}")]
        #expect(designBoardsDrawing(messages) == 2)
        #expect(designBoardsDrawing([]) == 0)
    }

    @Test func aBatchEditAndAnExtractionCountTheBoardsTheyNameAndAPieceIsOneToo() {
        func call(_ tool: String, _ args: String, _ id: String) -> NativeThreadMessage {
            NativeThreadMessage(entryID: id, role: "toolResult", blocks: [], toolName: tool, argumentsText: args)
        }
        let messages = [
            call("boards_edit", #"{"paths":["A.dc.html","B.dc.html"],"boards":[{"path":"C.dc.html","edits":[]}]}"#, "1"),
            call("board_extract", #"{"path":"A.dc.html","element":"A.dc.html#1:0","piece":"TopBar.dc.html"}"#, "2"),
            call("board_search", #"{"text":"x"}"#, "3"),
        ]
        #expect(designBoardsDrawing(messages) == 4)
    }

    // MARK: Delete design system

    @Test func theSystemDialogAnswersWhatBreaks() {
        let words = DeleteSystemWords(name: "acme-web", components: 9,
                                      usedBy: ["Checkout funnel dashboard", "Events explorer", "Onboarding flow"],
                                      repo: "dashboard-web", building: false)
        #expect(words.title == "Delete the design system “acme-web”?")
        #expect(words.message == "Its colors, type, spacing and 9 components go from Shepherd.")
        #expect(words.lines[0].lead == "Used by 3 designs; they keep their copy.")
        #expect(words.lines[0].text == " Checkout funnel dashboard, Events explorer, Onboarding flow")
        #expect(words.lines[1].text == "Built from " && words.lines[1].mono == "dashboard-web" && words.lines[1].tail == ". The repo isn’t touched.")
        #expect(words.lines[2].role == .note && words.lines[2].text == "New designs can’t pick it. Build it again from the repo any time.")
        #expect(words.confirm == "Delete")
    }

    @Test func aSystemStillBuildingStopsItsBuild() {
        let words = DeleteSystemWords(name: "acme-mobile", components: 0, usedBy: [], repo: "mobile-app", building: true)
        #expect(words.title == "Delete “acme-mobile”?")
        #expect(words.message == "It’s still being built from " && words.messageMono == "mobile-app"
            && words.messageTail == ". Deleting stops the build and keeps nothing from it.")
        #expect(words.lines.map(\.text) == ["No designs use it yet", "The repo "])
        #expect(words.confirm == "Stop and delete")
    }

    // MARK: The toast

    @Test func theToastSaysWhatHappenedAndOffersTheWayBack() {
        let deleted = DesignToast(kind: .deleted(DesignDeletion(designID: DesignID(), name: "Checkout funnel dashboard", undoUntil: 0),
                                                 host: nil), name: "Checkout funnel dashboard")
        #expect(!deleted.isFailure && deleted.actionTitle == "Undo")
        #expect(deleted.words.before == "Deleted " && deleted.words.after == ".")
        let reason = DesignToast.remoteReason(host: "build-01", error: RemoteHostClientError.outcomeUnknown(message: "timed out"))
        #expect(reason == "build-01, where it’s saved, didn’t answer, so it’s back.")
        let failed = DesignToast(kind: .designFailed(DesignID(), host: UUID()), name: "Checkout funnel dashboard", reason: reason)
        #expect(failed.isFailure && failed.actionTitle == "Try again")
        #expect(failed.words.before + failed.name + failed.words.after
            == "Couldn’t delete Checkout funnel dashboard. build-01, where it’s saved, didn’t answer, so it’s back.")
    }

    // MARK: Import

    private static let preview = DesignImportPreview(file: "checkout-funnel.zip", title: "Checkout funnel", boards: 12, pages: 3,
                                                     systems: [.init(namespace: "checkout-ds", title: "Checkout DS", existing: "checkout-ds")],
                                                     origin: DesignImportOrigin(file: "checkout-funnel.zip", title: "Checkout funnel",
                                                                                stamp: nil, importedAt: 0))

    @Test func importingAgainNamesTheCopyAndTheOneThere() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let imported = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let existing = Design(name: "Checkout funnel", createdAt: 1,
                              importedFrom: DesignImportOrigin(file: "checkout-funnel.zip", title: "Checkout funnel", stamp: nil,
                                                               importedAt: imported.timeIntervalSince1970 * 1000))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 26)))
        let words = ImportAgainWords(preview: Self.preview, existing: existing, copyName: "Checkout funnel 2", now: now, calendar: calendar)
        #expect(words.title == "“Checkout funnel” is already in Designs")
        #expect("You imported \(words.name)\(words.messageAfter)"
            == "You imported Checkout funnel on Sep 20. Import it again as a separate copy, or open the one you have. The two don’t affect each other.")
        #expect(words.copyName + words.copyRest == "Checkout funnel 2 · 12 boards · 3 pages")
        #expect((words.systemBefore ?? "") + (words.system ?? "") + (words.systemAfter ?? "")
            == "Design system: uses the Checkout DS you already have")
    }

    @Test func theImportingCardFollowsTheBoardsAsTheyLand() {
        var importing = DesignImporting(file: "checkout-funnel.zip")
        #expect(importing.shownTitle == "checkout-funnel")
        importing.apply(.boards(done: 7, of: 12, title: "Checkout funnel", system: "Checkout DS"))
        #expect(importing == DesignImporting(file: "checkout-funnel.zip", title: "Checkout funnel", done: 7, total: 12, system: "Checkout DS"))
        #expect(importing.shownTitle == "Checkout funnel")
    }

    /// The importing card goes first among Recent designs, and its system comes dashed after
    /// every system there is.
    @Test func anImportRunningGoesFirstWithItsSystemComing() {
        let design = Design(name: "Onboarding", createdAt: 1)
        let importing = DesignImporting(file: "checkout-funnel.zip", title: "Checkout funnel", done: 7, total: 12, system: "Checkout DS")
        let systems = [DesignSystemSummary(info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", createdAt: 1)),
                       DesignSystemSummary(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", createdAt: 0), builtIn: true)]
        let model = DesignsPageModel.make(designs: [design], spaces: [], firstBoards: [:], filter: "", selection: nil, now: Date(),
                                          systems: systems, importing: importing)
        #expect(model.rows.first?.map(\.id) == ["importing", design.id.rawValue])
        #expect(model.systems.map(\.name) == ["acme-web", "Night Watch", "Checkout DS"])
        let coming = model.systems.first { $0.dashed }
        #expect(coming?.name == "Checkout DS" && coming?.source == "came with Checkout funnel" && coming?.count == "after the boards")
        #expect(coming?.menu == nil)
    }

    /// A built-in says so; a system an import brought names its design.
    @Test func systemCardsSayWhereTheyCameFrom() {
        let design = Design(name: "Checkout funnel", createdAt: 1)
        let systems = [
            DesignSystemSummary(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", createdAt: 0), builtIn: true),
            DesignSystemSummary(info: DesignSystemInfo(namespace: "checkout-ds", title: "Checkout DS", createdAt: 1, cameWith: design.id)),
        ]
        let model = DesignsPageModel.make(designs: [design], spaces: [], firstBoards: [:], filter: "", selection: nil, now: Date(),
                                          systems: systems)
        let checkout = model.systems.first { $0.name == "Checkout DS" }
        #expect(checkout?.source == "came with Checkout funnel" && checkout?.tag == nil)
        let nightWatch = model.systems.first { $0.name == "Night Watch" }
        #expect(nightWatch?.tag == "Built-in")
        #expect(nightWatch?.menu?.items.last?.enabled == false)
    }

    @Test(arguments: [("checkout-funnel.zip", true), ("Checkout.ZIP", true), ("notes.txt", false), ("board.png", false)])
    func onlyAZipOrAFolderImports(_ name: String, _ accepted: Bool) {
        #expect(DesignImportSource.accepts(URL(fileURLWithPath: "/nowhere/\(name)")) == accepted)
    }

    // MARK: Remove from Recents

    @Test func aDesignRemovedFromRecentsHasNoRowUntilItChanges() {
        let space = Space(name: "web", path: "/tmp/web")
        let hidden = Design(name: "Checkout", createdAt: 1, lastActiveAt: 50, recentsHiddenAt: 60)
        let changed = Design(name: "Onboarding", createdAt: 1, lastActiveAt: 70, recentsHiddenAt: 60)
        let lists = SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space], designs: [hidden, changed]), designs: true))
        #expect(lists.designs.map(\.id) == [.design(changed.id)])
    }
}
