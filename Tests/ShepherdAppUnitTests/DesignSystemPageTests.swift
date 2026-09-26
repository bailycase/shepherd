import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Design systems in the app, as pure rules: the Designs page's systems grid (NavDesigns), a
/// system's page (DZSystem), a component's specimen board, New design's system card (DZStart),
/// and the sidebar's More ▸ Design systems.
@Suite("Design system page")
@MainActor
struct DesignSystemPageTests {
    private static let web = Space(name: "dashboard-web", path: "/tmp/dashboard-web")
    private static let app = Space(name: "shepherd", path: "/tmp/shepherd")
    private static let now = Date(timeIntervalSince1970: 1_790_215_200)
    private static let ms = now.timeIntervalSince1970 * 1000

    private static let tokens = DesignSystemTokens(
        name: "acme-web", namespace: "acme-web",
        colors: [
            .init(name: "--accent", value: "#4f46e5", source: .init(file: "web/static/tokens.css", line: 8)),
            .init(name: "--text", value: "#0f172a", source: .init(file: "web/static/tokens.css", line: 10)),
            .init(name: "--bg", value: "#f8fafc", source: .init(file: "web/static/tokens.css", line: 4)),
            .init(name: "--success", value: "#059669"),
        ],
        type: [.init(name: "display", size: 26, weight: 700, family: "sans", sample: "Checkout funnel"),
               .init(name: "label", size: 12, weight: 600, transform: "uppercase", sample: "People · conversion")],
        spacing: [.init(name: "--space-4", px: 16, source: .init(file: "web/static/tokens.css", line: 20))],
        radii: [.init(name: "--radius-md", px: 8)],
        fonts: [.init(name: "sans", family: "Inter")],
        components: [
            .init(name: "Button", source: .init(file: "templates/partials/button.html"), specimen: "components/Button.html"),
            .init(name: "Chip", source: .init(file: "templates/partials/chip.html"), specimen: "components/Chip.html"),
            .init(name: "Card", source: .init(file: "templates/partials/card.html")),
        ])

    private static func summary(_ namespace: String, title: String? = nil, builtIn: Bool = false, owner: DesignID? = nil,
                                space: SpaceID? = nil, sources: [String] = [], synced: Double? = nil, updated: Double = 0,
                                counts: DesignSystemCounts = DesignSystemCounts()) -> DesignSystemSummary {
        DesignSystemSummary(info: DesignSystemInfo(namespace: namespace, title: title ?? namespace, revision: 3, createdAt: 0,
                                                   updatedAt: updated, syncedAt: synced, ownerDesignID: owner, spaceID: space,
                                                   sources: sources),
                            builtIn: builtIn, counts: counts)
    }

    private static let acme = summary("acme-web", space: web.id, sources: ["web/static/tokens.css"], synced: ms - 4 * 60_000,
                                      counts: tokens.counts)
    private static let nightWatch = summary("night-watch", title: "Night Watch", builtIn: true)

    private func design(_ name: String, system: String? = nil, boards: Int = 4, space: Space = web, builds: Bool = false) -> Design {
        Design(name: name, systemNamespace: system, createdAt: 1_000, boardCount: boards, buildsSystem: builds,
               sourceSpaceID: builds ? space.id : nil)
    }

    // MARK: The systems grid (NavDesigns)

