import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Agent deck resizing", .mainActorExclusive)
@MainActor
struct AgentDeckResizeTests {
    /// Real deck hosts with inert review placeholders: no pi, terminal, input or focus changes.
    /// The leading inset changes the workspace column just as a docked sidebar does.
    @Observable final class State {
        let tabs: [ShepherdCore.Tab]
        var selected: Int? = 0
        var frozenSize: CGSize?
        var sidebarWidth: CGFloat = 0

        init(count: Int) {
            let space = SpaceID()
            tabs = (0..<count).map {
                ShepherdCore.Tab(spaceID: space, order: $0, layout: .leaf(LeafPane(cwd: "/tmp", isReview: true)))
            }
        }

        var models: [AgentLayoutModel] {
            tabs.enumerated().map { index, tab in
                AgentLayoutModel(tab: tab, isVisible: index == selected, thread: nil,
                                 focusedPaneID: nil, inspectingRunID: nil, review: nil)
            }
        }
    }

    private struct Workspace: View {
        let vm: ShepherdViewModel
        let state: State

        var body: some View {
            AgentLayoutDeck(vm: vm, models: state.models, frozenSize: state.frozenSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, state.sidebarWidth)
        }
    }

    /// Give every host a real last-displayed size before measuring hidden behavior.
    private func visitEveryHost(_ state: State, in window: OffscreenWindow) {
        for index in state.tabs.indices {
            state.selected = index
            ListPerf.settle(window)
        }
        state.selected = 0
        for _ in 0..<3 { ListPerf.settle(window) }
    }

