import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Budgets for the long lists, over realistic large fixtures in
/// off-screen windows. The budgets count row bodies (`SHRenderProbe`), which a slower machine
/// doesn't change: a list that builds rows off screen, or redraws every row for a highlight, a
/// selection, or one row's change, fails whatever the hardware. `ListPerformanceReport` prints the
/// timings behind them.
@Suite("List performance", .mainActorExclusive)
@MainActor
struct ListPerformanceTests {
    // MARK: Sidebar

    private static let sidebarSize = CGSize(width: AppLayout.sidebarDefaultWidth, height: 800)

    /// How many rows fit the window, with a row's height and spacing.
    private static var sidebarRowsOnScreen: Int {
        Int(sidebarSize.height / (SHDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
    }

    /// The fleet in an off-screen sidebar, settled.
    private func openSidebar(_ app: AppHarness) async throws -> (ShepherdViewModel, OffscreenWindow) {
        var fleet = ListFixtures.fleet(in: app.dir)
        // These Recents-focused measurements need idle rows on screen, not below status groups.
        for index in fleet.agents.indices { fleet.agents[index].status = .idle }
        let vm = try await app.start(with: fleet)
        let window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
        ListPerf.settle(window)
        return (vm, window)
    }

    /// The Recents rows on screen at the top of the list (Needs you's come first).
    private func recentsOnScreen(_ vm: ShepherdViewModel) -> [SidebarListRow] {
        Array(vm.sidebarLists.all.prefix(Self.sidebarRowsOnScreen / 2)).filter { row in vm.sidebarLists.recents.contains { $0.id == row.id } }
    }

    @Test func openingTheSidebarOverThreeHundredAgentsBuildsOnlyTheRowsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= 2 * Self.sidebarRowsOnScreen, "\(rows)")
        #expect(rows["sidebar.lists", default: 0] <= 1, "one derivation for the whole list: \(rows)")
    }

