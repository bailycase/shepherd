import Foundation
import ShepherdCore
import ShepherdRemote
import Testing

/// Characterizes the stacks and pane produced by a compact/regular layout switch.
@Suite struct NavigationCarryTests {
    private static let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let otherHost = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let ref = AgentRef(host: host, agent: AgentID(rawValue: "thread"))
    private static let other = AgentRef(host: otherHost, agent: AgentID(rawValue: "thread"))
    private static let thread = MobileRoute.thread(ref)

    struct Screen: Sendable {
        let route: MobileRoute
        var pane: PadSidePaneTab? = nil
    }

    private static let homeScreens: [Screen] = [
        .init(route: .home(.needsYou)),
        .init(route: .newThread(.compose(host: host))),
        .init(route: .subagents(.list(ref)), pane: .subagents),
        .init(route: .subagents(.run(ref, runID: "run")), pane: .subagents),
        .init(route: .review(.changes(ref, file: "README.md")), pane: .changes),
        .init(route: .review(.diff(ref, path: "README.md")), pane: .changes),
        .init(route: .review(.commit(ref))),
        .init(route: .search(.search(query: "acme"))),
        .init(route: .terminal(.panes(ref)), pane: .terminal),
        .init(route: .sidePane(.files(ref)), pane: .files),
        .init(route: .browser(.page(ref)), pane: .browser),
        .init(route: .forge(.list)),
    ]

    @Test(arguments: homeScreens)
    func homeScreensCarryAboveTheirThread(_ screen: Screen) {
        let pad = NavigationCarry.widen(tab: .home, path: [Self.thread, screen.route])
        let pane = NavigationCarry.takePaneScreens(selection: pad.selection, path: pad.path)
        let detail = pane?.path ?? pad.path
        let expected: [MobileRoute] = screen.pane == nil ? [screen.route] : []
        #expect(pad.selection == Self.ref)
        #expect(detail == expected)
        #expect(pane?.tab == screen.pane)
        #expect(pane?.route == (screen.pane == nil ? nil : screen.route))

        let phone = NavigationCarry.narrow(selection: pad.selection, path: detail, presented: nil)
        #expect(phone.tab == .home)
        // A pane converted on unfold is not pushed back into the compact stack.
        #expect(phone.path == [Self.thread] + expected)
    }

    struct TabScreen: Sendable {
        let tab: MobileTab
        let root: MobileRoute
        let route: MobileRoute
    }

    private static let tabScreens: [TabScreen] = [
        .init(tab: .designs, root: .padDesign(.list), route: .designs(.design(.init(host: host, design: .init(rawValue: "acme"))))),
        .init(tab: .designs, root: .padDesign(.list), route: .padDesign(.design(.init(host: host, design: .init(rawValue: "acme"))))),
        .init(tab: .projects, root: .projects(.list), route: .projects(.project(.init(home: .host(host), id: .init(rawValue: "acme"))))),
        .init(tab: .automations, root: .home(.automations), route: .automations(.detail(host: host, automation: .init(rawValue: "acme")))),
        .init(tab: .settings, root: .settings(.root), route: .settings(.appearance)),
        .init(tab: .settings, root: .settings(.root), route: .designs(.systems)),
    ]

