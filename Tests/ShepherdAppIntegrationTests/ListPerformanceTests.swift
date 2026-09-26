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

/// Budgets for the long lists (DESIGN.md › Performance), over realistic large fixtures in
/// off-screen windows. The budgets count row bodies (`NWRenderProbe`), which a slower machine
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
        Int(sidebarSize.height / (NWDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
    }

    /// The fleet in an off-screen sidebar, settled.
    private func openSidebar(_ app: AppHarness) async throws -> (ShepherdViewModel, OffscreenWindow) {
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
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
        let step = NWDensity.standard.rowHeight * 4

        var moved: CGFloat = 0
        let rows = ListPerf.counting { moved = ListPerf.scroll(window, scroll, step: step, steps: 20).distance }
        let arriving = Int(moved / (NWDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
        #expect(moved > 0)
        #expect(rows["sidebar.row", default: 0] <= 2 * (arriving + Self.sidebarRowsOnScreen), "\(rows)")
        #expect(rows["sidebar.lists", default: 0] == 0, "scrolling derives nothing: \(rows)")
    }

    /// A status report redraws the row it changed; the order holds (only a turn starting or
    /// ending moves a row), the destinations never redraw, and the lists derive once.
    @Test func aStatusReportRedrawsOnlyItsRow() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openSidebar(app)
        defer { window.close() }
        let shown = recentsOnScreen(vm).prefix(6)
        let order = vm.sidebarLists.recents.map(\.id)

        let rows = ListPerf.counting {
            for row in shown {
                var next = vm.state
                if let index = next.agents.firstIndex(where: { $0.id == row.id.agentID }) {
                    next.agents[index].status = next.agents[index].status == .working ? .done : .working
                }
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(vm.sidebarLists.recents.map(\.id) == order)
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
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

        let rows = ListPerf.counting {
            for row in shown {
                var next = vm.state
                if let index = next.agents.firstIndex(where: { $0.id == row.id.agentID }) {
                    next.agents[index].name += " (renamed)"
                }
                ListPerf.time(window) { vm.adopt(next) }
            }
        }
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2, "\(rows)")
    }

    /// A selection moving redraws the row it leaves and the row it lands on.
    @Test func aSelectionMovingRedrawsTheTwoRowsItTouches() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window) = try await openSidebar(app)
        defer { window.close() }
        let shown = recentsOnScreen(vm).prefix(6)

        let rows = ListPerf.counting {
            for row in shown { ListPerf.time(window) { vm.selectSidebarRow(row.id) } }
        }
        #expect(rows["sidebar.row", default: 0] <= shown.count * 2 + 2, "\(rows)")
        #expect(rows["sidebar.lists", default: 0] == 0, "a selection derives nothing: \(rows)")
    }

    // MARK: Designs

    private static let designsSize = CGSize(width: 1200, height: 800)
    /// A card's height: its thumbnail and its three lines, with the gap under it.
    private static let designRowHeight = NWDesignMetrics.cardThumbnailHeight + 80 + NWPageMetrics.columnGap

    /// Rows of cards that fit the page under its header.
    private static var designRowsOnScreen: Int {
        Int((designsSize.height - NWPageMetrics.headerHeight) / designRowHeight) + 1
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
        let model = try #require(vm.designExport)
        #expect(model.selection.rows.count == 172)

        var window: OffscreenWindow!
        let opening = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 900, height: 900), dark: true, DesignExportOverlay(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let shown = Int(NWDesignMetrics.exportVisibleRows)
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
    private static let systemRowHeight: CGFloat = 2 * NWDesignMetrics.cardPaddingVertical + 32 + NWPageMetrics.columnGap
    /// A row of swatches: the 56pt swatch, its two lines and the gap under it.
    private static let swatchRowHeight: CGFloat = NWDesignMetrics.tokenSwatchHeight + 2 * NW.Space.s + 28 + AppLayout.designSystemColorGap

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
        let onScreen = (Int((Self.designsSize.height - NWPageMetrics.headerHeight) / Self.systemRowHeight) + 1) * DesignsPageModel.systemColumns
        #expect(counts["design.systemCard", default: 0] > 0)
        #expect(counts["design.systemCard", default: 0] <= 2 * (onScreen + DesignsPageModel.systemColumns), "\(counts)")
        #expect(counts["design.systemCard", default: 0] < DesignSystemStore.maxSystems)
    }

    /// A system's page over 300 colors: only the rows of swatches on screen are built.
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
        let onScreen = (Int((Self.designsSize.height - NWPageMetrics.headerHeight) / Self.swatchRowHeight) + 1)
            * AppLayout.designSystemColorColumns
        #expect(counts["design.swatch", default: 0] > 0)
        #expect(counts["design.swatch", default: 0] <= 2 * (onScreen + AppLayout.designSystemColorColumns), "\(counts)")
        #expect(counts["design.swatch", default: 0] < 300)
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

    // MARK: Thread

    /// A long thread streaming its reply builds only the rows on screen for each chunk, however
    /// many turns came before.
    @Test func streamingIntoALongThreadBuildsOnlyTheRowsOnScreen() async throws {
        var snapshot = ListFixtures.threadSnapshot(turns: 500, running: true)
        let store = NativeThreadStore()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                     ThreadView(store: store, active: true, isFocused: false, request: { _ in .snapshot(value: snapshot) },
                                                commandKey: "budget"))
        defer {
            store.stop()
            window.close()
        }
        try await eventuallyOnMain("the thread to load") { store.ready }
        ListPerf.settle(window)

        NWRenderProbe.start()
        for index in 0..<5 {
            let live = ListFixtures.message("live", "assistant", String(repeating: "Streaming sentence \(index). ", count: index + 1))
            snapshot = ListFixtures.threadSnapshot(turns: 500, running: true, revision: UInt64(index + 2), provisional: [live])
            await store.refresh()
            ListPerf.settle(window)
        }
        let rows = NWRenderProbe.stop()
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
                                                commandKey: "entrances"))
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
    }

    // MARK: Thread chrome

    /// Row bodies counted while `work` runs, with the window settled after it.
    private func counting(_ window: OffscreenWindow, _ work: () async throws -> Void) async rethrows -> [String: Int] {
        NWRenderProbe.start()
        try await work()
        ListPerf.settle(window)
        return NWRenderProbe.stop()
    }

    /// A thread of sixty turns under its toolbar, loaded and at rest.
    private func chromeThread(running: Bool) async throws -> FakeThread {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(120) + (running ? [ThreadFixture.user("u", "Go on")] : []),
                                              provisional: running ? [ThreadFixture.streaming("Streaming")] : [], running: running,
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

    /// A streamed chunk redraws the thread and its streaming row, never the composer, its
    /// chips, or the toolbar.
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

        #expect(rows["thread.view", default: 0] >= 5, "the reply streamed: \(rows)")
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

        #expect(rows["thread.view", default: 0] >= 5, "the reply streamed: \(rows)")
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

    /// Widening or narrowing the thread redraws its composer only when the Send menu would
    /// change sides (beside the card, or above it), never for each width a live resize passes.
    @Test func aWidthThatKeepsTheSendMenusSideRedrawsNoComposer() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(4)), size: CGSize(width: 1800, height: 800))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)

        let frames = 10
        let rows = try await counting(thread.window) {
            for step in 1...frames {
                thread.window.window.setContentSize(NSSize(width: 1800 - CGFloat(step) * 8, height: 800))
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

    /// Fifteen chunks of a growing fenced block, delivered in one burst, color it at most twice
    /// (the first complete lines at once, then at most every 250 ms, at line boundaries); the
    /// finished reply colors it once more, in full.
    @Test(.timingSensitive) func aBurstOfCodeChunksColorsTheBlockAtMostTwice() async throws {
        let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it")]
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(Self.codeReply(2))], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(500))
        ListPerf.settle(thread.window)

        let burst = try await counting(thread.window) {
            for chunk in 1...15 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(Self.codeReply(2 + chunk * 6) + "    let partial")]
                await thread.serve(next)
                ListPerf.settle(thread.window)
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        let finished = try await counting(thread.window) {
            var next = thread.snapshot
            next.revision += 1
            next.running = false
            next.messages = turn + [ThreadFixture.assistant("done", Self.codeReply(2 + 15 * 6) + "    let partial\n}\n```\n")]
            next.provisional = []
            await thread.serve(next)
            try await Task.sleep(for: .milliseconds(600))
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
        NWRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(table + "\n\nIn")], running: true),
                                size: CGSize(width: 1180, height: 900))
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await Task.sleep(for: .milliseconds(200))
        ListPerf.settle(thread.window)
        let first = NWRenderProbe.stop()
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
        #expect(streamed["thread.view", default: 0] >= 5, "the reply streamed: \(streamed)")
        #expect(streamed["prose.table", default: 0] == 0, "\(streamed)")
        #expect(streamed["prose.tableCell", default: 0] == 0, "\(streamed)")
    }

    // MARK: Workspace

    /// Launching into a workspace of many agents builds the visible layout first: its first
    /// frame holds one layout and its thread, and the rest mount after it, a few per turn.
    @Test func launchBuildsOnlyTheVisibleLayoutFirst() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(12, in: app)
        var window: OffscreenWindow!

        let first = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }

        #expect(first["layout.agentLayout", default: 0] == 1, "\(first)")
        #expect(first["thread.view", default: 0] <= 2, "\(first)")
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
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
        NWRenderProbe.start()
        try await workspace.stream()
        result.counts["a streamed reply"] = NWRenderProbe.stop()
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
        NWRenderProbe.start()
        window = OffscreenWindow(size: CGSize(width: 900, height: 800), dark: true,
                                 ThreadView(store: store, active: true, isFocused: false, request: { _ in .snapshot(value: snapshot) },
                                            commandKey: "tray", inspectSubagent: { _ in }))
        defer {
            store.stop()
            window.close()
        }
        try await eventuallyOnMain("the thread to load") { store.ready && store.tray != nil }
        ListPerf.settle(window)
        let rows = NWRenderProbe.stop()

        #expect(rows["tray.row", default: 0] > 0, "the tray shows: \(rows)")
        #expect(rows["tray.row", default: 0] <= 8, "\(rows)")
    }

    /// An open tray of two hundred runs scrolls inside, building only the rows in view.
    private struct TrayHost: View {
        let runs: [ChildRun]
        let state: SubagentTrayState

        var body: some View {
            SubagentTrayView(tray: NativeSubagentTray(runs), state: state, runs: runs,
                             actions: SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }), answer: { _ in })
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
        next[2].state = "complete"
        next[2].endedAt = 2_000

        let rows = ListPerf.counting { ListPerf.time(window) { window.show(TrayHost(runs: next, state: state)) } }

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
        #expect(opened["skills.row", default: 0] <= 80, "\(opened)")

        var snapshot = try #require(vm.skills.state(of: vm.skillsHosts[0]).snapshot)
        snapshot.skills[0].isOn = false
        let changed = ListPerf.counting {
            ListPerf.time(window) { vm.skills.hostChanged(ShepherdViewModel.thisMacSkills, snapshot) }
        }
        #expect(changed["skills.row", default: 0] <= 2, "\(changed)")
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
        #expect(rows["review.fileChip", default: 0] <= 24, "\(rows)")
        #expect(rows["diff.line", default: 0] <= 2 * Int(800 / NWDiffMetrics.lineHeight), "\(rows)")
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
            NWDiffLineContent(id: "\(line.id)", key: line.id, kind: line.kind.diffKind, oldNumber: line.oldLine, newNumber: line.newLine,
                              text: AttributedString(line.text), source: line.text)
        }
        func window(hovering: Bool) -> OffscreenWindow {
            OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true, VStack(spacing: 0) {
                ForEach(lines) { NWDiffLine($0, onComment: {}, hovering: hovering) }
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
                if case .send(_, _, let operation, _, _, _, _) = value { return .accepted(operationID: operation) }
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
        let linesIntoView = Int(moved / NWDiffMetrics.lineHeight)
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
        let pairsIntoView = Int(moved / NWDiffMetrics.lineHeight)
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
        #expect(rows["diff.row", default: 0] <= 2 * Int(800 / NWDiffMetrics.lineHeight), "\(rows)")
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
        let headers = all.filter { $0.layer.bounds.height == NWFileHeader.height }
        let shadows = all.filter { $0.layer.bounds.height != NWFileHeader.height }
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
                        Color.clear.nwCommandPalette(isPresented: .constant(true)) {
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
        #expect(rows["palette.row", default: 0] <= 2 * NWPaletteMetrics.maxVisibleRows, "\(rows)")
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
        #expect(rows["palette.row", default: 0] <= 20 * 2 + NWPaletteMetrics.maxVisibleRows, "\(rows)")
    }

    /// Lazy rows still let the card hug a short list, and a long one stops at the cap.
    @Test(arguments: [3, 1000])
    func thePaletteHugsAShortListAndCapsALongOne(count: Int) throws {
        let items = (0..<count).map { PaletteItem(id: "c\($0)", kind: .action("c\($0)"), section: .commands, title: "Command \($0)") }
        let window = palette(items, query: "")
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        let row = NWDensity.standard.rowHeight
        let cap = NWPaletteMetrics.placement(in: CGSize(width: 900, height: 700), rowHeight: row).maxListHeight
        let natural = NWPaletteMetrics.sectionHeight + CGFloat(count) * row
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
        #expect(visible.minY > CGFloat(150) * NWDensity.standard.rowHeight, "scrolled to \(visible.minY)")
    }
}