    @Test func theGridListsTheSystemsBuiltHereThenBuildsThenTheBuiltIns() {
        let build = design("shepherd", space: Self.app, builds: true)
        let designs = [design("Checkout", system: "acme-web"), design("Onboarding", system: "acme-web"),
                       design("Settings", system: "night-watch"), build]
        let zeta = Self.summary("zeta", space: Self.app.id)
        let model = DesignsPageModel.make(designs: designs, spaces: [Self.web, Self.app], firstBoards: [:], filter: "", selection: nil,
                                          now: Self.now, systems: [Self.nightWatch, zeta, Self.acme],
                                          swatches: ["acme-web": DesignSystemPresentation.swatches(Self.tokens, count: 4)])
        #expect(model.systems.map(\.name) == ["acme-web", "zeta", "shepherd", "Night Watch"])
        #expect(model.systems.map(\.id) == [.system("acme-web"), .system("zeta"), .build(build.id), .system("night-watch")])
        #expect(model.systems.map(\.source) == ["dashboard-web · tokens.css", "shepherd", "shepherd · building",
                                                DesignsPageModel.builtInSource])
        #expect(model.systems.map(\.count) == ["2 designs", "0 designs", "", "1 design"])
        #expect(model.systems[0].swatches.map(\.light) == ["#4f46e5", "#0f172a", "#f8fafc", "#059669"])
        #expect(!model.cards.contains { $0.id == build.id }, "a build has no card")
        #expect(model.projects.map(\.name) == ["dashboard-web", "shepherd"])
    }

    /// Three to a row; "Build one from a repo" follows the last system, on a row of its own when
    /// the last is full.
    @Test(arguments: [(0, [0], [true]), (2, [2], [true]), (3, [3, 0], [false, true]), (4, [3, 1], [false, true])])
    func theBuildTileFollowsTheLastSystem(count: Int, rows: [Int], tiles: [Bool]) {
        let systems = (0..<count).map { Self.summary("s\($0)") }
        let model = DesignsPageModel.make(designs: [], spaces: [], firstBoards: [:], filter: "", selection: nil, now: Self.now,
                                          systems: systems)
        #expect(model.systemRows.map(\.systems.count) == rows)
        #expect(model.systemRows.map(\.tile) == tiles)
    }

    @Test func theFilterKeepsSystemsByNameSourceOrTheDesignsItKeeps() {
        let designs = [design("Checkout", system: "acme-web"), design("Settings", system: "night-watch")]
        func names(_ filter: String) -> [String] {
            DesignsPageModel.make(designs: designs, spaces: [Self.web], firstBoards: [:], filter: filter, selection: nil, now: Self.now,
                                  systems: [Self.nightWatch, Self.acme]).systems.map(\.name)
        }
        #expect(names("checkout") == ["acme-web"])
        #expect(names("tokens.css") == ["acme-web"])
        #expect(names("night") == ["Night Watch"])
        #expect(names("nothing").isEmpty)
    }

    // MARK: A system's page (DZSystem)

    @Test func thePageSaysWhereTheSystemWasReadAndHowFresh() throws {
        let read = DesignSystemRead(summary: Self.acme, tokens: Self.tokens, readme: nil, files: [])
        let model = DesignSystemPageModel.make(summary: Self.acme, read: read, build: nil, spaces: [Self.web], designs: [],
                                               syncing: false, now: Self.now)
        #expect(model.title == "acme-web" && model.namespace == "acme-web")
        #expect(model.status == NWDesignHeaderStatus(.done, label: "Synced"))
        #expect(model.source.map(\.text) == ["Read from ", "dashboard-web", ": ", "web/static/tokens.css", " and 3 templates in ",
                                             "templates/partials/", " · synced 4m ago"])
        #expect(model.source.map(\.mono) == [false, true, false, true, false, true, false])
        #expect(model.canResync && !model.builtIn)
        #expect(model.chip.map(\.light) == ["#4f46e5", "#0f172a", "#f8fafc"])
        #expect(model.background == "#f8fafc")
    }

    @Test func thePageListsEachSectionWithItsCount() {
        let read = DesignSystemRead(summary: Self.acme, tokens: Self.tokens, readme: nil, files: [])
        let designs = [design("Checkout", system: "acme-web", boards: 4), design("Onboarding", system: "acme-web", boards: 2),
                       design("Other", boards: 9)]
        let model = DesignSystemPageModel.make(summary: Self.acme, read: read, build: nil, spaces: [Self.web], designs: designs,
                                               syncing: false, now: Self.now)
        #expect(model.sections.map(\.title) == ["Colors", "Type", "Spacing & radii", "Components", "Boards using it"])
        #expect(model.sections.map(\.count) == [4, 2, 2, 3, 6])
        #expect(model.colors.map(\.detail) == ["#4f46e5 · tokens.css:8", "#0f172a · tokens.css:10", "#f8fafc · tokens.css:4", "#059669"])
        #expect(model.type.map(\.sample) == ["Checkout funnel", "PEOPLE · CONVERSION"])
        #expect(model.type.map(\.family) == ["Inter", nil], "a style's font names one of the system's faces")
        #expect(model.type.map(\.spec) == ["26/700", "12/600"])
        #expect(model.steps.map(\.detail) == ["16px · tokens.css:20", "8px"])
        #expect(model.components.map(\.template) == ["partials/button.html", "partials/chip.html", "partials/card.html"])
        #expect(model.components.map(\.specimen) == ["components/Button.html", "components/Chip.html", nil])
        #expect(model.boards.map(\.name) == ["Checkout", "Onboarding"] && model.boards.map(\.detail) == ["4 boards", "2 boards"])
    }

    @Test func aResyncSaysSoAndABuiltInCantBeSynced() {
        let syncing = DesignSystemPageModel.make(summary: Self.acme, read: nil, build: nil, spaces: [Self.web], designs: [],
                                                 syncing: true, now: Self.now)
        #expect(syncing.status == NWDesignHeaderStatus(.running, label: "Syncing"))
        let builtIn = DesignSystemPageModel.make(summary: Self.nightWatch, read: nil, build: nil, spaces: [], designs: [],
                                                 syncing: false, now: Self.now)
        #expect(builtIn.status == nil && !builtIn.canResync && builtIn.builtIn)
        #expect(builtIn.source.map(\.text) == ["Generated from ShepherdUI's tokens"])
        #expect(builtIn.background == "#ffffff", "a system without a background draws on a page's own white")
        // Its project gone: nothing to read again, and the line says what it holds.
        let orphan = Self.summary("acme-web", space: SpaceID(), counts: DesignSystemCounts(colors: 2, type: 1))
        let gone = DesignSystemPageModel.make(summary: orphan, read: nil, build: nil, spaces: [Self.web], designs: [],
                                              syncing: false, now: Self.now)
        #expect(!gone.canResync)
        #expect(gone.source.map(\.text) == ["2 colors, 1 type style, 0 spacing and radius steps, 0 components"])
    }

    @Test func aBuildStillReadingItsProjectSaysSo() {
        let build = design("dashboard-web", builds: true)
        let model = DesignSystemPageModel.make(summary: nil, read: nil, build: build, spaces: [Self.web], designs: [],
                                               syncing: false, now: Self.now)
        #expect(model.building && model.namespace == nil && model.sections.isEmpty)
        #expect(model.title == "dashboard-web")
        #expect(model.source.map(\.text) == ["Reading ", "dashboard-web", "…"])
    }

    @Test(arguments: [
        (["templates/partials/a.html", "templates/partials/b.html"], "templates/partials"),
        (["a/x.html", "b/y.html"], nil), (["button.html"], nil),
    ] as [([String], String?)])
    func templatesNameTheirFolderWhenTheyShareOne(_ files: [String], _ folder: String?) {
        #expect(DesignSystemPageModel.commonFolder(files) == folder)
    }

    // MARK: Specimens

    @Test func aSpecimenIsABoardOfTheTilesSizeInTheSystem() throws {
        let files: [String: Data] = [
            "tokens.css": Data(":root{}".utf8),
            "components/Button.html": Data("<button class=\"btn\">Export CSV</button>".utf8),
            "components/Chip.html": Data(repeating: 0x61, count: DesignSpecimenBoard.maxSpecimenBytes + 1),
        ]
        let boards = DesignSpecimenBoard.boards(Self.tokens, files: files, background: "#f8fafc")
        #expect(boards.keys.sorted() == [0], "a specimen too large, or none, draws nothing")
        let board = try #require(boards[0])
        #expect(board.path == "_specimen-0.dc.html" && DesignPath(board.path) != nil)
        #expect(board.source.contains("<script src=\"./support.js\"></script>"))
        #expect(board.source.contains("<link rel=\"stylesheet\" href=\"tokens.css\">"))
        #expect(board.source.contains("<button class=\"btn\">Export CSV</button>"))
        #expect(board.source.contains("width: 320px; height: 92px;") && board.source.contains("background: #f8fafc;"))
        #expect(board.source.contains("<title>Button</title>"))
        // A background that isn't a color is left out rather than written into the style.
        let hostile = DesignSpecimenBoard.source(specimen: "x", title: "<b>", stylesheet: false, background: "red; }")
        #expect(!hostile.contains("red;") && !hostile.contains("tokens.css") && hostile.contains("<title>&lt;b&gt;</title>"))
    }

    @Test func newDesignsCardNamesTheSystemAndTheRepoItWasReadFrom() {
        let built = NewDesignState.card(system: Self.acme, spaces: [Self.web])
        #expect(built == ("acme-web", "design system · dashboard-web", "found in web/static/tokens.css"))
        // The repo is information only: a system whose project is gone still names itself.
        let orphan = NewDesignState.card(system: Self.acme, spaces: [])
        #expect(orphan == ("acme-web", "design system", "found in web/static/tokens.css"))
        let written = NewDesignState.card(system: Self.summary("sketch"), spaces: [Self.web])
        #expect(written == ("sketch", "design system", "made in Shepherd"))
        let nightWatch = NewDesignState.card(system: Self.nightWatch, spaces: [])
        #expect(nightWatch == ("night-watch", "design system · shepherd", "built into Shepherd"))
        let none = NewDesignState.card(system: nil, spaces: [Self.web])
        #expect(none.title == "No design system")
    }

    /// A new design starts in the system changed last among those built here, else Night Watch:
    /// no project picks it.
    @Test func aNewDesignStartsInTheLatestSystemBuiltHereElseTheBuiltIn() {
        let older = Self.summary("older", space: Self.app.id, updated: 1)
        let newer = Self.summary("newer", space: Self.web.id, updated: 2)
        #expect(NewDesignState.defaultSystem(in: [Self.nightWatch, older, newer])?.namespace == "newer")
        #expect(NewDesignState.defaultSystem(in: [Self.nightWatch])?.namespace == "night-watch")
        #expect(NewDesignState.defaultSystem(in: []) == nil)
        let draft = NewDesignState()
        #expect(draft.chosenSystem(in: [Self.nightWatch, older, newer])?.namespace == "newer")
        draft.choose(system: "older")
        #expect(draft.chosenSystem(in: [Self.nightWatch, older, newer])?.namespace == "older")
        // A pick that is gone reads as the default.
        #expect(draft.chosenSystem(in: [Self.nightWatch])?.namespace == "night-watch")
    }

    // MARK: The sidebar

    @Test func designSystemsSitsUnderMoreBetweenHostsAndExtensionsWhileTheToolIsOn() {
        let off = SidebarDerivation.destinations(shown: nil, moreOpen: true, offlineHosts: 0, newThreadChord: "⌘N")
        #expect(off.map(\.title) == ["New thread", "Automations", "More", "Hosts", "Extensions"])
        let on = SidebarDerivation.destinations(shown: .designSystem, moreOpen: true, offlineHosts: 0, newThreadChord: "⌘N", designs: true)
        #expect(on.map(\.title) == ["New thread", "Designs", "Automations", "More", "Hosts", "Design systems", "Extensions"])
        let row = on[5]
        #expect(row.target == .designSystems && row.icon == .symbol("paintpalette") && row.child && row.selected)
        #expect(!on[1].selected, "a system's page is not the Designs page")
        let build = SidebarDerivation.destinations(shown: nil, moreOpen: true, offlineHosts: 0, newThreadChord: "⌘N", designs: true,
                                                   systemShown: true)
        #expect(build[5].selected, "a build's page is a system's page")
    }

    @Test func aSystemBuildHasNoRecentsRowAndNeitherDoesItsAgent() {
        var builder = Fixture.agent("dashboard-web", in: Self.web).agent
        let build = Design(name: "dashboard-web", agentID: builder.id, createdAt: 1, buildsSystem: true, sourceSpaceID: Self.web.id)
        builder.designID = build.id
        let canvas = Design(name: "Checkout", createdAt: 2)
        let lists = SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [Self.web], agents: [builder],
                                                                               designs: [build, canvas]), designs: true))
        #expect(lists.all.map(\.id) == [.design(canvas.id)])
    }
}
