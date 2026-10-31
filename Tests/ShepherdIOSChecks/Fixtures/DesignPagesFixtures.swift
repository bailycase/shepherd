import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A design with pages on every mobile screen of it: Studio's checkout design with its three wide
// boards on Desktop (a long name, to truncate), the phone board on Phone, and Archive empty. The page chosen on one screen is the page the
// others show (`HostDesignLibraries.pages`), so an iPhone Duo closed or opened keeps it.
//
//   design-pad-pages     iPad (-r landscape): the canvas's page popup by Export; Phone fitted.
//   design-pages         iPhone: the boards grid on Phone, the title's page menu.
//   design-board-pages   iPhone: a board on Phone, then Desktop chosen elsewhere moves it there;
//                        Archive (empty) shows no board, and Phone afterwards shows its board.
//   design-board-empty-page  iPhone: the board screen on Archive, its title the page menu.
//   design-boards-pages  iPhone: the Boards sheet on Phone.
//   duo-design-pages     iPhone Duo (-f closed): Phone chosen closed, kept open on the canvas,
//                        Desktop chosen there, kept closed again.
//   duo-design-pages-open  iPhone Duo (-f open): the canvas's page popup, Phone shown, then Desktop's
//                        long name truncated.
extension FixtureCatalog {
    static var designPages: [FixtureScreen] {
        let pad = DesignPadFixtures.ref
        let ref = DesignPagesFixtures.ref
        let phone = DesignPagesFixtures.phoneBoard.rawValue
        let hosts = DesignPagesFixtures.hosts()
        return [
            FixtureScreen(name: "design-pad-pages", hosts: hosts, routes: [.padDesign(.list), .padDesign(.design(pad))],
                          prepare: { app in await DesignPagesFixtures.padPages(app) }),
            FixtureScreen(name: "design-pages", hosts: hosts, routes: [.designs(.design(ref))],
                          prepare: { app in await DesignPagesFixtures.grid(app) }),
            FixtureScreen(name: "design-board-pages", hosts: hosts, routes: [.designs(.design(ref)), .designs(.board(ref, path: phone))],
                          prepare: { app in await DesignPagesFixtures.board(app) }),
            FixtureScreen(name: "design-board-empty-page", hosts: hosts,
                          routes: [.designs(.design(ref)), .designs(.board(ref, path: phone))],
                          prepare: { app in await DesignPagesFixtures.emptyPage(app) }),
            FixtureScreen(name: "duo-design-pages-open", hosts: hosts, routes: [.padDesign(.list), .padDesign(.design(pad))],
                          prepare: { app in
                              await DesignPagesFixtures.padPages(app)
                              // Back on Desktop: its long name truncates in the popup.
                              let canvas = PadDesigns.of(app.hosts).canvas(pad)
                              canvas.showPage(DesignPagesFixtures.desktop)
                              await FixtureWindows.wait("Desktop drawn", seconds: 30) { canvas.boards.count == 3 && canvas.isDrawn }
                          }),
            FixtureScreen(name: "design-boards-pages", hosts: hosts, routes: [.designs(.design(ref)), .designs(.board(ref, path: phone))],
                          presented: .designs(.boards(ref, current: phone)),
                          prepare: { _ in await DesignsFixtures.drawn(images: 1) }),
            FixtureScreen(name: "duo-design-pages", hosts: hosts, routes: [.designs(.design(ref))],
                          prepare: { app in await DesignPagesFixtures.duo(app) }),
        ]
    }
}

enum DesignPagesFixtures {
    static let ref = HostDesignRef(host: FixtureData.studio, design: DesignPadFixtures.designID)
    static let desktop = "desktop"
    static let phone = "phone"
    static let archive = "archive"
    static let desktopName = "Desktop directions for the checkout review"
    static let phoneBoard = DesignPath("A-phone.dc.html")!

    /// The iPad fixture's hosts, the checkout design's boards on two pages.
    static func hosts() -> [FixtureHostData] {
        var hosts = DesignPadFixtures.hosts()
        guard let host = hosts.firstIndex(where: { $0.id == FixtureData.studio }),
              let item = hosts[host].designs?.designs.firstIndex(where: { $0.design.id == DesignPadFixtures.designID }),
              var index = hosts[host].designs?.designs[item].index else { return hosts }
        index.pages = [.init(id: desktop, name: desktopName), .init(id: phone, name: "Phone"), .init(id: archive, name: "Archive")]
        for path in index.boards.keys { index.boards[path]?.page = path == phoneBoard ? phone : desktop }
        hosts[host].designs?.designs[item].index = index
        return hosts
    }