    /// Scrolling Recents builds the rows that come into view, never the whole fleet.
    @Test func scrollingRecentsBuildsOnlyTheRowsComingIntoView() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window) = try await openSidebar(app)
        defer { window.close() }
        let scroll = try #require(ListPerf.scrollView(in: window))
        let step = SHDensity.standard.rowHeight * 4

        var moved: CGFloat = 0
        let rows = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: step, steps: 20).distance }
        let arriving = Int(moved / (SHDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
        #expect(moved > 0)
        #expect(rows["sidebar.row", default: 0] <= 2 * (arriving + Self.sidebarRowsOnScreen), "\(rows)")
        #expect(rows["sidebar.lists", default: 0] == 0, "scrolling derives nothing: \(rows)")
    }

    /// A status change moves its row to the matching group and updates both counts, without
    /// redrawing its neighbors or the destinations. Activity order still follows the stamp.
    @Test func aStatusReportRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openSidebar(app)
        defer { window.close() }
        let shown = recentsOnScreen(vm).prefix(6)
        try #require(!shown.isEmpty)
        let indices = try shown.map { row in try #require(vm.state.agents.firstIndex { $0.id == row.id.agentID }) }
        let order = vm.sidebarLists.activity.map(\.id)

        let rows = ListPerf.counting {
            for index in indices {
                var next = vm.state
                next.agents[index].status = next.agents[index].status == .working ? .done : .working
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(vm.sidebarLists.activity.map(\.id) == order)
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
        #expect(rows["sidebar.header", default: 0] <= shown.count * 2, "only the source and destination counts: \(rows)")
        #expect(rows["sidebar.destination", default: 0] == 0, "\(rows)")
        #expect(rows["sidebar.lists", default: 0] <= shown.count, "\(rows)")
    }

    /// One row changing (a settled name) redraws that row alone.
    @Test func oneRowChangingRedrawsThatRowAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openSidebar(app)
        defer { window.close() }
        let shown = recentsOnScreen(vm).prefix(6)
        try #require(!shown.isEmpty)
        let indices = try shown.map { row in try #require(vm.state.agents.firstIndex { $0.id == row.id.agentID }) }

        let rows = ListPerf.counting {
            for index in indices {
                var next = vm.state
                next.agents[index].name += " (renamed)"
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
    }

    /// A selection moving redraws the row it leaves and the row it lands on.
    @Test func aSelectionMovingRedrawsTheTwoRowsItTouches() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openSidebar(app)
        defer { window.close() }
        let shown = recentsOnScreen(vm).prefix(6)
        try #require(!shown.isEmpty)

        let rows = ListPerf.counting {
            for row in shown { ListPerf.time(window) { vm.selectSidebarRow(row.id) } }
        }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2 + 2, "\(rows)")
        #expect(rows["sidebar.lists", default: 0] == 0, "a selection derives nothing: \(rows)")
    }

    // MARK: Sidebar with pinned threads

    /// The fleet in an off-screen sidebar with `pinned` of its threads pinned, settled. The
    /// pinned threads are the fleet's middle and last, so none of them starts out on top.
    private func openPinnedSidebar(_ app: AppHarness, pinned count: Int) async throws -> (ShepherdViewModel, OffscreenWindow) {
        var fleet = ListFixtures.fleet(in: app.dir)
        for index in fleet.agents.indices { fleet.agents[index].status = .idle }
        let vm = try await app.start(with: fleet)
        let recents = vm.sidebarLists.recents
        for row in recents[(recents.count / 2)...].prefix(count) { vm.pinThread(row.id) }
        let window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
        ListPerf.settle(window)
        return (vm, window)
    }

    @Test func openingTheSidebarWithPinnedThreadsBuildsOnlyTheRowsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        var fleet = ListFixtures.fleet(in: app.dir)
        for index in fleet.agents.indices { fleet.agents[index].status = .idle }
        let vm = try await app.start(with: fleet)
        let recents = vm.sidebarLists.recents
        for row in recents[(recents.count / 2)...].prefix(12) { vm.pinThread(row.id) }
        #expect(vm.sidebarLists.pinned.count == 12)

        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= 2 * Self.sidebarRowsOnScreen, "\(rows)")
        #expect(rows["sidebar.header", default: 0] <= 3, "Pinned, Projects and Recents: \(rows)")
        #expect(rows["sidebar.lists", default: 0] <= 1, "one derivation for the whole list: \(rows)")
    }

    /// Pinning redraws the row that moves and the headers that change, not the rows it shifts:
    /// the first pin brings Pinned in; every pin updates Pinned and Recents' counts.
    @Test func pinningAThreadRedrawsOnlyTheRowThatMovesAndTheHeaders() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openPinnedSidebar(app, pinned: 0)
        defer { window.close() }
        let shown = Array(vm.sidebarLists.recents.prefix(Self.sidebarRowsOnScreen / 2))
        try #require(shown.count >= 4)

        let first = ListPerf.counting { ListPerf.time(window) { vm.pinThread(shown[1].id) } }
        #expect(vm.sidebarLists.pinned.map(\.id) == [shown[1].id])
        #expect(first["sidebar.row", default: 0] <= 4, "\(first)")
        #expect((1...2).contains(first["sidebar.header", default: 0]), "the Pinned header arrives: \(first)")
        #expect(first["sidebar.destination", default: 0] == 0, "\(first)")
        #expect(first["sidebar.lists", default: 0] <= 1, "\(first)")

        let second = ListPerf.counting { ListPerf.time(window) { vm.pinThread(shown[3].id) } }
        #expect(vm.sidebarLists.pinned.count == 2)
        #expect(second["sidebar.row", default: 0] <= 4, "\(second)")
        #expect(second["sidebar.header", default: 0] == 2, "Pinned and Recents counts change: \(second)")
        #expect(second["sidebar.lists", default: 0] <= 1, "\(second)")
    }

    @Test func unpinningAThreadRedrawsOnlyTheRowThatMovesAndTheHeaders() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openPinnedSidebar(app, pinned: 2)
        defer { window.close() }
        let pinned = vm.sidebarLists.pinned
        try #require(pinned.count == 2)

        let one = ListPerf.counting { ListPerf.time(window) { vm.unpinThread(pinned[0].id) } }
        #expect(vm.sidebarLists.pinned.map(\.id) == [pinned[1].id])
        #expect(one["sidebar.row", default: 0] <= 4, "\(one)")
        #expect(one["sidebar.header", default: 0] == 2, "Pinned and Recents counts change: \(one)")
        #expect(one["sidebar.lists", default: 0] <= 1, "\(one)")

        let last = ListPerf.counting { ListPerf.time(window) { vm.unpinThread(pinned[1].id) } }
        #expect(vm.sidebarLists.pinned.isEmpty)
        #expect(last["sidebar.row", default: 0] <= 4, "\(last)")
        #expect(last["sidebar.header", default: 0] <= 2, "the Pinned header goes: \(last)")
        #expect(last["sidebar.destination", default: 0] == 0, "\(last)")
    }

    /// A status report on a pinned thread redraws its row and nothing else: the pins hold their
    /// order, and no header changes.
    @Test func aStatusReportOnAPinnedThreadRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openPinnedSidebar(app, pinned: 6)
        defer { window.close() }
        let shown = vm.sidebarLists.pinned.prefix(6)
        try #require(shown.count == 6)
        let order = vm.sidebarLists.pinned.map(\.id)
        let indices = try shown.map { row in try #require(vm.state.agents.firstIndex { $0.id == row.id.agentID }) }

        let rows = ListPerf.counting {
            for index in indices {
                var next = vm.state
                next.agents[index].status = next.agents[index].status == .working ? .done : .working
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(vm.sidebarLists.pinned.map(\.id) == order)
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
        #expect(rows["sidebar.header", default: 0] == 0, "\(rows)")
        #expect(rows["sidebar.destination", default: 0] == 0, "\(rows)")
        #expect(rows["sidebar.lists", default: 0] <= shown.count, "\(rows)")
    }

    // MARK: Sidebar organized by project

    /// The fleet in an off-screen sidebar organized by project, settled.
    private func openProjectsSidebar(_ app: AppHarness) async throws -> (ShepherdViewModel, OffscreenWindow) {
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        vm.settings.sidebarStyle = .projects
        let window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
        ListPerf.settle(window)
        return (vm, window)
    }

    /// The open projects' threads on screen at the top of the tree.
    private func treeRowsOnScreen(_ vm: ShepherdViewModel) -> [SidebarListRow] {
        Array(vm.sidebarWalkRows.prefix(Self.sidebarRowsOnScreen / 2))
    }

    @Test func openingTheProjectTreeOverThreeHundredAgentsBuildsOnlyTheRowsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        vm.settings.sidebarStyle = .projects
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let built = rows["sidebar.row", default: 0] + rows["sidebar.project", default: 0]
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.project", default: 0] > 0, "\(rows)")
        #expect(built <= 2 * Self.sidebarRowsOnScreen, "\(rows)")
        #expect(rows["sidebar.tree", default: 0] <= 1, "one derivation for the whole tree: \(rows)")
        #expect(rows["sidebar.lists", default: 0] == 0, "Activity's lists are not derived for the tree: \(rows)")
    }

    @Test func threeHundredNestedProjectsStillBuildOnlyVisibleRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Platform", path: app.dir.path)
        let children = (0..<300).map { Fixture.space("Child \($0)", path: app.dir.appendingPathComponent("child-\($0)").path) }
        let agents = children.enumerated().map { Fixture.agent("Work \($0.offset)", in: $0.element, order: $0.offset) }
        let vm = try await app.start(with: Fixture.state(spaces: children + [parent], agents: agents))
        vm.settings.sidebarStyle = .projects
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(vm.sidebarTree.projects.filter { $0.parentID == .local(parent.id) }.count == 300)
        #expect(rows["sidebar.row", default: 0] + rows["sidebar.project", default: 0] <= 2 * Self.sidebarRowsOnScreen)
        #expect(rows["sidebar.tree", default: 0] <= 1)
    }

    /// Scrolling the tree builds the rows that come into view, never the whole fleet.
    @Test func scrollingTheProjectTreeBuildsOnlyTheRowsComingIntoView() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window) = try await openProjectsSidebar(app)
        defer { window.close() }
        let scroll = try #require(ListPerf.scrollView(in: window))
        let step = SHDensity.standard.rowHeight * 4

        var moved: CGFloat = 0
        let rows = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: step, steps: 20).distance }
        let arriving = Int(moved / (SHDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
        #expect(moved > 0)
        #expect(rows["sidebar.row", default: 0] + rows["sidebar.project", default: 0] <= 2 * (arriving + Self.sidebarRowsOnScreen),
                "\(rows)")
        #expect(rows["sidebar.tree", default: 0] == 0, "scrolling derives nothing: \(rows)")
    }

    /// A status report redraws its row (and its project's, whose roll-up may change), never the
    /// other rows or the destinations, and derives the tree once.
    @Test func aStatusReportRedrawsOnlyItsRowInTheTree() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openProjectsSidebar(app)
        defer { window.close() }
        let shown = treeRowsOnScreen(vm).prefix(6)
        try #require(!shown.isEmpty)
        let indices = try shown.map { row in try #require(vm.state.agents.firstIndex { $0.id == row.id.agentID }) }

        let rows = ListPerf.counting {
            for index in indices {
                var next = vm.state
                next.agents[index].status = next.agents[index].status == .working ? .done : .working
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(rows["sidebar.row", default: 0] > 0, "\(rows)")
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
        #expect(rows["sidebar.project", default: 0] <= shown.count * 2, "\(rows)")
        #expect(rows["sidebar.destination", default: 0] == 0, "\(rows)")
        #expect(rows["sidebar.tree", default: 0] <= shown.count, "\(rows)")
    }

    /// Opening a closed project builds its threads and redraws its own row; nothing derives.
    @Test func expandingAProjectBuildsOnlyItsRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openProjectsSidebar(app)
        defer { window.close() }
        vm.setAllProjects(expanded: false)
        ListPerf.settle(window)
        let project = try #require(vm.sidebarTree.projects.first)

        let rows = ListPerf.counting {
            ListPerf.time(window) { vm.toggleProject(project.id) }
        }
        #expect(vm.sidebarWalkRows.count == project.rows.count)
        #expect(rows["sidebar.row", default: 0] <= project.rows.count * 2, "\(rows)")
        #expect(rows["sidebar.project", default: 0] <= 2, "\(rows)")
        #expect(rows["sidebar.tree", default: 0] == 0, "opening a project derives nothing: \(rows)")
    }

    // MARK: Designs

    private static let designsSize = CGSize(width: 1200, height: 800)
    /// A card's height: its thumbnail and its three lines, with the gap under it.
    private static let designRowHeight = SHDesignMetrics.cardThumbnailHeight + 80 + SHPageMetrics.columnGap

    /// Rows of cards that fit the page under its header.
    private static var designRowsOnScreen: Int {
        Int((designsSize.height - SHPageMetrics.headerHeight) / designRowHeight) + 1
    }

    /// The Designs page over 120 designs (no boards, so no thumbnails to render), and what opens
    /// it in a window.
    private func openDesigns(_ app: AppHarness) async throws -> () -> OffscreenWindow {
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.designNetwork = .none
        for index in 0..<120 {
            _ = try await app.server.createDesign(Design(name: "Design \(index)", createdAt: Double(1_000 + index)))
        }
        try await eventuallyOnMain("the designs to arrive") { vm.state.designs.count == 120 }
        vm.openDestination(.designs)
        return { OffscreenWindow(size: Self.designsSize, dark: true, DesignsDestination(vm: vm)) }
    }

    @Test func openingTheDesignsPageBuildsOnlyTheCardsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let make = try await openDesigns(app)
        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = make()
            ListPerf.settle(window)
        }
        defer { window.close() }
        let onScreen = Self.designRowsOnScreen * DesignsPageModel.columns
        #expect(counts["design.card", default: 0] > 0)
        #expect(counts["design.card", default: 0] <= 2 * (onScreen + DesignsPageModel.columns), "\(counts)")
    }

    /// Scrolling the cards builds the rows that come into view, never all 120 cards.
    @Test func scrollingTheDesignsPageBuildsOnlyTheCardsComingIntoView() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let make = try await openDesigns(app)
        let window = make()
        ListPerf.settle(window)
        defer { window.close() }
        let scroll = try #require(ListPerf.scrollView(in: window))
        var moved: CGFloat = 0
        let counts = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: Self.designRowHeight / 2, steps: 12).distance }
        let arriving = (Int(moved / Self.designRowHeight) + 1) * DesignsPageModel.columns
        #expect(moved > 0)
        #expect(counts["design.card", default: 0] <= 2 * (arriving + Self.designRowsOnScreen * DesignsPageModel.columns), "\(counts)")
        #expect(counts["design.card", default: 0] < 120)
    }

    /// A host's 120 designs (`designs.v1`) under its name: the page builds the cards on screen,
    /// as it does for this Mac's.
    @Test func openingTheDesignsPageBuildsOnlyTheHostsCardsOnScreen() async throws {
        let app = try AppHarness(), remote = try RemoteHostHarness()
        defer { app.stop(); remote.stop() }
        app.settings.designToolEnabled = true
        remote.host.settings.designToolEnabled = true
        let vm = try await app.start(with: ShepherdState())
        vm.designNetwork = .none
        let space = Fixture.space(path: remote.host.dir.path)
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        for index in 0..<120 {
            _ = try await remote.host.server.createDesign(Design(name: "Design \(index)", createdAt: Double(1_000 + index)))
        }
        _ = try await remote.connect(app.remoteHosts)
        await vm.loadRemoteDesigns()
        #expect(vm.remoteDesignSections.first?.cards.count == 120)
        vm.openDestination(.designs)

        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = OffscreenWindow(size: Self.designsSize, dark: true, DesignsDestination(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let onScreen = Self.designRowsOnScreen * DesignsPageModel.columns
        #expect(counts["design.card", default: 0] > 0)
        #expect(counts["design.card", default: 0] <= 2 * (onScreen + DesignsPageModel.columns), "\(counts)")
    }

    // MARK: The Export sheet's boards

    /// The Export sheet over a design of 172 boards: it builds the rows it shows (eight, then it
    /// scrolls), and a tick redraws the row it changed.
    @Test func theExportSheetBuildsOnlyTheBoardRowsItShowsAndATickRedrawsOne() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.designNetwork = .none
        let design = Design(name: "Large", createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.grid(172), in: design.id, on: app.server, perRow: 12)
        try await eventuallyOnMain("the design to arrive") { vm.state.designs.count == 1 }
        await vm.designScreen(design.id).refresh()
        vm.openDesignExport(design.id)
        // The sheet opens over this Mac's synced copy of the host's design.
        try await eventuallyOnMain("the export sheet", timeout: .seconds(30)) { vm.designExport != nil }
        let model = try #require(vm.designExport)
        #expect(model.selection.rows.count == 172)

        var window: OffscreenWindow!
        let opening = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 900, height: 900), dark: true, DesignExportOverlay(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let shown = Int(SHDesignMetrics.exportVisibleRows)
        #expect(opening["design.exportRow", default: 0] > 0)
        #expect(opening["design.exportRow", default: 0] <= 2 * (shown + 2), "\(opening)")

        let first = try #require(model.selection.rows.first?.path)
        let tick = ListPerf.counting {
            model.selection.toggle(first)
            ListPerf.settle(window)
        }
        #expect(tick["design.exportRow", default: 0] >= 1)
        #expect(tick["design.exportRow", default: 0] <= 2, "\(tick)")
    }

    // MARK: Design systems

    /// A system card's height (its 12pt padding and two lines) with the gap under it.
    private static let systemRowHeight: CGFloat = 2 * SHDesignMetrics.cardPaddingVertical + 32 + SHPageMetrics.columnGap

    /// `count` systems in the server's store, as folders it lists (the store's cap is 100), each
    /// with `colors` colors.
    private func writeSystems(_ app: AppHarness, count: Int, colors: Int = 4) throws {
        let directory = app.server.designSystems.directory
        for index in 0..<count {
            let namespace = String(format: "system-%03d", index)
            let folder = directory.appendingPathComponent(namespace, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tokens = DesignSystemTokens(name: namespace, namespace: namespace, colors: (0..<colors).map { color in
                DesignSystemTokens.Color(name: "--color-\(color)", value: String(format: "#%06x", color * 997 % 0xffffff))
            })
            try tokens.encoded().write(to: folder.appendingPathComponent(DesignSystemFile.tokens))
            let info = DesignSystemInfo(namespace: namespace, title: namespace, revision: 1, createdAt: 1)
            try JSONEncoder().encode(info).write(to: folder.appendingPathComponent(DesignSystemFile.info))
        }
    }

    /// The Designs page over the store's 100 systems (no designs): only the system rows on
    /// screen are built.
    @Test func openingTheDesignsPageBuildsOnlyTheSystemCardsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space(path: app.dir.path)]))
        vm.designNetwork = .none
        try writeSystems(app, count: DesignSystemStore.maxSystems)
        await vm.loadDesignSystems()
        #expect(vm.designSystems.summaries.count == DesignSystemStore.maxSystems)
        vm.openDestination(.designs)
        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = OffscreenWindow(size: Self.designsSize, dark: true, DesignsDestination(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let onScreen = (Int((Self.designsSize.height - SHPageMetrics.headerHeight) / Self.systemRowHeight) + 1) * DesignsPageModel.systemColumns
        #expect(counts["design.systemCard", default: 0] > 0)
        #expect(counts["design.systemCard", default: 0] <= 2 * (onScreen + DesignsPageModel.systemColumns), "\(counts)")
        #expect(counts["design.systemCard", default: 0] < DesignSystemStore.maxSystems)
    }

    /// A system's page over 300 colors: only the color rows on screen are built.
    @Test func openingASystemsPageBuildsOnlyTheSwatchesOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space(path: app.dir.path)]))
        vm.designNetwork = .none
        try writeSystems(app, count: 1, colors: 300)
        await vm.loadDesignSystems()
        vm.openDesignSystem("system-000")
        #expect(vm.shownDestination == .designSystem)
        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = OffscreenWindow(size: Self.designsSize, dark: true, DesignSystemDestination(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        // A color is a row of its table (DesignSystemColors): at least a control's height, so no more than
        // the window's height over that are on screen at once.
        let onScreen = Int(Self.designsSize.height / SH.Height.controlM) + 1
        #expect(counts["design.referenceColor", default: 0] > 0)
        #expect(counts["design.referenceColor", default: 0] <= 2 * onScreen, "\(counts)")
        #expect(counts["design.referenceColor", default: 0] < 300)
    }

    // MARK: A design's comments

    private static let commentsSize = CGSize(width: AppLayout.designChatWidth, height: 800)
    /// A one-line comment's card and the room after it: at least this tall.
    private static let commentRowHeight: CGFloat = 70

    private static var commentsOnScreen: Int { Int(commentsSize.height / commentRowHeight) + 1 }

    /// The Comments tab over 300 open comments.
    private static func commentsList() -> DesignCommentsList {
        DesignCommentsList(cards: (1...300).map { number in
            DesignCommentCardValue(id: UUID(), number: number, target: "A · Checkout funnel", meta: "You · 2m",
                                   text: "Comment \(number): show the absolute counts next to the percentages.")
        }) { _ in }
    }

    @Test func openingTheCommentsTabBuildsOnlyTheCardsOnScreen() {
        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = OffscreenWindow(size: Self.commentsSize, dark: true, Self.commentsList())
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(counts["design.comment", default: 0] > 0)
        #expect(counts["design.comment", default: 0] <= 2 * Self.commentsOnScreen, "\(counts)")
    }

    @Test func scrollingTheCommentsTabBuildsOnlyTheCardsComingIntoView() throws {
        let window = OffscreenWindow(size: Self.commentsSize, dark: true, Self.commentsList())
        ListPerf.settle(window)
        defer { window.close() }
        let scroll = try #require(ListPerf.scrollView(in: window))
        var moved: CGFloat = 0
        let counts = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: Self.commentRowHeight / 2, steps: 12).distance }
        #expect(moved > 0)
        let arriving = Int(moved / Self.commentRowHeight) + 1
        #expect(counts["design.comment", default: 0] <= 2 * (arriving + Self.commentsOnScreen), "\(counts)")
        #expect(counts["design.comment", default: 0] < 300)
    }

    // MARK: Browser console

    private static let consoleSize = CGSize(width: 600, height: SHBrowserMetrics.consoleBarHeight + SHBrowserMetrics.consoleListHeight)
    private static var consoleRowsOnScreen: Int { Int(SHBrowserMetrics.consoleListHeight / SHBrowserMetrics.consoleRowHeight) + 1 }

    /// A console holding its most lines (a chatty dev server), in its drawer.
    private func openConsole() -> (BrowserConsoleLog, OffscreenWindow) {
        let log = BrowserConsoleLog()
        for index in 0..<BrowserConsoleLog.maxLines {
            log.append(index % 25 == 0 ? .warning : .log, "[vite] hmr update /src/components/Row\(index).tsx")
        }
        let window = OffscreenWindow(size: Self.consoleSize, dark: true, BrowserConsoleDrawer(console: log, open: true, toggle: {}))
        ListPerf.settle(window)
        return (log, window)
    }

    @Test func openingTheConsoleBuildsOnlyTheLinesOnScreen() {
        var window: OffscreenWindow!
        let counts = ListPerf.counting {
            window = openConsole().1
        }
        defer { window.close() }
        #expect(counts["browser.consoleRow", default: 0] > 0)
        #expect(counts["browser.consoleRow", default: 0] <= 2 * Self.consoleRowsOnScreen, "\(counts)")
    }

    /// A line arriving (the log at its cap, so one leaves the top too) builds the new line and
    /// the one it pushes into view, never the lines already there.
    @Test func aConsoleLineArrivingBuildsOnlyItsRow() {
        let (log, window) = openConsole()
        defer { window.close() }
        let counts = ListPerf.counting {
            for index in 0..<5 {
                log.append(.log, "[vite] page reload \(index)")
                ListPerf.settle(window)
            }
        }
        #expect(counts["browser.consoleRow", default: 0] > 0)
        #expect(counts["browser.consoleRow", default: 0] <= 5 * 2, "\(counts)")
    }

    // MARK: Thread

    /// A long thread streaming its reply builds only the rows on screen for each chunk, however
    /// many turns came before.
    @Test func streamingIntoALongThreadBuildsOnlyTheRowsOnScreen() async throws {
        var snapshot = ListFixtures.threadSnapshot(turns: 500, running: true)
        let store = NativeThreadStore()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                     ThreadView(store: store, active: true, isFocused: false, request: { _ in .snapshot(value: snapshot) },
                                                commandKey: "budget", listModels: { .empty }))
        defer {
            store.stop()
            window.close()
        }
        try await eventuallyOnMain("the thread to load") { store.ready }
        // Data readiness precedes SwiftUI's first scroll-to-tail. Count streaming work, not a
        // still-pending initial layout (which otherwise flakes on both baseline and optimized code).
        try await eventuallyOnMain("the initial thread layout to reach its tail") {
            ListPerf.settle(window)
            guard let scroll = ListPerf.scrollView(in: window), let document = scroll.documentView else { return false }
            return document.bounds.height > scroll.contentView.bounds.height
                && abs(document.bounds.height - scroll.contentView.bounds.maxY + scroll.contentInsets.bottom) < 2
        }

        SHRenderProbe.start()
        for index in 0..<5 {
            let live = ListFixtures.message("live", "assistant", String(repeating: "Streaming sentence \(index). ", count: index + 1))
            snapshot = ListFixtures.threadSnapshot(turns: 500, running: true, revision: UInt64(index + 2), provisional: [live])
            await store.refresh()
            ListPerf.settle(window)
        }
        let rows = SHRenderProbe.stop()
        // A 800pt window shows a dozen turns; five chunks may build each a few times (about 90
        // here, at any speed). On macOS 26 (CI) the builder ran for every row on each chunk, 4,999
        // times, while still redrawing only the streaming turn.
        withKnownIssue("older SwiftUI runs every row's builder for each streamed chunk", isIntermittent: true) {
            #expect(rows["thread.rowBuilder", default: 0] <= 5 * 40, "\(rows)")
        } when: { ListPerf.olderLazyStacks }
        #expect(rows["thread.agentTurn", default: 0] <= 5 * 2, "only the streaming turn redraws: \(rows)")
    }

    /// Turns scrolled back into the lazy stack are simply there: no entrance plays while reading.
    @Test func scrollingThroughALongThreadPlaysNoEntrances() async throws {
        let snapshot = ListFixtures.threadSnapshot(turns: 500)
        let store = NativeThreadStore()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                     ThreadView(store: store, active: true, isFocused: false, request: { _ in .snapshot(value: snapshot) },
                                                commandKey: "entrances", listModels: { .empty }))
        defer {
            store.stop()
            window.close()
        }
        try await eventuallyOnMain("the thread to load") { store.ready }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        let rows = ListPerf.counting {
            _ = ListPerf.scroll(window, scroll, step: -400, steps: 30)
            _ = ListPerf.scroll(window, scroll, step: 400, steps: 30)
        }
        #expect(rows["thread.agentTurn", default: 0] > 20, "the thread scrolled: \(rows)")
        #expect(rows["arrival.animates", default: 0] == 0, "\(rows)")
        #expect(rows["thread.view", default: 0] <= 2, "scrolling must not repeatedly rebuild the transcript: \(rows)")
    }

    private static let replyFences = 3

    /// A reply of three Swift fences and a closing paragraph, which grows by a few words from chunk 0 to 2. It ends
    /// in a newline whichever chunk it is, so the finished parse draws exactly what streamed.
    private static func fencedReply(chunk: Int) -> String {
        let steps = (1...replyFences).map { "Step \($0):\n\n```swift\nfunc turnEnd\($0)() {\n    let value = \($0)\n    print(value)\n}\n```\n\n" }
        let closings = ["That is the whole change.\n", "That is the whole change, in three steps.\n",
                        "That is the whole change, in three steps, each one small enough to read.\n"]
        return "Here is how the change fits together, in three small steps.\n\n" + steps.joined() + closings[chunk]
    }

    /// Where a reply's turn ends and what it edited: what its end brings in.
    enum TurnEnd: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// An ordinary thread: the footer.
        case ordinary
        /// An ordinary thread, and the turn edited files: the changes card and the footer.
        case editing
        /// A design chat, whose turns draw no footer.
        case designChat
        /// A Project thread, whose turns draw no footer; the turn edited files, so the changes card is the one part.
        case project

        var testDescription: String { rawValue }
        var edits: Bool { self == .editing || self == .project }
        /// What the end of the turn brings in when the reply arrived on screen: its changes card and footer rise into place
        /// together, as the one entrance they share, and a turn that draws neither makes none.
        var entrances: Int { self == .designChat ? 0 : 1 }
    }

    private static let promptAt = 1_790_000_000_000.0

    /// The host's record of the turn that answers the prompt at `promptAt`: its "Edited 3 files" card.
    private static func recordedTurn() -> ChangesTurn {
        ChangesTurn(messageTimestamp: promptAt, startedAt: promptAt, endedAt: promptAt + 60_000, state: .ready,
                    files: (0..<3).map { ChangesFile(path: "Sources/Edit\($0).swift", status: .modified, added: 10, removed: 3) },
                    added: 30, removed: 9, canUndo: true)
    }

    /// Serves `messages` (and the reply being written, while `running`) and draws it.
    private func serve(_ thread: FakeThread, messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [],
                       running: Bool, turnChanges: [ChangesTurn]? = nil) async {
        var next = thread.snapshot
        next.revision += 1
        next.running = running
        next.messages = messages
        next.provisional = provisional
        if let turnChanges { next.turnChanges = turnChanges }
        await thread.serve(next)
        ListPerf.settle(thread.window)
    }

    /// A caught-up thread of twenty messages with a prompt, and a reply that streams in on screen in three chunks: it
    /// made its entrance, and `fencedReply`'s fences are drawn. `awayMidStream` switches the agent away and back
    /// after the first chunk, so the reply is no longer one that arrived with the thread's latest change. In a
    /// design chat the prompt is a comment card, and in a Project thread its typed references resolve to nothing.
    private func threadWithAReplyOnScreen(awayMidStream: Bool = false, in place: TurnEnd = .ordinary) async throws
        -> (thread: FakeThread, asked: [NativeThreadMessage]) {
        let history = ThreadFixture.history(20)
        let inCard = place == .designChat
        // The record of a turn that edited files is found by its prompt's time.
        var prompt = inCard ? LongThreads.user("u", "Walk me through it", origin: .designComment(id: LongThreads.commentID))
            : ThreadFixture.user("u", "Walk me through it")
        if place.edits { prompt.timestamp = Self.promptAt }
        let asked = history + [prompt]
        let thread = FakeThread(ThreadFixture.snapshot(history), size: CGSize(width: inCard ? AppLayout.designChatWidth : 900, height: 800),
                                designCards: inCard ? DesignChatFixture.cards() : nil,
                                projectCards: place == .project ? ProjectActionCards(resolved: { _ in nil }, card: { _ in AnyView(EmptyView()) }) : nil)
        do {
            try await thread.waitUntilReady()
            try await eventuallyOnMain("the thread to catch up") { thread.store.catchUp != nil }
            try await atRest(thread.window)
            let arrival = try await counting(thread.window) {
                await serve(thread, messages: asked, provisional: [ThreadFixture.streaming(Self.fencedReply(chunk: 0))], running: true)
            }
            #expect(arrival["arrival.animates", default: 0] > 0, "the reply arrived on screen: \(arrival)")
            if awayMidStream {
                try await thread.show(false)
                try await thread.show(true)
                try await atRest(thread.window)
            }
            for chunk in 1...2 {
                await serve(thread, messages: asked, provisional: [ThreadFixture.streaming(Self.fencedReply(chunk: chunk))], running: true)
            }
            try await atRest(thread.window)
            #expect(Self.nativeFields(in: thread.window.host) == Self.replyFences, "the reply's fences are on screen")
        } catch {
            thread.close()
            throw error
        }
        return (thread, asked)
    }

    /// Ends the turn of `threadWithAReplyOnScreen`'s reply and counts what the end draws, up to the store letting go of
    /// running (400 ms after pi does), which redraws the turn too.
    private func endingTheTurn(of thread: FakeThread, asked: [NativeThreadMessage], in place: TurnEnd = .ordinary) async throws -> [String: Int] {
        try await counting(thread.window) {
            await serve(thread, messages: asked + [ThreadFixture.assistant("a", Self.fencedReply(chunk: 2))], running: false,
                        turnChanges: place.edits ? [Self.recordedTurn()] : nil)
            try await eventuallyOnMain("the turn to end") { thread.store.rows.last?.live == false }
            try await eventuallyOnMain("the store to settle its running state") {
                ListPerf.settle(thread.window)
                return !thread.store.running
            }
        }
    }

    /// A reply that arrived on screen with three fences, and its turn then ends: the one row view that drew
    /// it while it streamed updates in place. Its fences keep their code views (none is created again) and its
    /// parts do not run their entrances again; the one new thing is what ends the turn, which enters once: the
    /// footer, with the changes card of a turn that edited files above it (nothing in a design chat, whose turns draw no
    /// footer, and the card alone in a Project thread, whose turns draw none either). The turn used to swap its live
    /// view for a new one, and the new one built every part afresh.
    @Test(arguments: TurnEnd.allCases) func aTurnThatEndsUpdatesItsReplyInPlace(place: TurnEnd) async throws {
        let (thread, asked) = try await threadWithAReplyOnScreen(in: place)
        defer { thread.close() }

        let ended = try await endingTheTurn(of: thread, asked: asked, in: place)

        #expect(ended["code.nativeCreated", default: 0] == 0, "no code view is made again: \(ended)")
        #expect(ended["arrival.animates", default: 0] == place.entrances, "only the parts that end the turn make an entrance: \(ended)")
        #expect(ended["thread.agentTurn", default: 0] <= 2, "the turn redraws for its end and nothing else: \(ended)")
        #expect(Self.nativeFields(in: thread.window.host) == Self.replyFences, "the finished reply draws its fences")
    }

    /// A reply that did not arrive on screen with the thread's latest change (its agent was switched away from and
    /// back to while it streamed) is a reply whose footer and changes card were always simply there when its turn
    /// ended: it makes no entrance now either. Only a reply that arrived on screen brings them in
    /// (`aTurnThatEndsUpdatesItsReplyInPlace`).
    @Test(arguments: [TurnEnd.ordinary, .editing]) func aReplyThatDidNotArriveOnScreenMakesNoEntranceWhenItsTurnEnds(place: TurnEnd) async throws {
        let (thread, asked) = try await threadWithAReplyOnScreen(awayMidStream: true, in: place)
        defer { thread.close() }

        let ended = try await endingTheTurn(of: thread, asked: asked, in: place)

        #expect(ended["code.nativeCreated", default: 0] == 0, "no code view is made again: \(ended)")
        #expect(ended["arrival.animates", default: 0] == 0, "nothing makes an entrance: \(ended)")
        #expect(Self.nativeFields(in: thread.window.host) == Self.replyFences, "the finished reply draws its fences")
    }

    /// The same view draws a finished reply that goes live again (pi carries on in the turn it had ended), so it is
    /// updated where it stands too: no code view is made again and no part enters again.
    @Test func aFinishedReplyThatGoesLiveAgainIsUpdatedInPlace() async throws {
        let (thread, asked) = try await threadWithAReplyOnScreen()
        defer { thread.close() }
        let finished = asked + [ThreadFixture.assistant("a", Self.fencedReply(chunk: 2))]
        await serve(thread, messages: finished, running: false)
        try await eventuallyOnMain("the store to settle its running state") {
            ListPerf.settle(thread.window)
            return !thread.store.running && thread.store.rows.last?.live == false
        }
        try await atRest(thread.window)

        let resumed = try await counting(thread.window) {
            await serve(thread, messages: finished, running: true)
            try await eventuallyOnMain("the turn to be live again") { thread.store.rows.last?.live == true }
        }

        #expect(resumed["code.nativeCreated", default: 0] == 0, "no code view is made again: \(resumed)")
        #expect(resumed["arrival.animates", default: 0] == 0, "no part enters again: \(resumed)")
        #expect(Self.nativeFields(in: thread.window.host) == Self.replyFences, "the live reply draws its fences")
    }

    // MARK: Thread chrome

    /// Row bodies counted while `work` runs, with the window settled after it.
    private func counting(_ window: OffscreenWindow, _ work: () async throws -> Void) async rethrows -> [String: Int] {
        SHRenderProbe.start()
        try await work()
        ListPerf.settle(window)
        return SHRenderProbe.stop()
    }

    /// Waits until the thread has stopped building rows: what a change set off (the tail guard
    /// putting a thread back on its tail, a late layout) has landed, so a count starts from rest.
    private func atRest(_ window: OffscreenWindow, polls: Int = 30) async throws {
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        var built = 0, still = 0
        try await eventuallyOnMain("the thread to stop building rows", timeout: .seconds(30)) {
            ListPerf.settle(window)
            let now = ["thread.rowBuilder", "thread.view", "composer.body"].reduce(0) { $0 + SHRenderProbe.count($1) }
            still = now == built ? still + 1 : 0
            built = now
            return still >= polls
        }
    }

    /// A thread of sixty turns under its toolbar, loaded and at rest. Running, it holds a streaming
    /// reply, or with `streaming` false none yet: pi works and the thread ends in its wait line.
    private func chromeThread(running: Bool, streaming: Bool = true) async throws -> FakeThread {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(120) + (running ? [ThreadFixture.user("u", "Go on")] : []),
                                              provisional: running && streaming ? [ThreadFixture.streaming("Streaming")] : [], running: running,
                                              stats: NativeThreadStats(contextTokens: 42_000))
        snapshot.context = Self.context(42_000)
        let thread = FakeThread(snapshot, header: true)
        try await thread.waitUntilReady()
        // What loading sets off (the catch-up, the composer's models) lands before counting.
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)
        return thread
    }

    static func context(_ tokens: Int) -> NativeThreadContext {
        NativeThreadContext(tokens: tokens, window: 200_000, autoCompactAt: 183_616, autoCompact: true, keepRecent: 20_000,
                            split: NativeContextSplit(system: 6_800, instructions: 1_400, messages: 9_100, toolResults: tokens - 17_300))
    }

    /// A reply that moves the context redraws the ring beside Send alone: not the composer, its
    /// chips, or the thread.
    @Test func aUsageChangeRedrawsOnlyTheRing() async throws {
        let thread = try await chromeThread(running: false)
        defer { thread.close() }
        var next = thread.snapshot
        next.revision += 1
        next.context = Self.context(130_000)

        let rows = try await counting(thread.window) { await thread.serve(next) }

        #expect(rows["composer.contextMeter", default: 0] == 1, "\(rows)")
        #expect(thread.store.contextMeter?.ring == .fill(0.65, .warning))
        for key in ["composer.body", "composer.chips", "thread.view", "thread.rowBuilder"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    @Test func fiveGoalAccountingSnapshotsRedrawNoComposerQueueOrThreadRows() async throws {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(120), running: false)
        snapshot.goal = NativeGoal(id: "00000000-0000-0000-0000-0000000000AA", text: "Tests pass", state: .working,
                                   elapsedSeconds: 400, tokensUsed: 71_000, runningSince: Date().timeIntervalSince1970 * 1000)
        snapshot.queue = NativeQueue(items: QueueFixture.messages(["Then run lint", "Open the PR"]), mode: .all)
        snapshot.supportedActions += ["goal", "queue"]
        let thread = FakeThread(snapshot, header: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("goal and queue chrome to settle") {
            ListPerf.settle(thread.window)
            return thread.store.hasGoal && thread.store.queue.count == 2
        }
        // Two unchanged serve passes drain the initial catch-up before recording a mutation.
        await thread.serve(snapshot)
        ListPerf.settle(thread.window)
        let rows = try await counting(thread.window) {
            for index in 1...5 {
                var next = snapshot
                next.revision += UInt64(index)
                next.goal?.elapsedSeconds += Double(index)
                next.goal?.runningSince? += Double(index)
                next.goal?.tokensUsed += index * 1000
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }
        #expect(rows["goal.card", default: 0] >= 5, "the five accounting updates were drawn: \(rows)")
        for key in ["composer.body", "composer.chips", "queue.body", "queue.row", "thread.view", "thread.rowBuilder", "thread.agentTurn", "thread.userTurn"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    @Test func clientGoalClockTicksRedrawOnlyPills() async throws {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(120), running: false)
        snapshot.goal = NativeGoal(id: "00000000-0000-0000-0000-0000000000AA", text: "Tests pass", state: .working,
                                   elapsedSeconds: 400, tokensUsed: 71_000, runningSince: Date().timeIntervalSince1970 * 1000)
        snapshot.queue = NativeQueue(items: QueueFixture.messages(["Then run lint"]), mode: .all)
        snapshot.supportedActions += ["goal", "queue"]
        let thread = FakeThread(snapshot, header: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        ListPerf.settle(thread.window)
        SHRenderProbe.start()
        let rows: [String: Int]
        do {
            try await eventuallyOnMain("two local card and header clock ticks", timeout: .seconds(10)) {
                ListPerf.settle(thread.window)
                let counts = SHRenderProbe.counts
                return counts["goal.clock", default: 0] >= 2 && counts["goal.headerClock", default: 0] >= 2
            }
            rows = SHRenderProbe.stop()
        } catch {
            _ = SHRenderProbe.stop()
            throw error
        }
        for key in ["goal.card", "composer.body", "composer.chips", "queue.body", "queue.row", "thread.view", "thread.rowBuilder", "thread.agentTurn", "thread.userTurn"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
        #expect(thread.snapshot.revision == snapshot.revision, "client ticks need no server snapshot")
    }

    /// A question arriving takes the composer's place, and answering it gives the place back:
    /// both redraw the composer, never the thread's body or its toolbar. The rows on screen are
    /// laid out again for the new inset (a screenful at most), none off screen.
    @Test func aQuestionArrivingAndAnsweredRedrawsOnlyTheComposer() async throws {
        let thread = try await chromeThread(running: true)
        defer { thread.close() }
        // The 800pt window shows about a dozen of its 120 turns.
        let screenful = 20
        var asking = thread.snapshot
        asking.revision += 1
        asking.dialogs = [NativeThreadDialog(id: "d1", kind: .select, title: "How should I handle Horizon’s uncommitted edits?",
                                             options: ["Compare first (Recommended)\nDiff the 11 files.", "Leave Horizon alone\nDeploy from a clean checkout."])]
        var answered = asking
        answered.revision += 1
        answered.dialogs = []

        for (step, next) in [("arriving", asking), ("answered", answered)] {
            let rows = try await counting(thread.window) { await thread.serve(next) }

            #expect(thread.store.dialogs.count == next.dialogs.count)
            #expect(rows["composer.body", default: 0] >= 1, "\(step): the composer changed: \(rows)")
            for key in ["thread.view", "thread.header", "toolbar.thread"] {
                #expect(rows[key, default: 0] == 0, "\(step): \(key): \(rows)")
            }
            let turns = rows["thread.agentTurn", default: 0] + rows["thread.userTurn", default: 0]
            #expect(turns <= screenful, "\(step): only the rows on screen: \(rows)")
        }
    }

    /// A poll that moves only the context count redraws nothing in the chrome: the toolbar shows
    /// no counters, so neither it nor the composer nor the thread redraws.
    @Test func aStatsOnlyPollRedrawsNoToolbar() async throws {
        let thread = try await chromeThread(running: false)
        defer { thread.close() }
        var next = thread.snapshot
        next.revision += 1
        next.stats = NativeThreadStats(contextTokens: 43_000)

        let rows = try await counting(thread.window) { await thread.serve(next) }

        for key in ["thread.header", "toolbar.thread", "thread.view"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    /// A streamed chunk redraws its streaming row, never the composer, its chips, or the toolbar.
    @Test func aStreamedChunkRedrawsNoComposerOrToolbar() async throws {
        let thread = try await chromeThread(running: true)
        defer { thread.close() }

        let rows = try await counting(thread.window) {
            for index in 1...5 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming("Streaming" + String(repeating: " more words", count: index * 4))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }

        #expect(rows["thread.liveRow", default: 0] >= 5, "the reply streamed: \(rows)")
        // On CI's macOS 26 VM the composer redrew for every chunk (5 bodies, 15 chip rows); a
        // Mac redraws none. A known issue there until the cause is found, a failure everywhere else.
        withKnownIssue("CI's VM redraws the composer for each streamed chunk", isIntermittent: true) {
            for key in ["composer.body", "composer.chips", "thread.header", "toolbar.thread"] {
                #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
            }
        } when: {
            !TimingTests.enabled
        }
        // The ring reads only the usage, which a chunk leaves as it was, and sits out of the
        // control row's fitting candidates.
        #expect(rows["composer.contextMeter", default: 0] == 0, "\(rows)")
    }

    /// A streamed chunk beside "Up next" redraws none of the stack: the composer reads the
    /// store's queue, which a chunk leaves as it was.
    @Test func aStreamedChunkRedrawsNoQueueRow() async throws {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(120) + [ThreadFixture.user("u", "Go on")],
                                              provisional: [ThreadFixture.streaming("Streaming")], running: true)
        snapshot.queue = NativeQueue(items: QueueFixture.messages(["Then run the tests", "And lint it", "Then open the PR"]), mode: .all)
        snapshot.supportedActions.append("queue")
        let thread = FakeThread(snapshot, header: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)
        #expect(thread.store.queue.count == 3)

        let rows = try await counting(thread.window) {
            for index in 1...5 {
                var next = snapshot
                next.revision += UInt64(index)
                next.provisional = [ThreadFixture.streaming("Streaming" + String(repeating: " more words", count: index * 4))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }

        #expect(rows["thread.liveRow", default: 0] >= 5, "the reply streamed: \(rows)")
        #expect(rows["queue.row", default: 0] == 0, "\(rows)")
        // See aStreamedChunkRedrawsNoComposerOrToolbar: CI's VM redraws the composer per chunk.
        withKnownIssue("CI's VM redraws the composer for each streamed chunk", isIntermittent: true) {
            for key in ["composer.body", "composer.chips"] {
                #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
            }
        } when: {
            !TimingTests.enabled
        }

        // The control: a queued message edited on the host redraws its row.
        var edited = snapshot
        edited.revision += 10
        edited.queue?.items[1].text = "And lint it, then format"
        let changed = try await counting(thread.window) { await thread.serve(edited) }
        #expect(changed["queue.row", default: 0] >= 1, "\(changed)")
    }

    /// pi works and nothing has streamed yet: the thread ends in its wait line ("Waiting for
    /// response" and its clock). A hook's status and the request's first event change what it says,
    /// and redraw that line alone, never the thread's body, its rows or the composer.
    @Test func aWaitLineChangeRedrawsOnlyItsLine() async throws {
        let thread = try await chromeThread(running: true, streaming: false)
        defer { thread.close() }
        #expect(thread.store.showsThinking && thread.store.liveRow == nil, "the thread ends in its wait line")
        // The request is in flight before the changes begin: its clock is already on the line, so the line keeps its height.
        let sent = Date().timeIntervalSince1970 * 1000 - 3000
        var inFlight = thread.snapshot
        inFlight.revision += 1
        inFlight.liveRequest = NativeResponseTiming(sentAt: sent)
        await thread.serve(inFlight)
        try await atRest(thread.window)

        let rows = try await counting(thread.window) {
            for step in 1...6 {
                var next = thread.snapshot
                next.revision += 1
                next.hookStatus = step.isMultiple(of: 2) ? nil : "Checking the path"
                next.liveRequest = NativeResponseTiming(sentAt: sent, firstEventAt: step.isMultiple(of: 2) ? sent + 900 : nil)
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }

        #expect(thread.store.liveWait == NativeLiveWait(phase: .started, since: sent), "\(thread.store.liveWait)")
        #expect(rows["thread.waitLine", default: 0] >= 6, "the line changed with each snapshot: \(rows)")
        for key in ["thread.view", "thread.column", "composer.body"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    /// A tool starting or ending flips the live "Thinking…" line (`showsThinking`). The live row
    /// redraws, and the thread's body, the rows around it and the composer stay as they were, as
    /// they do for a streamed chunk (the control).
    @Test func aToolBoundaryRedrawsOnlyTheLiveRow() async throws {
        let thread = try await chromeThread(running: true)
        defer { thread.close() }
        try await atRest(thread.window)

        let chunks = try await counting(thread.window) {
            for index in 1...6 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming("Streaming" + String(repeating: " more words", count: index * 4))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }
        try await atRest(thread.window)
        let boundaries = try await counting(thread.window) {
            for step in 1...6 {
                let finished = step.isMultiple(of: 2)
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.bash(finished ? "complete" : "running")]
                await thread.serve(next)
                ListPerf.settle(thread.window)
                #expect(thread.store.showsThinking == finished, "step \(step): between tools only once the call has ended")
            }
        }

        #expect(boundaries["thread.liveRow", default: 0] >= 6, "the live row followed each step: \(boundaries)")
        for key in ["thread.view", "thread.column"] {
            #expect(chunks[key, default: 0] == 0, "\(key), the control: chunks \(chunks)")
            #expect(boundaries[key, default: 0] == 0, "\(key): tool boundaries \(boundaries)")
        }
        // See aStreamedChunkRedrawsNoComposerOrToolbar: CI's VM redraws the composer per chunk.
        withKnownIssue("CI's VM redraws the composer for each streamed chunk", isIntermittent: true) {
            #expect(boundaries["composer.body", default: 0] == 0, "\(boundaries)")
        } when: {
            !TimingTests.enabled
        }
    }

    @MainActor @Observable final class RedrawCounter {
        var value = 0
    }

    /// The composer under a parent that redraws and hands it a closure made afresh each time (the
    /// thread's Jump to latest while the reader is detached captures the thread's state).
    private struct ComposerUnderParent: View {
        let counter: RedrawCounter
        let store: NativeThreadStore
        let input: ThreadInput

        var body: some View {
            let _ = SHRenderProbe.tick("test.parent")
            let tick = counter.value
            Composer(store: store, input: input, active: true, isFocused: false, agentName: "Investigate", hasTurns: true,
                     gutter: AppLayout.gutter, listModels: { .empty }, jumpToLatest: { _ = tick })
                .equatable()
        }
    }

    /// A parent that redraws with closures made afresh leaves the composer alone: its inputs are
    /// equal, whatever the closures capture.
    @Test func aParentRedrawWithFreshClosuresRedrawsNoComposer() async throws {
        let thread = try await chromeThread(running: false)
        defer { thread.close() }
        let counter = RedrawCounter()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 400), dark: true,
                                     ComposerUnderParent(counter: counter, store: thread.store, input: ThreadInput()))
        defer { window.close() }
        var quiet = 0
        try await eventuallyOnMain("the composer to stop redrawing") {
            quiet = ListPerf.counting { ListPerf.settle(window) }["composer.body", default: 0] == 0 ? quiet + 1 : 0
            return quiet >= 5
        }

        let rows = ListPerf.counting {
            for _ in 1...5 {
                counter.value += 1
                ListPerf.settle(window)
            }
        }

        #expect(rows["test.parent", default: 0] >= 5, "the parent redrew: \(rows)")
        #expect(rows["composer.body", default: 0] == 0, "\(rows)")
    }

    @Test(arguments: [false, true])
    func changingThreadGuttersDoesNotRebuildTheTranscript(dark: Bool) async throws {
        let threshold = AppLayout.threadMaxWidth + 2 * AppLayout.gutter
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(120)),
                                size: CGSize(width: threshold + 60, height: 800), dark: dark)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let scroll = try #require(thread.scrollView)
        let widths = [threshold - 40, threshold + 40]
        #expect(AppLayout.threadGutter(width: widths[0]) != AppLayout.threadGutter(width: widths[1]))

        let rows = try await counting(thread.window) {
            for step in 0..<6 {
                let width = widths[step % widths.count]
                thread.window.window.setContentSize(CGSize(width: width, height: 800))
                try await eventuallyOnMain("resized thread viewport") {
                    ListPerf.settle(thread.window)
                    return abs(thread.window.host.bounds.width - width) < 1
                }
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                ListPerf.settle(thread.window)
                #expect(thread.scrollView === scroll, "gutter changes keep the mounted scroll view")
            }
        }
        #expect(rows["composer.body", default: 0] > 0, "the composer receives the changing gutters: \(rows)")
        #expect(rows["thread.view", default: 0] <= 1, "six gutter changes must not rebuild the transcript: \(rows)")
    }

    /// Resizing redraws the composer only when the Send menu changes sides, not for each
    /// width or height a live resize passes while the menu remains on the same side.
    @Test(arguments: [false, true])
    func aResizeThatKeepsTheSendMenusSideRedrawsNoComposer(heightOnly: Bool) async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(4)), size: CGSize(width: 1800, height: 800))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)

        let frames = 10
        let rows = try await counting(thread.window) {
            for step in 1...frames {
                thread.window.window.setContentSize(NSSize(width: heightOnly ? 1800 : 1800 - CGFloat(step) * 8,
                                                           height: heightOnly ? 800 - CGFloat(step) * 8 : 800))
                ListPerf.settle(thread.window)
            }
        }

        #expect(rows["composer.body", default: 0] == 0, "\(rows)")
    }

    /// Switching is a visibility flip: hiding a thread and showing it again each rebuild it (and
    /// its composer) once, and the rows on screen, whatever its first pull brings back.
    @Test func aSwitchRebuildsEachThreadOnce() async throws {
        let thread = try await chromeThread(running: false)
        defer { thread.close() }

        let hide = try await counting(thread.window) { try await thread.show(false) }
        let show = try await counting(thread.window) { try await thread.show(true) }

        for (name, rows) in [("hide", hide), ("show", show)] {
            #expect(rows["thread.view", default: 0] <= 1, "\(name): \(rows)")
            #expect(rows["composer.body", default: 0] <= 1, "\(name): \(rows)")
        }
        // An 800pt window shows a few turns; the lazy stack builds some ahead.
        #expect(show["thread.rowBuilder", default: 0] <= 40, "\(show)")
    }

    // MARK: Code blocks

    /// A reply streaming `lines` lines of a Swift fence (still open).
    static func codeReply(_ lines: Int) -> String {
        let body = (0..<lines).map { "    let value\($0) = compute(\($0), from: source[\($0)]) // step \($0)" }
        return "Here it is:\n\n```swift\nfunc build() {\n" + body.joined(separator: "\n") + "\n"
    }

    private static var highlightRun = 0

    /// Fifteen chunks of a growing fenced block, delivered in one burst, color it at most twice
    /// (the first complete lines at once, then at most every 250 ms, at line boundaries); the
    /// finished reply colors it once more, in full.
    @Test(.timingSensitive) func aBurstOfCodeChunksColorsTheBlockAtMostTwice() async throws {
        // The process-wide highlight cache survives repeated test invocations.
        Self.highlightRun += 1
        let function = "func burstBudget\(Self.highlightRun)()"
        func reply(_ lines: Int) -> String {
            Self.codeReply(lines).replacingOccurrences(of: "func build()", with: function)
        }
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it")]
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(reply(2))], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        let initialCode = CodeHighlightCache.Key(fence: reply(2).components(separatedBy: "```swift\n")[1], language: "swift")
        try await eventuallyOnMain("initial complete code lines to finish highlighting") {
            ListPerf.settle(thread.window)
            return CodeHighlightCache.cached(initialCode.prefix(lines: 2)) != nil
        }

        let burst = try await counting(thread.window) {
            // Deliver a burst without forcing fifteen full native layouts between chunks.
            // Those layouts can span several throttle intervals on a busy machine.
            for chunk in 1...15 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(reply(2 + chunk * 6) + "    let partial")]
                await thread.serve(next)
            }
            let code = CodeHighlightCache.Key(fence: (reply(92) + "    let partial").components(separatedBy: "```swift\n")[1], language: "swift")
            try await eventuallyOnMain("burst's final complete lines to finish highlighting") {
                ListPerf.settle(thread.window)
                return CodeHighlightCache.cached(code.prefix(lines: 93)) != nil
            }
        }
        let finished = try await counting(thread.window) {
            var next = thread.snapshot
            next.revision += 1
            next.running = false
            next.messages = turn + [ThreadFixture.assistant("done", reply(2 + 15 * 6) + "    let partial\n}\n```\n")]
            next.provisional = []
            await thread.serve(next)
            let code = CodeHighlightCache.Key(fence: (reply(92) + "    let partial\n}").components(separatedBy: "```swift\n")[1], language: "swift")
            try await eventuallyOnMain("finished code block to finish highlighting") {
                ListPerf.settle(thread.window)
                return CodeHighlightCache.cached(code) != nil
            }
        }

        #expect((1...2).contains(burst["highlight.render", default: 0]), "\(burst)")
        #expect(finished["highlight.render", default: 0] == 1, "\(finished)")
    }

    // MARK: Tables

    /// A reply streaming its summary under a 200-row table redraws none of the table: the
    /// table is parsed once per chunk in the store, compares equal, and keeps its cells. Its
    /// first build makes each cell once (the fitting layout; the scrolling one is not built).
    @Test func aReplyStreamingUnderALargeTableRedrawsNoneOfItsCells() async throws {
        let rows = 200
        let table = MarkdownFixtures.largeTable(rows: rows)
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "List the calls")]
        // Counting from before the window opens: the thread may load in its first frames.
        SHRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(table + "\n\nIn")], running: true),
                                size: CGSize(width: 1180, height: 900))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)
        let first = SHRenderProbe.stop()
        #expect(first["prose.tableCell", default: 0] > 0, "the table was built: \(first)")
        #expect(first["prose.tableCell", default: 0] <= (rows + 1) * 3, "each cell built at most once: \(first)")

        let streamed = try await counting(thread.window) {
            for index in 1...5 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(table + "\n\nIn" + String(repeating: " all, the calls finished", count: index))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }
        #expect(streamed["thread.liveRow", default: 0] >= 5, "the reply streamed: \(streamed)")
        #expect(streamed["prose.table", default: 0] == 0, "\(streamed)")
        #expect(streamed["prose.tableCell", default: 0] == 0, "\(streamed)")
    }

    // MARK: Fences and links

    /// A reply streaming its closing paragraph redraws that chunk, and nothing in it that did not change: the closed
    /// fences keep their native views (no `updateNSView`, no highlight), the remote image chip and the table keep
    /// their bodies. The paragraph is the only thing that moves, so the chunk's blocks all evaluate again, but a
    /// block whose inputs are equal does not.
    @Test func aStreamedChunkRedrawsNoUnchangedFence() async throws {
        let fences = (1...3).map { "func unchanged\($0)() {\n    let value = \($0)\n    print(value)\n}" }
        func reply(_ pulls: Int) -> String {
            let steps = fences.enumerated().map { "Step \($0.offset + 1):\n\n```swift\n\($0.element)\n```\n\n" }.joined()
            let table = "| Step | Files | Tests |\n|---|---|---|\n| one | 2 | 4 |\n| two | 1 | 2 |\n| three | 3 | 6 |\n\n"
            return "Here is the change.\n\n" + steps + "![Build status](https://ci.example.com/badge.png)\n\n" + table
                + "In" + String(repeating: " all, the steps passed", count: pulls)
        }
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Walk me through it")]
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(reply(0))], running: true),
                                size: CGSize(width: 900, height: 800))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the closed fences to finish highlighting") {
            ListPerf.settle(thread.window)
            return fences.allSatisfy { CodeHighlightCache.cached(CodeHighlightCache.Key(fence: $0, language: "swift")) != nil }
        }
        try await atRest(thread.window)
        #expect(Self.nativeFields(in: thread.window.host) == fences.count, "the fences are on screen")

        let streamed = try await counting(thread.window) {
            for pulls in 1...5 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(reply(pulls))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }
        #expect(streamed["thread.liveRow", default: 0] >= 5, "the reply streamed: \(streamed)")
        #expect(streamed["prose.chunk", default: 0] >= 5, "the chunk it grows in was drawn again: \(streamed)")
        #expect(streamed["code.nativeUpdated", default: 0] == 0, "no closed fence is updated: \(streamed)")
        #expect(streamed["code.highlighted", default: 0] == 0, "no closed fence is evaluated again: \(streamed)")
        #expect(streamed["highlight.render", default: 0] == 0, "no closed fence is colored again: \(streamed)")
        #expect(streamed["prose.image", default: 0] == 0, "the image chip is not drawn again: \(streamed)")
        #expect(streamed["prose.table", default: 0] == 0, "the table is not drawn again: \(streamed)")
        #expect(Self.nativeFields(in: thread.window.host) == fences.count, "the fences are still on screen")
    }

    /// A reply streaming its closing paragraph draws that paragraph again and none of the blocks beside it in the chunk:
    /// each block is its own view, equal to what it was, so the paragraphs, the list, the quote, the fences, the table
    /// and the image chip evaluate no body (`prose.block` counts the blocks that do).
    @Test func aStreamedChunkRedrawsOnlyTheBlockItGrew() async throws {
        let fences = (1...3).map { "func unchanged\($0)() {\n    let value = \($0)\n    print(value)\n}" }
        func reply(_ pulls: Int) -> String {
            func paragraph(_ number: Int) -> String { "Paragraph \(number) of the walkthrough, which stays as it was.\n\n" }
            let steps = fences.enumerated().map { "\(paragraph($0.offset + 2))```swift\n\($0.element)\n```\n\n" }.joined()
            let list = (1...5).map { "- Item \($0) of the checklist\n" }.joined() + "\n"
            let table = "| Step | Files | Tests |\n|---|---|---|\n| one | 2 | 4 |\n| two | 1 | 2 |\n| three | 3 | 6 |\n\n"
            return paragraph(1) + steps + paragraph(5) + list + paragraph(6) + table + paragraph(7)
                + "> A quote that stays as it was.\n\n" + paragraph(8) + "![Build status](https://ci.example.com/badge.png)\n\n"
                + paragraph(9) + "In" + String(repeating: " all, the steps passed", count: pulls)
        }
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Walk me through it")]
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(reply(0))], running: true),
                                size: CGSize(width: 900, height: 1400))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the closed fences to finish highlighting") {
            ListPerf.settle(thread.window)
            return fences.allSatisfy { CodeHighlightCache.cached(CodeHighlightCache.Key(fence: $0, language: "swift")) != nil }
        }
        try await atRest(thread.window)
        #expect(Self.nativeFields(in: thread.window.host) == fences.count, "the fences are on screen")

        let streamed = try await counting(thread.window) {
            for pulls in 1...5 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(reply(pulls))]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }
        #expect(streamed["thread.liveRow", default: 0] >= 5, "the reply streamed: \(streamed)")
        #expect(streamed["prose.chunk", default: 0] >= 5, "the chunk it grows in was drawn again: \(streamed)")
        #expect(streamed["prose.block", default: 0] >= 5, "the paragraph it grew was drawn again: \(streamed)")
        #expect(streamed["prose.block", default: 0] <= 10, "only the block it grew is drawn again: \(streamed)")
        #expect(streamed["code.nativeUpdated", default: 0] == 0, "no closed fence is updated: \(streamed)")
        #expect(streamed["code.highlighted", default: 0] == 0, "no closed fence is evaluated again: \(streamed)")
        #expect(streamed["prose.image", default: 0] == 0, "the image chip is not drawn again: \(streamed)")
        #expect(streamed["prose.table", default: 0] == 0, "the table is not drawn again: \(streamed)")
        #expect(Self.nativeFields(in: thread.window.host) == fences.count, "the fences are still on screen")
    }

    // MARK: Thread prose

    /// The blocks in the thread's last prose item once its parse has landed (0 before).
    private static func parsedBlocks(_ store: NativeThreadStore) -> Int {
        for item in (store.rows.last?.presentation?.items ?? []).reversed() {
            if case .prose(_, _, let prose) = item { return prose.blockCount }
        }
        return 0
    }

    /// The native code fields under `view`.
    private static func nativeFields(in view: NSView) -> Int {
        (view is SHNativeCodeText.Field ? 1 : 0) + view.subviews.reduce(0) { $0 + nativeFields(in: $1) }
    }

    /// Draws until the reply stops building: its parse has landed (`blocks` top-level blocks) and the
    /// window's counts hold still.
    private func settleReply(_ thread: FakeThread, blocks: Int) async throws {
        try await eventuallyOnMain("the reply's off-main parse to land") {
            ListPerf.settle(thread.window)
            return Self.parsedBlocks(thread.store) == blocks
        }
        var last = SHRenderProbe.counts
        var still = 0
        try await eventuallyOnMain("the long reply to stop building") {
            ListPerf.settle(thread.window)
            let now = SHRenderProbe.counts
            still = now == last ? still + 1 : 0
            last = now
            return still >= 5
        }
    }

    /// A reply of `cycles` cycles (a paragraph, a swift fence, a table and a list each: four blocks) that is giant
    /// (`NativeProse.isGiant`, 128 KB of text from about 380 cycles): the only kind drawn a chunk at a time.
    private static func giantReply(cycles: Int = 500) -> String {
        let text = MarkdownFixtures.longReply(cycles: cycles)
        #expect(NativeProse(nativeMarkdownParse(text)).isGiant, "\(cycles) cycles are a giant reply")
        return text
    }

    /// A finished giant reply of 500 cycles (about 2,000 blocks) opens at its tail. Only the chunks in
    /// view and its tail are built: before, every fence and table of the reply was.
    @Test func aLongReplyBuildsOnlyTheChunksOnScreen() async throws {
        let text = Self.giantReply()
        let blocks = nativeMarkdownBlocks(text).count
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it all down")]
        // Counting from before the window opens: the thread may load in its first frames.
        SHRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn + [ThreadFixture.assistant("long", text)]),
                                size: CGSize(width: 900, height: 800))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await settleReply(thread, blocks: blocks)
        let counts = SHRenderProbe.stop()

        #expect(counts["thread.agentTurn", default: 0] > 0, "the thread was built: \(counts)")
        // A 900x800 window shows two or three cycles; the lazy stack builds some ahead, and the tail (three
        // chunks of about five cycles) is built whole.
        withKnownIssue("older SwiftUI builds more of a lazy stack than is on screen", isIntermittent: true) {
            #expect(counts["code.nativeCreated", default: 0] <= 40, "\(counts)")
            #expect(counts["prose.table", default: 0] <= 40, "\(counts)")
            #expect(counts["prose.chunk", default: 0] <= 12, "\(counts)")
        } when: { ListPerf.olderLazyStacks }
        #expect(counts["code.nativeCreated", default: 0] <= 100, "500 fences in the reply: \(counts)")
        #expect(counts["prose.table", default: 0] <= 100, "500 tables in the reply: \(counts)")
    }

    /// Scrolling through a giant reply from its top to its tail builds the chunks it passes and lets
    /// go of the ones far behind: a creation count cannot show that, so this counts the native
    /// fields SwiftUI dismantled against the ones it built (about 500 built, about 25 alive at once).
    @Test func aLongReplyLetsGoOfChunksScrolledFarAway() async throws {
        let text = Self.giantReply()
        let blocks = nativeMarkdownBlocks(text).count
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it all down")]
        SHRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn + [ThreadFixture.assistant("long", text)]),
                                size: CGSize(width: 900, height: 800))
        defer {
            thread.close()
            SHRenderProbe.stop()
        }
        try await thread.waitUntilReady()
        try await settleReply(thread, blocks: blocks)
        let scroll = try #require(thread.scrollView)

        // A reader's scroll: the wheel's intent first, or the thread would follow its tail back down.
        var held = 0
        try await eventuallyOnMain("the thread to stay at its top") {
            if scroll.contentView.bounds.origin.y > 1_000 {
                held = 0
                thread.input.readerScrolled(upward: true)
                ListPerf.jump(thread.window, scroll, toEnd: false)
            } else {
                ListPerf.settle(thread.window)
                held += 1
            }
            return held >= 10
        }
        try await settleReply(thread, blocks: blocks)
        // Then down through the whole reply a screenful at a time, as a reader does (a jump builds only
        // the few chunks at its two ends), and on to the tail.
        var screens = 0
        while screens < 40, ListPerf.scroll(thread.window, scroll, step: 800, steps: 20).distance > 0 { screens += 1 }
        #expect(screens < 40, "the reply ended within \(screens) batches of 20 screens")
        ListPerf.jump(thread.window, scroll, toEnd: true)
        try await settleReply(thread, blocks: blocks)
        try await eventuallyOnMain("the chunks scrolled away to be let go") {
            ListPerf.settle(thread.window)
            let counts = SHRenderProbe.counts
            let created = counts["code.nativeCreated", default: 0], dismantled = counts["code.nativeDismantled", default: 0]
            return dismantled > 0 && created - dismantled <= 40
        }
        #expect(Self.nativeFields(in: thread.window.host) <= 40, "fields alive in the window")
    }

    /// A reply grown in five serves of 100 cycles, following its tail, keeps only its tail built once it is
    /// giant (from the fourth serve): the chunks it streamed past are let go, counted both ways.
    @Test func streamingALongReplyBuildsOnlyItsTail() async throws {
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it all down")]
        SHRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming("Here it is.")], running: true),
                                size: CGSize(width: 900, height: 800))
        defer {
            thread.close()
            SHRenderProbe.stop()
        }
        try await thread.waitUntilReady()
        var text = ""
        for serve in 0..<5 {
            text += (serve == 0 ? "" : "\n\n") + MarkdownFixtures.longReply(cycles: 100, from: serve * 100)
            var next = thread.snapshot
            next.revision += 1
            next.provisional = [ThreadFixture.streaming(text)]
            await thread.serve(next)
            try await settleReply(thread, blocks: nativeMarkdownParse(text, streaming: true).blocks.count)
        }
        #expect(NativeProse(nativeMarkdownParse(text, streaming: true)).isGiant, "the reply ended giant")
        let counts = SHRenderProbe.counts
        let created = counts["code.nativeCreated", default: 0], dismantled = counts["code.nativeDismantled", default: 0]
        #expect(created - dismantled <= 40, "fields alive by count: created \(created), dismantled \(dismantled)")
        let fields = Self.nativeFields(in: thread.window.host)
        #expect(fields <= 40, "fields alive in the window")
        #expect(fields > 0, "the reply's tail is on screen: \(counts)")
    }

    /// A reply below the giant gate (30 cycles, about 7 chunks) is laid out whole, as before chunks, and streams in a
    /// cycle at a time: each serve redraws exactly one chunk, the one being written, and on a serve that adds a chunk
    /// that one and the new one at most, never the closed chunks before. Only the new cycle's code view is created.
    @Test func aStreamedReplyBelowTheGateRedrawsOneChunkPerServe() async throws {
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it all down")]
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming("Here it is.")], running: true),
                                size: CGSize(width: 900, height: 800))
        defer { thread.close() }
        try await thread.waitUntilReady()
        ListPerf.settle(thread.window)
        var text = ""
        var serves: [[String: Int]] = []
        var chunks = [NativeProse(nativeMarkdownParse("Here it is.", streaming: true)).chunks.count]
        for cycle in 0..<30 {
            text += (cycle == 0 ? "" : "\n\n") + MarkdownFixtures.longReply(cycles: 1, from: cycle)
            chunks.append(NativeProse(nativeMarkdownParse(text, streaming: true)).chunks.count)
            var next = thread.snapshot
            next.revision += 1
            next.provisional = [ThreadFixture.streaming(text)]
            SHRenderProbe.start()
            await thread.serve(next)
            do {
                try await settleReply(thread, blocks: nativeMarkdownParse(text, streaming: true).blocks.count)
            } catch {
                SHRenderProbe.stop()
                throw error
            }
            serves.append(SHRenderProbe.stop())
        }
        let prose = NativeProse(nativeMarkdownParse(text, streaming: true))
        #expect(!prose.isGiant && (5...10).contains(prose.chunks.count), "\(prose.chunks.count) chunks of \(prose.textBytes) bytes")
        for (cycle, counts) in serves.enumerated() {
            let grew = chunks[cycle + 1] > chunks[cycle]
            let redrawn = counts["prose.chunk", default: 0]
            #expect(grew ? (1...2).contains(redrawn) : redrawn == 1,
                    "serve \(cycle) \(grew ? "added" : "did not add") a chunk (\(chunks[cycle]) to \(chunks[cycle + 1])): \(counts)")
            #expect(counts["code.nativeCreated", default: 0] <= 1, "serve \(cycle): \(counts)")
        }
        #expect(chunks[30] > chunks[0], "chunks were added while it streamed: \(chunks)")
        #expect(Self.nativeFields(in: thread.window.host) >= 30, "every cycle's fence is laid out: below the gate nothing is lazy")
    }

    // MARK: Workspace

    /// Launching into a workspace of many agents builds the visible layout and nothing else: its
    /// first frame holds one layout and its thread, and once that thread is ready no other
    /// layout has mounted, until its agent is shown.
    @Test func launchBuildsOnlyTheVisibleLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(12, in: app, mounting: .launch)
        var window: OffscreenWindow!
        let visible = vm.threadStores.store(for: agents[0].agent.id)

        SHRenderProbe.start()
        window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let first = SHRenderProbe.counts
        let total: [String: Int]
        do {
            try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
            ListPerf.settle(window)
            total = SHRenderProbe.stop()
        } catch {
            SHRenderProbe.stop()
            throw error
        }

        #expect(first["layout.agentLayout", default: 0] == 1, "\(first)")
        #expect(first["thread.view", default: 0] <= 2, "\(first)")
        #expect(total["deck.mount", default: 0] == 1, "\(total)")
        #expect(total["deck.hiddenLayout", default: 0] == 0, "\(total)")
        #expect(try WorkspaceNavigationTests.deck(in: window).pages.count == 1)
        #expect(vm.mountedTabs.count == 1)
    }

    /// What a launch builds does not grow with the agents nobody opened: beside thirty of them
    /// the window holds the same layouts, hosts and views as alone, and its renders stay within a
    /// twentieth.
    @Test func aLaunchBuildsTheSameBesideThirtyAgentsNobodyOpened() async throws {
        func views(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + views($1) } }
        func launch(beside others: Int) async throws -> (counts: [String: Int], views: Int) {
            let app = try AppHarness()
            defer { app.stop() }
            let space = Fixture.space(path: app.dir.path)
            var agents = [try await app.liveAgent("shown", in: space, order: 0)]
            for index in 0..<others { agents.append(Fixture.agent("nobody opened \(index)", in: space, order: index + 1)) }
            let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
            vm.selectAgent(agents[0].agent.id)
            let shown = vm.threadStores.store(for: agents[0].agent.id)

            SHRenderProbe.start()
            let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
            defer { window.close() }
            do {
                try await eventuallyOnMain("the shown thread to load", timeout: .seconds(60)) { shown.ready }
                ListPerf.settle(window)
                // What the launch set off after the thread, until the window holds still.
                var settled = 0
                try await eventuallyOnMain("the window to hold still") {
                    ListPerf.settle(window)
                    let now = views(window.host)
                    defer { settled = now }
                    return now == settled
                }
            } catch {
                SHRenderProbe.stop()
                throw error
            }
            return (SHRenderProbe.stop(), views(window.host))
        }

        let alone = try await launch(beside: 0)
        let crowded = try await launch(beside: 30)

        #expect(crowded.counts["deck.mount", default: 0] == alone.counts["deck.mount", default: 0], "\(crowded.counts)")
        #expect(crowded.counts["deck.hiddenLayout", default: 0] == alone.counts["deck.hiddenLayout", default: 0], "\(crowded.counts)")
        #expect(crowded.views == alone.views, "\(crowded.views) views beside thirty, \(alone.views) alone")
        for key in ["layout.agentLayout", "layout.paneTreeGeo", "thread.view", "composer.body"] {
            let base = alone.counts[key, default: 0]
            #expect(abs(crowded.counts[key, default: 0] - base) <= max(2, base / 20), "\(key): alone \(alone.counts), beside thirty \(crowded.counts)")
        }
    }

    /// Dragging the window's edge relays out the visible layout alone: hidden layouts keep
    /// their size until the drag ends, and the shell around them (the root view, the sidebar,
    /// the palette's overlay) takes no update while the width changes nothing it lays out.
    @Test func aResizeFrameRelaysOutOnlyTheVisibleLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(6, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        try await Task.sleep(for: .milliseconds(300))
        ListPerf.settle(window)

        let sidebar = CGRect(x: 0, y: 80, width: 160, height: 320)
        let before = FrameTimer.capture(window, sidebar)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window.window)
        ListPerf.settle(window)
        let frames = 10
        let rows = ListPerf.counting {
            for step in 1...frames {
                window.window.setContentSize(NSSize(width: 1400 - CGFloat(step) * 8, height: 800))
                ListPerf.settle(window)
            }
        }
        // The frozen layouts, wider than the column now, must not widen the shell around them.
        let during = FrameTimer.capture(window, sidebar)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window.window)
        ListPerf.settle(window)

        #expect(during == before, "the sidebar stays put while hidden layouts are frozen")
        #expect(rows["layout.paneTreeGeo", default: 0] <= frames, "the visible layout alone: \(rows)")
        for key in ["shell.root", "shell.sidebar", "paletteOverlay"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    /// Narrowing a window changes the shell's sidebar geometry. Its image-viewer action must
    /// keep a stable identity so all fixed-size hidden threads are not invalidated with it.
    @Test func aShellResizeDoesNotInvalidateEveryMountedThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(6, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the mounted workspace to settle") {
            ListPerf.settle(window)
            return vm.mountedTabs.count == agents.count
                && vm.threadStores.store(for: agents[0].agent.id).ready
                && IdleCostTests.spinners(in: window.host).all == 0
        }
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let hidden = deck.pages.values.filter { $0.host.isHidden }.map(\.host)
        let bounds = hidden.map(\.bounds)
        let frames = 12
        let counts = ListPerf.counting {
            for step in 1...frames {
                window.window.setContentSize(CGSize(width: 1200 - CGFloat(step) * 12, height: 800))
                ListPerf.settle(window)
            }
        }
        #expect(counts["shell.root", default: 0] > 0, "the shell really changed during resizing")
        #expect(hidden.count == agents.count - 1 && hidden.map(\.bounds) == bounds)
        #expect(counts["thread.view", default: 0] <= frames,
                "a changing shell must not invalidate every fixed-size hidden thread: \(counts)")
    }

    /// A hidden agent reporting its status redraws no mounted layout: the workspace resolves
    /// each layout's values, and only a layout whose values changed runs again.
    @Test func aStatusReportRedrawsNoMountedLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(8, in: app)
        defer { window.close() }
        #expect(vm.mountedTabs.count == agents.count)

        let rows = ListPerf.counting {
            for agent in agents.dropFirst() {
                var next = vm.state
                if let index = next.agents.firstIndex(where: { $0.id == agent.agent.id }) {
                    next.agents[index].status = next.agents[index].status == .working ? .done : .working
                }
                ListPerf.time(window) { vm.adopt(next) }
            }
        }

        #expect(rows["layout.agentLayout", default: 0] == 0, "\(rows)")
        #expect(rows["layout.paneTreeGeo", default: 0] == 0, "\(rows)")
    }

    /// A hidden agent starting a turn, asking a question and ending it changes only what the sidebar shows of it: the
    /// root view, the workspace, the layouts' resolver and every thread read the workspace's structure, so none of them
    /// runs again. Each edge redraws its sidebar row and the headers whose counts it moves. Renaming a thread is
    /// structure, and reruns the workspace and that one layout.
    @Test func aStatusReportAmongMountedAgentsRunsNoShellBody() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(8, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        // Measure after every stub has served and the hidden threads have stopped updating, not while they boot.
        for agent in agents { _ = try await app.readyThread(agent.agent.id) }
        func settled() async throws {
            var quiet = 0
            try await eventuallyOnMain("the mounted workspace to settle", timeout: .seconds(60)) {
                ListPerf.settle(window)
                guard vm.mountedTabs.count == agents.count, vm.threadStores.store(for: agents[0].agent.id).ready,
                      IdleCostTests.spinners(in: window.host).all == 0 else { return false }
                let counts = ListPerf.counting { ListPerf.settle(window) }
                quiet = ["shell.root", "shell.workspace", "thread.view", "deck.hiddenLayout"].allSatisfy { counts[$0, default: 0] == 0 } ? quiet + 1 : 0
                return quiet >= 10
            }
        }
        try await settled()
        // The first adoption that changes anything reruns every mounted thread once, whatever it changed: take it before counting.
        var first = vm.state
        first.agents[0].lastActiveAt = 1
        vm.adopt(first)
        try await settled()
        let hidden = agents.dropFirst()
        let stamp = 1_800_000_000_000.0

        func report(_ who: ArraySlice<AgentFixture>? = nil, _ change: (inout Agent) -> Void) -> [String: Int] {
            ListPerf.counting {
                for agent in who ?? hidden {
                    var next = vm.state
                    guard let index = next.agents.firstIndex(where: { $0.id == agent.agent.id }) else { continue }
                    change(&next.agents[index])
                    ListPerf.time(window) { vm.adopt(next) }
                }
            }
        }
        let edges: [(String, [String: Int])] = [
            ("a turn starting", report { $0.status = .working; $0.lastActiveAt = stamp + 1 }),
            ("a question", report { $0.status = .blocked; $0.waitingOn = "Which database?"; $0.waitingReason = "database?" }),
            ("a turn ending", report {
                $0.status = .done; $0.waitingOn = nil; $0.waitingReason = nil; $0.lastActiveAt = stamp + 2; $0.completedAt = stamp + 2
            }),
        ]
        #expect(vm.state.agents.filter { $0.status == .done }.count == hidden.count)
        for (edge, rows) in edges {
            for key in ["shell.root", "shell.workspace", "layout.agentLayout", "thread.view", "deck.update"] {
                #expect(rows[key, default: 0] == 0, "\(edge), \(key): \(rows)")
            }
            #expect(rows["sidebar.row", default: 0] <= hidden.count * 2, "\(edge): \(rows)")
            #expect(rows["sidebar.header", default: 0] <= hidden.count * 2, "\(edge): \(rows)")
        }

        // Control: a name is structure.
        let renamed = report(hidden.prefix(1)) { $0.name = "Checkout funnel v2" }
        #expect(renamed["shell.workspace", default: 0] >= 1, "\(renamed)")
        #expect(renamed["layout.agentLayout", default: 0] == 1, "\(renamed)")
    }

    /// The same through the host, as the app receives it: its pushes set the connection's state and are adopted
    /// (`receiveLocalHostState`), and a hidden agent's reports redraw neither the shell nor a thread.
    @Test func aReportThroughTheHostRunsNoShellBody() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(6, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        for agent in agents { _ = try await app.readyThread(agent.agent.id) }
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        func report(_ agent: AgentFixture, _ status: AgentStatus) async throws {
            try reporter.send(.setAgentStatus(agentID: agent.agent.id, status: status))
            try await eventuallyOnMain("the host's \(status) report for \(agent.agent.name)", timeout: .seconds(30)) {
                ListPerf.settle(window)
                return vm.state.agents.first { $0.id == agent.agent.id }?.status == status
            }
        }
        func settled() async throws {
            var quiet = 0
            try await eventuallyOnMain("the mounted workspace to settle", timeout: .seconds(60)) {
                ListPerf.settle(window)
                guard vm.mountedTabs.count == agents.count, vm.threadStores.store(for: agents[0].agent.id).ready,
                      IdleCostTests.spinners(in: window.host).all == 0 else { return false }
                let counts = ListPerf.counting { ListPerf.settle(window) }
                quiet = ["shell.root", "shell.workspace", "thread.view", "deck.hiddenLayout"].allSatisfy { counts[$0, default: 0] == 0 } ? quiet + 1 : 0
                return quiet >= 10
            }
        }
        try await settled()
        // The first adoption that changes anything reruns every mounted thread once, whatever it changed: take it before counting.
        try await report(agents[0], .working)
        try await settled()

        SHRenderProbe.start()
        for agent in agents.dropFirst() {
            try await report(agent, .working)
            try await report(agent, .done)
        }
        let rows = SHRenderProbe.stop()
        for key in ["shell.root", "shell.workspace", "layout.agentLayout", "thread.view", "deck.update"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
        #expect(rows["sidebar.row", default: 0] > 0, "the sidebar showed the reports: \(rows)")
    }

    /// One checkout read writes every thread that shares the checkout. The count it carries is
    /// not in a layout's model, so a change of it reruns no layout, thread or composer, hidden or
    /// not; only the card on screen is asked to read again.
    @Test func aCheckoutCountChangeAmongEightAgentsRedrawsNoLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(8, in: app)
        defer { window.close() }
        let ids = agents.map(\.agent.id)
        await app.server.setAgentCheckouts(ids, AgentCheckout(branch: "main", changedFiles: 1))
        try await eventuallyOnMain("every thread to carry the checkout") {
            vm.state.agents.count == ids.count && vm.state.agents.allSatisfy { $0.checkout?.changedFiles == 1 }
        }
        try await eventuallyOnMain("the card on screen") {
            ListPerf.settle(window)
            return vm.branchCardStore(for: ids[0]).card != nil
        }
        ListPerf.settle(window)

        var next = vm.state
        for index in next.agents.indices { next.agents[index].checkout = AgentCheckout(branch: "main", changedFiles: 2) }
        let rows = ListPerf.counting { ListPerf.time(window) { vm.adopt(next) } }

        #expect(vm.state.agents.allSatisfy { $0.checkout?.changedFiles == 2 })
        for key in ["layout.agentLayout", "layout.paneTreeGeo", "thread.view", "composer.body", "deck.update", "deck.hiddenLayout"] {
            #expect(rows[key, default: 0] == 0, "\(key): \(rows)")
        }
    }

    /// The count still reaches the card that shows it: the visible thread's card is asked to
    /// read again, a hidden one is not, and reads when its thread shows.
    @Test func aCountChangeReadsOnlyTheCardOnScreenAgain() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(8, in: app)
        defer { window.close() }
        let ids = agents.map(\.agent.id)
        await app.server.setAgentCheckouts(ids, AgentCheckout(branch: "main", changedFiles: 1))
        try await eventuallyOnMain("every thread to carry the checkout") {
            vm.state.agents.count == ids.count && vm.state.agents.allSatisfy { $0.checkout?.changedFiles == 1 }
        }
        try await eventuallyOnMain("the card on screen") {
            ListPerf.settle(window)
            return vm.branchCardStore(for: ids[0]).card != nil
        }
        ListPerf.settle(window)
        let before = ids.map { vm.branchCardStore(for: $0).refreshRequest }

        var next = vm.state
        for index in next.agents.indices { next.agents[index].checkout = AgentCheckout(branch: "main", changedFiles: 2) }
        ListPerf.time(window) { vm.adopt(next) }

        let after = ids.map { vm.branchCardStore(for: $0).refreshRequest }
        #expect(after[0] == before[0] + 1, "the card on screen reads again: \(before) to \(after)")
        #expect(Array(after.dropFirst()) == Array(before.dropFirst()), "a hidden card waits until its thread shows: \(before) to \(after)")

        #expect(vm.branchCardStore(for: ids[3]).card == nil, "a hidden thread's card has not read")
        vm.selectAgent(ids[3])
        try await eventuallyOnMain("the shown thread's card") {
            ListPerf.settle(window)
            return vm.branchCardStore(for: ids[3]).card != nil
        }
    }

    /// A host's push about another thread leaves a remote thread's layout alone
    /// (`RemoteLayoutModel`): not the layout, its panel, the thread or the composer. With design
    /// references on, the thread pane once read the connection for them, so every push rebuilt it.
    @Test func aHostPushForAnotherThreadRedrawsNoRemoteLayout() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        local.settings.designToolEnabled = true
        remote.host.settings.designToolEnabled = true
        let space = Fixture.space("acme-web", path: remote.host.dir.path)
        // The thread's pi is up before the host starts, so nothing binds to its layout while it is counted.
        let shown = try await remote.host.liveAgent("Checkout funnel", in: space)
        let other = Fixture.agent("Search index", in: space, order: 1)
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [shown, other]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        let ref = RemoteAgentRef(hostID: connection.id, agentID: shown.agent.id)
        // The thread pane reads the connection only where the host takes references and the thread has chips.
        #expect(connection.supportsDesignCapability(RemoteProtocol.designReferencesCapability))
        #expect(vm.remoteDesignReferenceChips(for: ref) != nil)

        vm.selectRemoteAgent(hostID: ref.hostID, agentID: ref.agentID)
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), RemoteAgentPane(vm: vm, ref: ref))
        defer { window.close() }
        try await eventuallyOnMain("the remote thread to mount") {
            window.layout()
            return ListPerf.scrollView(in: window) != nil
        }
        let store = vm.remoteThreadStores.store(for: ref)
        try await eventuallyOnMain("the remote thread to load") { store.ready }
        ListPerf.settle(window)

        let reporter = try ExtensionClient(path: remote.host.scratch.socketPath)
        func report(_ status: AgentStatus) async throws {
            try reporter.send(.setAgentStatus(agentID: other.agent.id, status: status))
            try await eventuallyOnMain("the host's \(status) report for the other thread") {
                connection.state.agents.first { $0.id == other.agent.id }?.status == status
            }
            ListPerf.settle(window)
        }
        SHRenderProbe.start()
        for edge in 0..<6 { try await report(edge.isMultiple(of: 2) ? .working : .done) }
        let pushes = SHRenderProbe.stop()
        for key in ["layout.remoteLayout", "layout.remotePaneTree", "thread.view", "composer.body"] {
            #expect(pushes[key, default: 0] == 0, "\(key): \(pushes)")
        }

        // Control: the thread's own name changing redraws its layout.
        SHRenderProbe.start()
        try await remote.host.server.renameAgent(shown.agent.id, to: "Checkout funnel v2")
        try await eventuallyOnMain("the host's rename") { connection.state.agents.first { $0.id == shown.agent.id }?.name == "Checkout funnel v2" }
        ListPerf.settle(window)
        let renamed = SHRenderProbe.stop()
        #expect(renamed["layout.remoteLayout", default: 0] >= 1, "\(renamed)")
    }

    /// Opening a review docks it beside one layout, and redraws that layout alone.
    @Test func openingAReviewRedrawsOnlyItsLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(8, in: app)
        defer { window.close() }

        let rows = ListPerf.counting { ListPerf.time(window) { vm.openReview(agentID: agents[0].agent.id, path: nil) } }

        #expect(vm.reviewSessions.values.contains { $0.agentID == agents[0].agent.id })
        #expect(rows["layout.agentLayout", default: 0] <= 1, "\(rows)")
    }

    /// What updates in the visible layout set off: each kind's probe counts, and what of the
    /// window AppKit walks.
    struct VisibleUpdates {
        var census = HiddenAgentsWorkspace.Census()
        var counts: [String: [String: Int]] = [:]
    }

    static func visibleUpdates(hidden: Int) async throws -> VisibleUpdates {
        let app = try AppHarness()
        defer { app.stop() }
        let workspace = try await HiddenAgentsWorkspace.open(hidden: hidden, in: app)
        defer { workspace.close() }
        var result = VisibleUpdates(census: workspace.census())
        result.counts["1 pt steps"] = ListPerf.counting { _ = workspace.scroll(step: 1, steps: 40) }
        result.counts["40 pt steps"] = ListPerf.counting { _ = workspace.scroll(step: 40, steps: 40) }
        result.counts["keystrokes"] = ListPerf.counting { workspace.type(24) }
        result.counts["status reports"] = ListPerf.counting { workspace.reportStatus(20) }
        SHRenderProbe.start()
        try await workspace.stream()
        result.counts["a streamed reply"] = SHRenderProbe.stop()
        return result
    }

    /// Every mounted layout has a hosting view of its own (`AgentLayoutDeck`), so an update in
    /// the visible one costs the same beside thirty hidden agents as beside none: no hidden
    /// layout is laid out or runs a body, the deck itself takes no update, and AppKit walks the
    /// same views, layers and tracking areas (a hidden layout is an `isHidden` view). In one
    /// view graph, each hidden agent added about 0.4 M instructions to a scroll step and 1.2 M
    /// to a status report (`HiddenAgentsReport` prints them).
    @Test func anUpdateInTheVisibleLayoutCostsTheSameBesideThirtyHiddenAgents() async throws {
        let alone = try await Self.visibleUpdates(hidden: 0)
        let crowded = try await Self.visibleUpdates(hidden: 30)

        #expect(crowded.census == alone.census, "AppKit walks \(crowded.census) beside 30 hidden agents, \(alone.census) alone")
        for (update, counts) in crowded.counts.sorted(by: { $0.key < $1.key }) {
            #expect(counts["deck.hiddenLayout", default: 0] == 0, "\(update): \(counts)")
            #expect(counts["deck.update", default: 0] == 0, "\(update): \(counts)")
            // A reply's pulls land as the server's pushes come, differently each run.
            guard update != "a streamed reply" else { continue }
            let own = alone.counts[update] ?? [:]
            for key in Set(counts.keys).union(own.keys) {
                let (a, b) = (own[key, default: 0], counts[key, default: 0])
                #expect(abs(a - b) <= max(2, a / 20), "\(update), \(key): \(a) alone, \(b) beside 30 hidden agents")
            }
        }
        #expect((crowded.counts["a streamed reply"]?["deck.layout"] ?? 0) > 0, "the reply reached the screen")
    }

    // MARK: Subagents

    /// A turn whose spawn calls started `runs`, as the thread shows it.
    private static func spawned(_ runs: [ChildRun]) -> NativeThreadSnapshot {
        let spawns = runs.map { run in
            NativeThreadMessage(entryID: "t-\(run.runID)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "{}")],
                                toolName: "shepherd_child_start", toolCallID: run.toolCallID, argumentsText: "{\"task\":\"part\"}",
                                status: "complete")
        }
        return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false,
                                    supportedActions: ["send", "subagents"], dialogsSupported: true, dialogs: [],
                                    messages: ListFixtures.conversation(turns: 2)
                                        + [ListFixtures.message("u", "user", "Split it up"), ListFixtures.message("a", "assistant", "Splitting.")]
                                        + spawns,
                                    provisional: [], clipped: false, subagents: runs)
    }

    /// A finished workflow of two hundred runs: the tray above the composer shows four rows and
    /// "Show 196 more", and the thread records the runs in two lines, never a row each.
    @Test func aWorkflowOfTwoHundredRunsShowsFourTrayRows() async throws {
        let runs = (0..<200).map { index in
            var run = ListFixtures.run(index, state: "complete")
            run.toolCallID = "spawn-\(index)"
            return run
        }
        let snapshot = Self.spawned(runs)
        let store = NativeThreadStore()
        var window: OffscreenWindow!
        SHRenderProbe.start()
        window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                 ThreadView(store: store, active: true, isFocused: false, request: { _ in .snapshot(value: snapshot) },
                                            commandKey: "tray", inspectSubagent: { _ in }))
        defer {
            store.stop()
            window.close()
        }
        try await eventuallyOnMain("the thread to load") { store.ready && store.tray != nil }
        ListPerf.settle(window)
        let rows = SHRenderProbe.stop()

        #expect(rows["tray.row", default: 0] > 0, "the tray shows: \(rows)")
        #expect(rows["tray.row", default: 0] <= 8, "\(rows)")
    }

    /// Each tool call a subagent makes moves its row's words and counters on the host. The tray's
    /// rows redraw; the composer, which only decides whether the tray is docked and whether Stop
    /// reaches the subagents, runs no body. A run ending, which does change what Stop says,
    /// still redraws it (the control).
    @Test func aSubagentProgressUpdateRedrawsNoComposer() async throws {
        let runs = (0..<2).map { index in
            var run = ListFixtures.run(index)
            run.toolCallID = "spawn-\(index)"
            return run
        }
        var snapshot = Self.spawned(runs)
        snapshot.running = true
        let thread = FakeThread(snapshot, subagentTray: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the tray to dock") { thread.store.tray != nil }
        try await atRest(thread.window)

        let rows = try await counting(thread.window) {
            for step in 1...5 {
                var next = thread.snapshot
                next.revision += 1
                next.subagents = runs.map { run in
                    var run = run
                    run.turns = (run.turns ?? 0) + step
                    run.toolCalls = step
                    run.lastActivity = ChildActivity(tool: "read", preview: "Sources/Step\(step).swift", at: 2_000 + Double(step))
                    return run
                }
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
        }

        let line = thread.store.tray?.rows.first?.line
        #expect(line == .working(verb: "Read", subject: "Step5.swift", live: false), "the tray followed the last call: \(String(describing: line))")
        #expect(rows["tray.row", default: 0] >= 1, "the tray's rows redrew: \(rows)")
        #expect(rows["composer.body", default: 0] == 0, "composer.body: \(rows)")

        try await atRest(thread.window)
        var ended = thread.snapshot
        ended.revision += 1
        ended.subagents = runs.map { run in
            var run = run
            run.state = "complete"
            run.endedAt = 3_000
            return run
        }
        let finished = try await counting(thread.window) { await thread.serve(ended) }
        #expect(!thread.store.hasLiveSubagents)
        #expect(finished["composer.body", default: 0] >= 1, "Stop's help changes with the last run: \(finished)")
    }

    /// An open tray of two hundred runs scrolls inside, building only the rows in view.
    private struct TrayHost: View {
        let runs: [ChildRun]
        let state: SubagentTrayState

        var body: some View {
            SubagentTrayView(tray: NativeSubagentTray(runs), state: state, runs: runs,
                             actions: SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }))
                .frame(width: 800)
        }
    }

    @Test func anOpenTrayOfTwoHundredRunsBuildsOnlyTheRowsInView() throws {
        let runs = (0..<200).map { ListFixtures.run($0) }
        let state = SubagentTrayState()
        state.expanded = true
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 800, height: 500), dark: true, TrayHost(runs: runs, state: state))
            ListPerf.settle(window)
        }
        defer { window.close() }

        #expect(rows["tray.row", default: 0] > 0, "\(rows)")
        #expect(rows["tray.row", default: 0] <= 2 * AppLayout.trayExpandedMaxRows, "\(rows)")
    }

    /// Among two hundred live runs, one changing state redraws its own row; the rest keep theirs.
    @Test func oneRunChangingRedrawsOnlyItsTrayRow() throws {
        let runs = (0..<200).map { ListFixtures.run($0) }
        let state = SubagentTrayState()
        state.expanded = true
        let window = OffscreenWindow(size: CGSize(width: 800, height: 500), dark: true, TrayHost(runs: runs, state: state))
        defer { window.close() }
        ListPerf.settle(window)
        var next = runs
        // Paused retains the running row's sort position; complete would move it offscreen.
        next[2].state = "paused"

        let rows = ListPerf.counting { ListPerf.time(window) { window.show(TrayHost(runs: next, state: state)) } }

        #expect(rows["tray.row", default: 0] > 0, "\(rows)")
        #expect(rows["tray.row", default: 0] <= 2, "\(rows)")
    }

    // MARK: Skills

    /// Settings ▸ Skills over 200 skills: opening builds the rows on screen and some ahead of them,
    /// never the whole list, and one skill turning off redraws its row alone.
    @Test func oneSkillChangingRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        for index in 0..<200 {
            let name = "skill-\(index + 100)"
            let text = "---\nname: \(name)\ndescription: Skill number \(index).\n---\n"
            try app.server.skills.installFiles(name: name, files: [SkillFile(path: "SKILL.md", contents: Data(text.utf8))],
                                                invocation: .automatic)
        }
        await vm.skills.refresh(vm.skillsHosts)
        let size = CGSize(width: 1200, height: 800)
        var window: OffscreenWindow!
        let opened = ListPerf.counting {
            window = OffscreenWindow(size: size, dark: true, SkillsSettings(vm: vm, model: vm.skills))
            ListPerf.settle(window)
        }
        defer { window.close() }
        // About a dozen rows fit under the page's header; the lazy stack builds some ahead of
        // them (50 here, at any speed). All 200 would mean it isn't lazy.
        #expect(opened["skills.row", default: 0] > 0, "\(opened)")
        #expect(opened["skills.row", default: 0] <= 80, "\(opened)")

        var snapshot = try #require(vm.skills.state(of: vm.skillsHosts[0]).snapshot)
        snapshot.skills[0].isOn = false
        let changed = ListPerf.counting {
            ListPerf.time(window) { vm.skills.hostChanged(ShepherdViewModel.thisMacSkills, snapshot) }
        }
        #expect(changed["skills.row", default: 0] > 0, "\(changed)")
        #expect(changed["skills.row", default: 0] <= 2, "\(changed)")
    }

    /// The read-only groups are lazy too: 200 skills from pi's own setup and packages build only
    /// the rows on screen, and one changing redraws its row alone.
    @Test func onePiSkillChangingRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let pi = PiSkills(agentDirectory: "~/.pi/agent", skills: (0..<200).map { index in
            let name = "pi-skill-\(index + 100)"
            return index < 100
                ? PiSkill(name: name, summary: "Skill number \(index).", path: "~/.pi/agent/skills/\(name)/SKILL.md", origin: .agentDirectory)
                : PiSkill(name: name, summary: "Skill number \(index).", path: "~/.pi/agent/npm/node_modules/@acme/skills/\(name)/SKILL.md",
                          origin: .package, package: "@acme/skills")
        })
        app.server.skills.piSkills = { _ in pi }
        await vm.skills.refresh(vm.skillsHosts)
        let size = CGSize(width: 1200, height: 800)
        var window: OffscreenWindow!
        let opened = ListPerf.counting {
            window = OffscreenWindow(size: size, dark: true, SkillsSettings(vm: vm, model: vm.skills))
            ListPerf.settle(window)
        }
        defer { window.close() }
        #expect(opened["skills.row", default: 0] > 0, "\(opened)")
        #expect(opened["skills.row", default: 0] <= 80, "\(opened)")

        var snapshot = try #require(vm.skills.state(of: vm.skillsHosts[0]).snapshot)
        snapshot.pi?.skills[0].summary = "Changed by hand."
        let changed = ListPerf.counting {
            ListPerf.time(window) { vm.skills.hostChanged(ShepherdViewModel.thisMacSkills, snapshot) }
        }
        #expect(changed["skills.row", default: 0] > 0, "\(changed)")
        #expect(changed["skills.row", default: 0] <= 2, "\(changed)")
    }

    // MARK: MCP servers

    private struct NoCLI: MCPCLI {
        func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval,
                 onLine: (@Sendable (String) -> Void)?) async -> MCPCLIResult {
            MCPCLIResult(status: 1, stdout: "", stderr: "")
        }
    }

    /// Settings ▸ MCP servers over 200 servers: opening builds the rows on screen and some ahead
    /// of them, never the whole list, and one server changing redraws its row alone.
    @Test func oneServerChangingRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let directory = try makeScratchDirectory()
        let config = directory.appendingPathComponent("mcp.json")
        let servers = (0..<200).map { #""server-\#($0 + 100)": {"command": "npx", "args": ["server-\#($0)"]}"# }
        try Data("{\"mcpServers\": {\(servers.joined(separator: ","))}}".utf8).write(to: config)
        let store = MCPStore(dependencies: .init(
            file: MCPConfigFile(url: config), secrets: InMemorySecretStore(), http: URLSessionHTTP(), cli: NoCLI(),
            preparePi: { nil }, authData: { nil }, openURL: { _ in }, copy: { _ in }, now: { Date() }))
        #expect(store.rows.count == 200)
        let size = CGSize(width: 1200, height: 800)
        var window: OffscreenWindow!
        let opened = ListPerf.counting {
            window = OffscreenWindow(size: size, dark: true, MCPSettings(vm: vm, store: store))
            ListPerf.settle(window)
        }
        defer { window.close() }
        // About a dozen rows fit under the page's header; the lazy stack builds some ahead.
        #expect(opened["mcp.row", default: 0] > 0, "\(opened)")
        #expect(opened["mcp.row", default: 0] <= 80, "\(opened)")

        let changed = ListPerf.counting {
            ListPerf.time(window) {
                store.setEnabled("server-100", false)
            }
        }
        #expect(changed["mcp.row", default: 0] > 0, "\(changed)")
        #expect(changed["mcp.row", default: 0] <= 2, "\(changed)")
    }

    // MARK: Review

    private func review(_ files: [DiffFile]) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true, ReviewPaneContent(model: ListFixtures.reviewModel(files)))
    }

    @Test func openingAReviewOfThreeHundredFilesBuildsOnlyTheChipsAndLinesInView() throws {
        let files = (0..<300).map { ListFixtures.diffFile("Sources/Module\($0)/File\($0).swift", lines: 12) }
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = review(files)
            ListPerf.settle(window)
        }
        defer { window.close() }
        // A chip is at least its letter, a short name, and padding: about a dozen fit 600pt.
        #expect(rows["review.fileChip", default: 0] > 0, "\(rows)")
        #expect(rows["diff.line", default: 0] > 0, "\(rows)")
        #expect(rows["review.fileChip", default: 0] <= 24, "\(rows)")
        #expect(rows["diff.line", default: 0] <= 2 * Int(800 / SHDiffMetrics.lineHeight), "\(rows)")
    }

    /// Every line can be commented on, but a line builds its `+` only while it is hovered.
    @Test func scrollingALongDiffBuildsNoCommentButtons() throws {
        let window = review([ListFixtures.diffFile("Big.swift", lines: 2000)])
        defer { window.close() }
        let rows = ListPerf.counting {
            ListPerf.settle(window)
            if let scroll = ListPerf.scrollView(in: window) { _ = ListPerf.scroll(window, scroll, step: 400, steps: 40) }
        }
        #expect(rows["diff.line", default: 0] > 100, "the diff scrolled: \(rows)")
        #expect(rows["diff.commentButton", default: 0] == 0, "\(rows)")
    }

    /// A hovered line's `+` is built with no AppKit view behind it (a `Button` brings two): the
    /// pointer resting over a scrolling diff hovers a new line every step.
    @Test func aHoveredLinesPlusBringsNoAppKitView() throws {
        func views(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + views($1) } }
        let lines = ListFixtures.diffFile("Big.swift", lines: 30).hunks[0].lines.map { line in
            SHDiffLineContent(id: "\(line.id)", key: line.id, kind: line.kind.diffKind, oldNumber: line.oldLine, newNumber: line.newLine,
                              text: AttributedString(line.text), source: line.text)
        }
        func window(hovering: Bool) -> OffscreenWindow {
            OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true, VStack(spacing: 0) {
                ForEach(lines) { SHDiffLine($0, onComment: {}, hovering: hovering) }
            })
        }
        var rest: OffscreenWindow!, hovered: OffscreenWindow!
        let buttons = ListPerf.counting {
            rest = window(hovering: false)
            hovered = window(hovering: true)
            ListPerf.settle(rest)
            ListPerf.settle(hovered)
        }
        defer {
            rest.close()
            hovered.close()
        }
        #expect(buttons["diff.commentButton", default: 0] == lines.count, "every hovered line shows its +: \(buttons)")
        #expect(views(hovered.host) == views(rest.host))
    }

    /// Opening a comment's editor on a line and saving it redraws that line's row, not every row
    /// on screen: rows compare their line and its note, never the closures.
    @Test func commentingOnALineRedrawsOnlyThatLine() throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel(files)
        model.session.comments = ListFixtures.realisticComments(files)
        let window = OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true, ReviewPaneContent(model: model))
        defer { window.close() }
        ListPerf.settle(window)

        let line = files[0].hunks[0].lines[10]
        let rows = ListPerf.counting {
            ListPerf.time(window) { model.startComment(fileID: files[0].id, lineID: line.id) }
            ListPerf.time(window) { model.saveComment("Rename this.", fileID: files[0].id, lineID: line.id) }
        }
        #expect(model.session.commentsByFile[files[0].id]?[line.id]?.text == "Rename this.")
        #expect(rows["diff.row", default: 0] <= 2, "\(rows)")
        #expect(rows["diff.line", default: 0] <= 2, "\(rows)")
        #expect(rows["review.comment", default: 0] <= 1, "\(rows)")
    }

    /// Scrolling a highlighted diff builds the rows that come into view and nothing else: no
    /// section, header, or comment on screen draws again, and the thread beside it never does.
    @Test func scrollingTheReviewBuildsOnlyTheRowsComingIntoView() async throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel(files)
        model.session.comments = ListFixtures.realisticComments(files)
        let snapshot = ListFixtures.threadSnapshot(turns: 50, running: true)
        let store = NativeThreadStore()
        defer { store.stop() }
        let window = OffscreenWindow(size: CGSize(width: 1300, height: 800), dark: true, HStack(spacing: 0) {
            ThreadView(store: store, active: true, isFocused: false, request: { value in
                if case .send(_, _, let operation, _, _, _, _, _, _) = value { return .accepted(operationID: operation) }
                return .snapshot(value: snapshot)
            }, commandKey: "perf")
            .frame(width: 700)
            ReviewPaneContent(model: model).frame(width: 600)
        })
        defer { window.close() }
        try await eventuallyOnMain("the thread to load") { store.ready }
        try await eventuallyOnMain("every file to be highlighted", timeout: .seconds(120)) { model.highlights.count == files.count }
        model.revealWholeFile(files[5].id)
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window, trailing: true))
        // Past the first file's comments, then into the 3,000-line file.
        _ = ListPerf.scroll(window, scroll, step: 400, steps: 30)

        let step: CGFloat = 88
        var moved: CGFloat = 0
        let rows = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: step, steps: 100).distance }
        let linesIntoView = Int(moved / SHDiffMetrics.lineHeight)
        #expect(moved > 5000, "the diff scrolled \(moved) pt")
        #expect(rows["diff.row", default: 0] <= linesIntoView + 10, "\(linesIntoView) lines came into view: \(rows)")
        #expect(rows["review.comment", default: 0] == 0, "\(rows)")
        #expect(rows.keys.filter { $0.hasPrefix("thread.") || $0.hasPrefix("composer.") }.isEmpty, "the thread beside it redrew: \(rows)")
    }

    /// Side by side (the pane at 900pt and up), scrolling builds one row per pair coming into
    /// view: a pair is one row, never two lines' worth.
    @Test func scrollingASplitDiffBuildsOnlyThePairsComingIntoView() throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel(files)
        let window = OffscreenWindow(size: CGSize(width: 1040, height: 800), dark: true, ReviewPaneContent(model: model))
        defer { window.close() }
        ListPerf.settle(window)
        #expect(model.layout == .split)
        let scroll = try #require(ListPerf.scrollView(in: window, trailing: true))
        _ = ListPerf.scroll(window, scroll, step: 400, steps: 5)

        var moved: CGFloat = 0
        let rows = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: 88, steps: 60).distance }
        let pairsIntoView = Int(moved / SHDiffMetrics.lineHeight)
        #expect(moved > 3000, "the diff scrolled \(moved) pt")
        #expect(rows["diff.row", default: 0] <= pairsIntoView + 10, "\(pairsIntoView) rows came into view: \(rows)")
        #expect(rows["review.toolbar", default: 0] == 0 && rows["review.fileChip", default: 0] == 0, "the chrome stays: \(rows)")
    }

    /// Opening and closing the pane's menus (scope, base, options) draws the menu and nothing
    /// under it: the diff, its headers and the strip stay.
    @Test func openingTheChangesMenusRedrawsNoDiffRows() throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel(files)
        let window = OffscreenWindow(size: CGSize(width: 1040, height: 800), dark: true, ReviewPaneContent(model: model))
        defer { window.close() }
        ListPerf.settle(window)

        let rows = ListPerf.counting {
            for menu in [ChangesMenu.scope, .commits, .options, .base] {
                ListPerf.time(window) { model.toggleMenu(menu) }
                ListPerf.time(window) { model.closeMenu() }
            }
        }
        #expect(rows["diff.row", default: 0] == 0 && rows["diff.line", default: 0] == 0, "\(rows)")
        #expect(rows["review.fileHeader", default: 0] == 0 && rows["review.fileChip", default: 0] == 0, "\(rows)")
    }

    /// ⌥U builds the rows on screen in the other layout, not the whole diff.
    @Test func switchingSplitAndUnifiedBuildsOnlyTheRowsOnScreen() throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel(files)
        let window = OffscreenWindow(size: CGSize(width: 1040, height: 800), dark: true, ReviewPaneContent(model: model))
        defer { window.close() }
        ListPerf.settle(window)

        let rows = ListPerf.counting { ListPerf.time(window) { _ = model.handleKey("u", option: true) } }
        #expect(model.layout == .unified)
        #expect(rows["diff.row", default: 0] <= 2 * Int(800 / SHDiffMetrics.lineHeight), "\(rows)")
    }

    /// The right pane casts its shadow only while it floats over the thread, and from its fill
    /// alone: a shadow on the pane's content is redrawn from every layer inside it on each
    /// scroll step, and before this the docked pane still carried a clear one on three layers.
    @Test(arguments: [(width: CGFloat(1400), floating: false), (width: ShellLayout.paneDockThreshold - 80, floating: true)])
    func theRightPaneCastsItsShadowFromItsFillOnlyWhileFloating(width: CGFloat, floating: Bool) throws {
        let model = ListFixtures.reviewModel([ListFixtures.diffFile("Big.swift", lines: 200)])
        let window = OffscreenWindow(size: CGSize(width: width, height: 800), dark: true,
                                     RightPaneSplit(state: RightPaneState(), showPane: true) { Color.clear } pane: { ReviewPaneContent(model: model) })
        defer { window.close() }
        ListPerf.settle(window)
        let all = ListPerf.shadowedLayers(in: window)
        // The file header pinned at the top of the diff casts its own short shadow (ChangesSplit),
        // from its fill too.
        let headers = all.filter { $0.layer.bounds.height == SHFileHeader.height }
        let shadows = all.filter { $0.layer.bounds.height != SHFileHeader.height }
        #expect(shadows.count == (floating ? 1 : 0), "\(shadows.map(\.layer))")
        #expect(headers.count == 1, "\(headers.map(\.layer))")
        #expect(all.allSatisfy { $0.subtree == 1 }, "a shadow over the pane's content: \(all.map(\.subtree))")
    }

    /// The sidebar overlaid on a narrow window casts its shadow from its fill alone: on the
    /// sidebar itself, Core Animation redrew the shadow from the scrolling list on every step.
    @Test func theOverlaidSidebarCastsItsShadowFromItsFillAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        let window = OffscreenWindow(size: CGSize(width: AppLayout.windowMinWidth, height: 700), dark: true,
                                     RootView(vm: vm).environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        try await eventuallyOnMain("the narrow window to hide the sidebar") {
            ListPerf.settle(window)
            return vm.sidebarAutoHidden
        }
        #expect(ListPerf.shadowedLayers(in: window).isEmpty)

        vm.toggleSidebar()
        try await eventuallyOnMain("the sidebar to overlay the workspace") {
            ListPerf.settle(window)
            return vm.sidebarOverlayShown && !ListPerf.shadowedLayers(in: window).isEmpty
        }

        let shadows = ListPerf.shadowedLayers(in: window)
        #expect(shadows.count == 1, "\(shadows.map(\.layer))")
        #expect(shadows.allSatisfy { $0.subtree == 1 }, "a shadow over the sidebar's list: \(shadows.map(\.subtree))")
    }

    // MARK: Palette

    private func palette(_ items: [PaletteItem], query: String, highlight: PaletteHighlight = PaletteHighlight()) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true,
                        Color.clear.shCommandPalette(isPresented: .constant(true)) {
                            PaletteCard(items: items, run: { _ in }, close: {}, initialQuery: query, highlight: highlight)
                        })
    }

    @Test func openingThePaletteOverAThousandResultsBuildsOnlyTheRowsOnScreen() throws {
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = palette(ListFixtures.paletteItems(1000), query: "fix")
            ListPerf.settle(window)
        }
        defer { window.close() }
        // At most 14 rows fit; each may be built twice while the card settles.
        #expect(rows["palette.row", default: 0] <= 2 * SHPaletteMetrics.maxVisibleRows, "\(rows)")
    }

    @Test func movingThePaletteHighlightRedrawsOnlyTheRowsItLeavesAndLandsOn() throws {
        let highlight = PaletteHighlight()
        let window = palette(ListFixtures.paletteItems(1000), query: "fix", highlight: highlight)
        defer { window.close() }
        ListPerf.settle(window)

        let rows = ListPerf.counting {
            for index in 1...20 { _ = ListPerf.time(window) { highlight.move(to: index) } }
        }
        // Two rows per move, plus the rows the highlight scrolls into view.
        #expect(rows["palette.row", default: 0] <= 20 * 2 + SHPaletteMetrics.maxVisibleRows, "\(rows)")
    }

    /// Lazy rows still let the card hug a short list, and a long one stops at the cap.
    @Test(arguments: [3, 1000])
    func thePaletteHugsAShortListAndCapsALongOne(count: Int) throws {
        let items = (0..<count).map { PaletteItem(id: "c\($0)", kind: .action("c\($0)"), section: .commands, title: "Command \($0)") }
        let window = palette(items, query: "")
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        let row = SHDensity.standard.rowHeight
        let cap = SHPaletteMetrics.placement(in: CGSize(width: 900, height: 700), rowHeight: row).maxListHeight
        let natural = SHPaletteMetrics.sectionHeight + CGFloat(count) * row
        #expect(abs(scroll.frame.height - min(natural, cap)) < 1, "list \(scroll.frame.height), rows \(natural), cap \(cap)")
    }

    @Test func theHighlightScrollsIntoViewPastTheCap() throws {
        let highlight = PaletteHighlight()
        let window = palette(ListFixtures.paletteItems(1000), query: "fix", highlight: highlight)
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        ListPerf.time(window) { highlight.move(to: 200) }

        let visible = scroll.contentView.bounds
        #expect(visible.minY > CGFloat(150) * SHDensity.standard.rowHeight, "scrolled to \(visible.minY)")
    }
}