    @Test func initiallyHiddenHostsReceiveOneUsableSizeBeforeBeingVisited() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let state = State(count: 3)
        state.selected = nil
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                     Workspace(vm: vm, state: state))
        defer { window.close() }
        ListPerf.settle(window)
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let entries = try state.tabs.map { try #require(deck.pages[$0.id]) }
        #expect(!deck.bounds.isEmpty)
        let initial = entries.map { $0.host.frame }
        #expect(initial.allSatisfy { !$0.isEmpty }, "restored hidden hosts need usable initial bounds")
        #expect(entries.allSatisfy { $0.host.isHidden })
        window.window.setContentSize(CGSize(width: 900, height: 600))
        ListPerf.settle(window)
        #expect(entries.map { $0.host.frame } == initial, "initial sizing is not repeated during later resizes")
        state.selected = 1
        ListPerf.settle(window)
        #expect(entries[1].host.frame == deck.bounds)
        #expect(entries[0].host.frame == initial[0] && entries[2].host.frame == initial[2])
    }

    @Test func aWindowlessZeroSizedPassDoesNotConsumeTheHiddenThreadsInitialLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(1, in: app)
        let page = AgentLayoutDeck.Page(vm: vm, model: AgentLayoutModel.Resolver(vm: vm, visibleTabID: nil)
            .model(for: agents[0].tab))
        let host = AgentLayoutDeck.Host(rootView: AgentLayoutDeck.PageRoot(page: page))
        host.isHidden = true
        host.frame = .zero
        #expect(host.window == nil && host.bounds.isEmpty)
        host.layout()

        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true)
        defer { window.close() }
        window.host.addSubview(host)
        host.frame = window.host.bounds
        let counts = ListPerf.counting {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            ListPerf.settle(window)
        }
        #expect(counts["deck.hiddenLayout", default: 0] > 0,
                "the first usable in-window pass must reach SwiftUI, even after an early zero-size pass")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        try await eventuallyOnMain("the hidden real thread's native surfaces to mount") {
            ListPerf.settle(window)
            return scrollViews(host).contains { !$0.bounds.isEmpty }
        }
        #expect(host.isHidden, "mounting hidden surfaces must not reveal or focus the agent")
    }

    @Test(arguments: [0, 16])
    func hiddenHostsKeepTheirBoundsAcrossWindowAndSidebarResizes(hidden: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let state = State(count: hidden + 1)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, Workspace(vm: vm, state: state))
        defer { window.close() }
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let entries = try state.tabs.map { try #require(deck.pages[$0.id]) }
        visitEveryHost(state, in: window)
        let initial = entries.map { $0.host.bounds }
        let order = deck.subviews.map(ObjectIdentifier.init)
        let counts = ListPerf.counting {
            // Ordinary resizing, live resizing, its completion, and side-pane/sidebar changes
            // all leave hidden bounds alone. In particular, clearing frozenSize does no work.
            for frozen in [false, true, false] {
                state.frozenSize = frozen ? deck.bounds.size : nil
                for step in 1...8 {
                    state.sidebarWidth = CGFloat(step % 3) * 80
                    window.window.setContentSize(CGSize(width: 1200 - CGFloat(step) * 12,
                                                        height: 800 - CGFloat(step) * 6))
                    ListPerf.settle(window)
                    #expect(entries[0].host.frame == deck.bounds)
                    for index in 1..<entries.count {
                        #expect(entries[index].host.bounds == initial[index])
                        #expect(entries[index].host.isHidden)
                    }
                }
            }
        }
        #expect(counts["deck.layout", default: 0] > 0, "the foreground really resized: \(counts)")
        // Native callbacks may finish hidden content transitions. The per-step bounds
        // assertions protect resize isolation without blocking AppKit cleanup.
        #expect(deck.subviews.map(ObjectIdentifier.init) == order)
        for (index, tab) in state.tabs.enumerated() {
            #expect(deck.pages[tab.id]?.page === entries[index].page)
            #expect(deck.pages[tab.id]?.host === entries[index].host)
        }
        let accessible = deck.accessibilityChildren() as? [NSView]
        #expect(accessible?.count == 1)
        #expect(accessible?.first === entries[0].host)
    }

    @Test func revealingSizesTheSameHostBeforeUnhidingAndKeepsTheOutgoingSize() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let state = State(count: 3)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, Workspace(vm: vm, state: state))
        defer { window.close() }
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let entries = try state.tabs.map { try #require(deck.pages[$0.id]) }
        visitEveryHost(state, in: window)
        let initial = deck.bounds
        let order = deck.subviews.map(ObjectIdentifier.init)
        state.frozenSize = initial.size
        window.window.setContentSize(CGSize(width: 1000, height: 700))
        ListPerf.settle(window)
        let narrow = deck.bounds
        #expect(narrow != initial)
        #expect(entries.map { $0.host.frame } == [narrow, initial, initial])

        let incoming = entries[1].host
        incoming.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                           object: incoming, queue: nil) { _ in
            MainActor.assumeIsolated {
                #expect(incoming.isHidden, "resize must happen before unhide, not on a later layout pass")
                #expect(incoming.frame == deck.bounds)
            }
        }
        state.selected = 1
        ListPerf.settle(window)
        NotificationCenter.default.removeObserver(token)
        #expect(!incoming.isHidden)
        #expect(entries.map { $0.host.frame } == [narrow, narrow, initial])

        state.frozenSize = nil
        ListPerf.settle(window)
        #expect(entries.map { $0.host.frame } == [narrow, narrow, initial], "no catch-up at live resize end")
        state.sidebarWidth = 160
        ListPerf.settle(window)
        let column = deck.bounds
        #expect(column.width < narrow.width)
        #expect(entries.map { $0.host.frame } == [narrow, column, initial])
        state.selected = 2
        ListPerf.settle(window)
        #expect(entries.map { $0.host.frame } == [narrow, column, column])
        state.selected = nil
        ListPerf.settle(window)
        window.window.setContentSize(CGSize(width: 1400, height: 900))
        ListPerf.settle(window)
        #expect(entries.map { $0.host.frame } == [narrow, column, column], "no visible page means no host resize")
        #expect(deck.accessibilityChildren()?.isEmpty == true)
        #expect(deck.hitTest(CGPoint(x: 20, y: 20)) == nil)
        state.selected = 0
        ListPerf.settle(window)
        #expect(entries[0].host.frame == deck.bounds)
        #expect(deck.subviews.map(ObjectIdentifier.init) == order)
        for (index, tab) in state.tabs.enumerated() {
            #expect(deck.pages[tab.id]?.page === entries[index].page)
            #expect(deck.pages[tab.id]?.host === entries[index].host)
        }
    }

    /// Informational main-thread CPU, not a machine-dependent timing budget. Compare 0 and 16
    /// hidden hosts using exactly the same real hosting views and resize sequence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
    func reportCPU() async throws {
        let report = PerfReport()
        for hidden in [0, 16] {
            let app = try AppHarness()
            defer { app.stop() }
            let vm = try await app.start()
            let state = State(count: hidden + 1)
            let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, Workspace(vm: vm, state: state))
            defer { window.close() }
            visitEveryHost(state, in: window)
            let deck = try WorkspaceNavigationTests.deck(in: window)
            let hiddenHosts = try state.tabs.dropFirst().map { try #require(deck.pages[$0.id]?.host) }
            let hiddenBounds = hiddenHosts.map(\.bounds)
            var cpu: [Double] = []
            SHRenderProbe.start()
            for step in 0..<48 {
                cpu.append(await MainThreadCPU.milliseconds {
                    state.sidebarWidth = CGFloat(step % 3) * 80
                    window.window.setContentSize(CGSize(width: 1200 - CGFloat(step % 12) * 8, height: 800))
                    ListPerf.settle(window)
                })
            }
            let counts = SHRenderProbe.stop()
            #expect(hiddenHosts.map(\.bounds) == hiddenBounds)
            #expect(counts["deck.layout", default: 0] > 0)
            report.add("deck resize (\(hidden) hidden)", "main-thread CPU per step (median)", ms: MainThreadCPU.median(cpu))
            report.add("deck resize (\(hidden) hidden)", "48 window/column resize steps", counts: counts)
        }
    }
}