    @Test(arguments: tabScreens)
    func nonHomeTabsAddAndRemoveTheirRoot(_ screen: TabScreen) {
        let path = [screen.route, .search(.search(query: "acme"))]
        let pad = NavigationCarry.widen(tab: screen.tab, path: path)
        #expect(pad.selection == nil)
        #expect(pad.path == [screen.root] + path)
        #expect(NavigationCarry.takePaneScreens(selection: pad.selection, path: pad.path) == nil)

        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: nil)
        #expect(phone.tab == screen.tab)
        #expect(phone.path == path)
    }

    @Test func aThreadAloneBecomesThePadSelectionAndBack() {
        let pad = NavigationCarry.widen(tab: .home, path: [Self.thread])
        #expect(pad.selection == Self.ref)
        #expect(pad.path.isEmpty)

        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: nil)
        #expect(phone.tab == .home)
        #expect(phone.path == [Self.thread])
    }

    @Test(arguments: [MobileTab.home, .designs])
    func emptyStackCarriesOnlyTheTabRoot(_ tab: MobileTab) {
        let pad = NavigationCarry.widen(tab: tab, path: [])
        #expect(pad.selection == nil)
        #expect(pad.path == (tab == .home ? [] : [.padDesign(.list)]))

        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: nil)
        #expect(phone.tab == tab)
        #expect(phone.path.isEmpty)
    }

    @Test func conversionUsesTheLastPushedThreadAndOnlyItsPaneSuffix() throws {
        let before = [MobileRoute.terminal(.panes(Self.other)), Self.thread, .browser(.page(Self.other))]
        let top = MobileRoute.review(.diff(Self.ref, path: "README.md"))
        let path = before + [.sidePane(.files(Self.ref)), top]
        let pane = try #require(NavigationCarry.takePaneScreens(selection: Self.other, path: path))
        #expect(pane.path == before)
        #expect(pane.tab == .changes)
        #expect(pane.route == top)

        let phone = NavigationCarry.narrow(selection: Self.other, path: pane.path, presented: nil)
        #expect(phone.path == [.thread(Self.other)] + before)
    }

    @Test func aNonPaneTopKeepsTheWholeStack() {
        let path = [Self.thread, .terminal(.panes(Self.ref)), .search(.search(query: "acme"))]
        let pad = NavigationCarry.widen(tab: .home, path: path)
        #expect(NavigationCarry.takePaneScreens(selection: pad.selection, path: pad.path) == nil)
        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: nil)
        #expect(phone.path == path)
    }

    @Test func aNonHomeOwnerDropsTheEarlierPadStack() {
        let path: [MobileRoute] = [.home(.needsYou), .home(.more), .settings(.root), .designs(.systems)]
        let phone = NavigationCarry.narrow(selection: Self.ref, path: path, presented: nil)
        #expect(phone.tab == .settings)
        #expect(phone.path == [.designs(.systems)])
    }

    @Test func anOrdinarySheetIsNotReplacedByAPush() {
        let pad = NavigationCarry.widen(tab: .home, path: [])
        let sheet = MobileRoute.newThread(.compose(host: Self.host))
        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: sheet)
        #expect(phone.path.isEmpty)
        #expect(phone.search == nil)
    }

    @Test func paletteFromSettingsCarriesSettingsAndOpensSearchInHome() throws {
        let path: [MobileRoute] = [.settings(.appearance)]
        let pad = NavigationCarry.widen(tab: .settings, path: path)
        let phone = NavigationCarry.narrow(selection: pad.selection, path: pad.path, presented: .search(.palette(query: "acme")))
        #expect(phone.tab == .settings)
        #expect(phone.path == path)
        let search = try #require(phone.search)
        #expect(search == .search(.search(query: "acme")))
        #expect(MobileTab.landing(of: search, from: phone.tab) == .home)
    }

    @Test func aForgottenHostsRoutesDoNotComeBackOnFold() {
        let pad = NavigationCarry.widen(tab: .home, path: [Self.thread, .review(.commit(Self.ref)), .thread(Self.other)])
        let detail = NavigationCarry.removing(host: Self.host, from: pad.path)
        // Forget clears the selected thread separately from the path.
        let phone = NavigationCarry.narrow(selection: nil, path: detail, presented: nil)
        #expect(phone.tab == .home)
        #expect(phone.path == [.thread(Self.other)])
        let widenedAgain = NavigationCarry.widen(tab: phone.tab, path: phone.path)
        #expect(widenedAgain.selection == Self.other)
        #expect(widenedAgain.path.isEmpty)
    }
}