    @MainActor static func check(_ ok: Bool, _ what: String) {
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED"): \(what)")
    }

    /// The canvas opens on Desktop; Phone shows its one board, fitted again, and the phone's
    /// screens of the design read Phone too.
    @MainActor static func padPages(_ app: MobileApp) async {
        let canvas = PadDesigns.of(app.hosts).canvas(DesignPadFixtures.ref)
        await FixtureWindows.wait("design canvas drawn", seconds: 30) { canvas.snapshot != nil && canvas.isDrawn }
        check(canvas.page == desktop && canvas.boards.count == 3, "the canvas opens on Desktop's three boards")
        check(canvas.pageList.count == 3, "the popup lists three pages")
        let before = canvas.viewport
        // A queued hit test must not restore the old page's selection after switching pages.
        canvas.pick(SHCanvasPick(board: "A.dc.html", point: CGPoint(x: 400, y: 440)))
        canvas.showPage(phone)
        await FixtureWindows.wait("Phone drawn", seconds: 30) { canvas.visibleBoards == [phoneBoard] && canvas.isDrawn }
        check(canvas.picks.isEmpty && canvas.draftElement == nil, "switching pages discards pending picks from the old page")
        check(canvas.boards.map(\.id) == [phoneBoard.rawValue] && canvas.pageName == "Phone", "Phone shows only its board")
        check(canvas.viewport.zoom > before.zoom * 2, "Phone is fitted again (zoom \(before.zoom) → \(canvas.viewport.zoom))")
        let designs = MobileDesigns.of(app.hosts)
        _ = await designs.sync(ref)
        check(designs.page(ref) == phone, "the phone's screens of the design read Phone")
    }

    @MainActor static func grid(_ app: MobileApp) async {
        let designs = MobileDesigns.of(app.hosts)
        await DesignsFixtures.synced(app, ref)
        check(designs.page(ref) == desktop, "the design opens on Desktop")
        designs.showPage(ref, phone)
        guard let index = designs.indexes[ref]?.snapshot.index else { FixtureCheck.fail("No index") }
        check(RemoteDesignPresentation.boards(index, page: designs.page(ref)) == [phoneBoard], "Phone lists only its board")
        await DesignsFixtures.drawn(images: 1)
        check(PadDesigns.of(app.hosts).canvas(DesignPadFixtures.ref).chosenPage == phone, "the iPad's canvas reads Phone")
    }

    @MainActor static func board(_ app: MobileApp) async {
        guard let model = await DesignsFixtures.board() else { return }
        let designs = MobileDesigns.of(app.hosts)
        check(model.boards == [phoneBoard] && designs.page(ref) == phone,
              "the phone board opens its page, Phone (\(model.boards.map(\.rawValue)), \(designs.page(ref) ?? "none"))")
        // Another screen (the Boards sheet's menu, the iPad's canvas) chooses Desktop.
        designs.showPage(ref, desktop)
        await FixtureWindows.wait("Desktop's first board", seconds: 10) { model.current == DesignPath("A.dc.html") && model.live != nil }
        check(model.boards.count == 3, "the board screen steps through Desktop's three boards")
        // An empty page: no board and no dots under the page's name, then back to a page with one.
        designs.showPage(ref, archive)
        await FixtureWindows.wait("Archive shows no board", seconds: 10) { model.current == nil }
        check(model.live == nil && model.boards.isEmpty && model.pageName == "Archive", "Archive shows no board and no dots")
        designs.showPage(ref, phone)
        await FixtureWindows.wait("Phone's board again", seconds: 10) { model.current == phoneBoard && model.live != nil }
        check(model.boards == [phoneBoard], "Phone after Archive shows its board")
        // The phone board boots in this fixture (the wide boards don't in the phone's live view).
        _ = await DesignsFixtures.board()
    }

    @MainActor static func emptyPage(_ app: MobileApp) async {
        guard let model = await DesignsFixtures.board() else { return }
        MobileDesigns.of(app.hosts).showPage(ref, archive)
        await FixtureWindows.wait("Archive shows no board", seconds: 10) { model.current == nil && model.live == nil }
        check(model.boards.isEmpty, "the board screen on Archive shows no board")
    }

    /// Closed: Phone on the boards grid. Opened: the canvas shows Phone; Desktop chosen there.
    /// Closed again: the narrow canvas still shows Desktop.
    @MainActor static func duo(_ app: MobileApp) async {
        let navigator = app.navigator
        let designs = MobileDesigns.of(app.hosts)
        await DesignsFixtures.synced(app, ref)
        check(navigator.layout == .phone, "closed, the phone's layout")
        designs.showPage(ref, phone)
        pose("open")
        await FixtureCheck.wait("the inner display's layout", seconds: 20) { navigator.layout == .pad }
        check(designs.page(ref) == phone, "opened, the design still shows Phone")
        PadDesignHooks.open(DesignPadFixtures.ref, navigator: navigator)
        let canvas = PadDesigns.of(app.hosts).canvas(DesignPadFixtures.ref)
        await FixtureWindows.wait("the canvas drawn", seconds: 30) { canvas.snapshot != nil && canvas.isDrawn }
        check(canvas.page == phone && canvas.boards.map(\.id) == [phoneBoard.rawValue], "opened, the canvas shows Phone")
        canvas.showPage(desktop)
        pose("closed")
        await FixtureCheck.wait("the outer display's layout", seconds: 20) { navigator.layout == .phone }
        await FixtureWindows.wait("the narrow canvas", seconds: 20) { canvas.column && canvas.isDrawn }
        check(canvas.page == desktop && designs.page(ref) == desktop && canvas.boards.count == 3,
              "closed again, the narrow canvas keeps Desktop")
    }

    @MainActor private static func pose(_ pose: String) {
        print("FIXTURE POSE \(pose)")
        fflush(stdout)
    }
}
