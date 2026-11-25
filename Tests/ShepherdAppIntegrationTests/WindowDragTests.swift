import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What dragging the window's edge costs, counted: the layouts out of sight take no pass in it, the threads out of sight do not
/// hear of it, and the history above the tail the reader follows is not drawn in it. Counts hold on a busy runner; timings don't.
@Suite("Dragging the window's edge", .mainActorExclusive)
@MainActor
struct WindowDragTests {
    private struct Workspace: View {
        let vm: ShepherdViewModel
        let state: AgentDeckResizeTests.State

        var body: some View {
            AgentLayoutDeck(vm: vm, models: state.models, frozenSize: state.frozenSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Hidden hosts take no layout pass while the window is dragged, whatever marks them for one on each frame (SwiftUI does: a hosting
    /// view watches its geometry in the window), and each takes the one it owes after the drag, a turn of the run loop apart.
    @Test func hiddenLayoutsTakeNoPassInADragAndOneAfterIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let state = AgentDeckResizeTests.State(count: 5)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, Workspace(vm: vm, state: state))
        defer { window.close() }
        let deck = try WorkspaceNavigationTests.deck(in: window)
        let entries = try state.tabs.map { try #require(deck.pages[$0.id]) }
        for index in state.tabs.indices {
            state.selected = index
            ListPerf.settle(window)
        }
        state.selected = 0
        for _ in 0..<3 { ListPerf.settle(window) }
        let hidden = entries.dropFirst().map(\.host)
        #expect(hidden.allSatisfy { $0.isHidden })

        // AppKit tells every view of the window that a live resize began, and marks the hidden ones for layout as the window moves.
        for entry in entries { entry.host.viewWillStartLiveResize() }
        let steps = 8
        let dragged = ListPerf.counting {
            for step in 1...steps {
                window.window.setContentSize(CGSize(width: 1200 - CGFloat(step) * 24, height: 800 - CGFloat(step) * 10))
                for host in hidden {
                    host.needsLayout = true
                    host.layoutSubtreeIfNeeded()
                }
                ListPerf.settle(window)
            }
        }
        #expect(dragged["deck.layout", default: 0] >= steps, "the layout on screen followed the drag: \(dragged)")
        #expect(dragged["deck.hiddenLayout", default: 0] == 0, "no hidden layout took a pass: \(dragged)")
        #expect(dragged["deck.heldLayout", default: 0] >= hidden.count, "each held its pass back: \(dragged)")
        #expect(hidden.allSatisfy { $0.frame.size != deck.bounds.size }, "and none was resized")

        SHRenderProbe.start()
        for entry in entries { entry.host.viewDidEndLiveResize() }
        deck.viewDidEndLiveResize()
        try await eventuallyOnMain("every hidden layout to take the pass it owes") {
            ListPerf.settle(window)
            return SHRenderProbe.count("deck.hiddenLayout") >= hidden.count
        }
        ListPerf.settle(window)
        let after = SHRenderProbe.stop()
        #expect(after["deck.hiddenLayout", default: 0] == hidden.count, "once each: \(after)")
    }

    /// The remote deck shares the local one's host and its catch-up (`DeckHost`, `DeckCatchUp`): its hidden pages hold their passes back
    /// through a drag, the shown page follows it, and each hidden page takes the one it owes once the drag ends.
    @Test func hiddenRemotePagesTakeNoPassInADragAndOneAfterIt() async throws {
        let rig = try await RemoteDeckTests.Rig()
        defer { rig.close() }
        _ = try await rig.firstVisit(0)
        _ = try await rig.firstVisit(1)
        _ = try await rig.show(0)
        try await rig.holdStill()
        let deck = try rig.deck()
        let shown = try #require(try rig.host(0))
        let hidden = try #require(try rig.host(1))
        #expect(!shown.isHidden && hidden.isHidden)

        shown.viewWillStartLiveResize()
        hidden.viewWillStartLiveResize()
        let steps = 8
        let dragged = ListPerf.counting {
            for step in 1...steps {
                rig.window.window.setContentSize(CGSize(width: 1200 - CGFloat(step) * 24, height: 800 - CGFloat(step) * 10))
                hidden.needsLayout = true
                hidden.layoutSubtreeIfNeeded()
                ListPerf.settle(rig.window)
            }
        }
        #expect(dragged["remoteDeck.layout", default: 0] >= steps, "the page on screen followed the drag: \(dragged)")
        #expect(dragged["remoteDeck.hiddenLayout", default: 0] == 0, "the hidden page took no pass: \(dragged)")
        #expect(dragged["remoteDeck.heldLayout", default: 0] >= steps, "it held each one back: \(dragged)")
        #expect(hidden.frame.size != deck.bounds.size, "and was not resized")

        SHRenderProbe.start()
        shown.viewDidEndLiveResize()
        hidden.viewDidEndLiveResize()
        deck.viewDidEndLiveResize()
        try await eventuallyOnMain("the hidden page to take the pass it owes") {
            ListPerf.settle(rig.window)
            return SHRenderProbe.count("remoteDeck.hiddenLayout") >= 1
        }
        ListPerf.settle(rig.window)
        let after = SHRenderProbe.stop()
        #expect(after["remoteDeck.hiddenLayout", default: 0] == 1, "once: \(after)")
        #expect(!hidden.owesPass, "and owes none")
    }

    /// A thread out of sight is not touched by the window's drag: its two changes (the drag's start and its end) would only rebuild
    /// every row of its eager tail, and nothing there is drawn. The drag reaches the thread on screen alone.
    @Test func hiddenThreadsDoNotHearOfTheDrag() async throws {
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

        let counts = ListPerf.counting {
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window.window)
            ListPerf.settle(window)
            for step in 1...6 {
                window.window.setContentSize(NSSize(width: 1400 - CGFloat(step) * 16, height: 800))
                ListPerf.settle(window)
            }
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window.window)
            ListPerf.settle(window)
        }
        // The layout on screen reads it at the drag's start and at its end; the five hidden ones would add ten more.
        #expect(counts["thread.view", default: 0] <= agents.count, "\(counts)")
    }

    private func builtRows(in view: NSView) -> Int {
        (view is ThreadTailGuard.RowMarker ? 1 : 0) + view.subviews.reduce(0) { $0 + builtRows(in: $1) }
    }

    private func documentHeight(_ scroll: NSScrollView) -> CGFloat { scroll.documentView?.frame.height ?? 0 }

    /// The two ways a drag can leave the tail: what covers the window while it is dragged is fewer rows than the tail at rest (it
    /// grows back in steps once the drag ends), or the same rows (nothing grows back, and the end of the drag changes nothing that the
    /// thread reads but the drag itself).
    enum Shape: CaseIterable, CustomTestStringConvertible {
        case longReplies, shortRows

        var testDescription: String {
            switch self {
            case .longReplies: "replies of a few paragraphs in an ordinary window"
            case .shortRows: "one-line rows in a tall window"
            }
        }

        var size: CGSize {
            switch self {
            case .longReplies: CGSize(width: 900, height: 800)
            // Tall enough that the rows covering it are more than the tail's cap (`ThreadView.eagerRows`).
            case .shortRows: CGSize(width: 900, height: 1600)
            }
        }

        /// A thread of `count` messages: a question and its answer, in paragraphs or in a line.
        func messages(_ count: Int) -> [NativeThreadMessage] {
            switch self {
            case .longReplies: ThreadFixture.history(count)
            case .shortRows:
                (0..<count).map { i in
                    i.isMultiple(of: 2) ? ThreadFixture.user("m\(i)", "Question \(i / 2)") : ThreadFixture.assistant("m\(i)", "Answer \(i / 2).")
                }
            }
        }
    }

    /// The reader at the tail reads none of the history while the window is dragged, and the tail covers the window: the history is not
    /// laid out, row by row, at every width the drag passes through. It is back when the drag ends, and the tail grows back with it: with
    /// no scroll and no update of the thread to bring it, whether the tail has anything to grow back to or not.
    @Test(arguments: Shape.allCases)
    func theHistoryStandsDownWhileFollowingTheTailThroughADrag(_ shape: Shape) async throws {
        let thread = FakeThread(ThreadFixture.snapshot(shape.messages(ThreadView.eagerRows * 4)), size: shape.size)
        try await thread.waitUntilReady()
        defer { thread.close() }
        let scroll = try #require(thread.scrollView)
        let cover = AppLayout.eagerCoverHeight(forViewport: scroll.bounds.height)
        let tail = thread.store.eagerRowCount(coveringHeight: cover, maxRows: ThreadView.eagerRows)
        let resting = thread.store.eagerTailRows(maxRows: ThreadView.eagerRows, costCap: NativeMountedCost.eagerTailCap,
                                                 coveringHeight: AppLayout.eagerTailHeight(cover: cover))
        switch shape {
        case .longReplies: #expect(tail < resting, "the tail grows back after the drag: \(tail) rows cover the window, \(resting) at rest")
        case .shortRows: #expect(tail == resting, "the tail has nothing to grow back to: \(tail) rows cover the window, \(resting) at rest")
        }
        let full = builtRows(in: thread.window.host)
        let fullHeight = documentHeight(scroll)

        thread.visibility.liveResizing = true
        ListPerf.settle(thread.window)
        let live = builtRows(in: thread.window.host)
        let parkedHeight = documentHeight(scroll)
        #expect(live <= tail, "only the tail is built while the window is dragged: \(live) built, the tail covers it in \(tail) rows (\(full) at rest)")
        #expect(fullHeight - parkedHeight > 500, "the history above the tail is out of the document: \(parkedHeight) of \(fullHeight)")
        let dragged = ListPerf.counting {
            for step in 1...8 {
                thread.window.window.setContentSize(NSSize(width: shape.size.width - CGFloat(step) * 30, height: shape.size.height))
                ListPerf.settle(thread.window)
            }
        }
        #expect(dragged["thread.rowBuilder", default: 0] == 0, "no row is built in the steps of a drag: \(dragged)")
        #expect(builtRows(in: thread.window.host) <= tail)

        // Taller or shorter only: no row's body runs, and no prose is built again, once the drag has been over the tallest it gets (the
        // tail covers what the window shows, and a drag only widens that).
        for height in [shape.size.height + 160, shape.size.height] {
            thread.window.window.setContentSize(NSSize(width: shape.size.width - 8 * 30, height: height))
            ListPerf.settle(thread.window)
        }
        let taller = ListPerf.counting {
            for step in 1...8 {
                thread.window.window.setContentSize(NSSize(width: shape.size.width - 8 * 30, height: shape.size.height + CGFloat(step % 4) * 40))
                ListPerf.settle(thread.window)
            }
        }
        for key in ["thread.rowBuilder", "thread.userTurn", "thread.agentTurn", "prose.block"] {
            #expect(taller[key, default: 0] == 0, "\(key) in the steps of a drag in height: \(taller)")
        }

        thread.visibility.liveResizing = false
        try await eventuallyOnMain("the tail back at its size") {
            ListPerf.settle(thread.window)
            return builtRows(in: thread.window.host) >= min(full, ThreadView.eagerRows)
        }
        // The history is back with it, and the reader has done nothing: it stands in the document again.
        try await eventuallyOnMain("the history above the tail back in the document") {
            ListPerf.settle(thread.window)
            return documentHeight(scroll) - parkedHeight > (fullHeight - parkedHeight) / 2
        }

        // A drag that only widens the window again: the height it ended at is the one the thread has, so the drag's end tells the thread
        // nothing but that it ended. The history is back all the same, with no scroll and no update of the thread to bring it.
        thread.visibility.liveResizing = true
        ListPerf.settle(thread.window)
        let parkedAgain = documentHeight(scroll)
        #expect(fullHeight - parkedAgain > 500, "the history is out of the document again: \(parkedAgain) of \(fullHeight)")
        for step in 1...8 {
            thread.window.window.setContentSize(NSSize(width: shape.size.width - CGFloat(8 - step) * 30, height: shape.size.height))
            ListPerf.settle(thread.window)
        }
        thread.visibility.liveResizing = false
        try await eventuallyOnMain("the history above the tail back in the document after a drag in width alone") {
            ListPerf.settle(thread.window)
            return documentHeight(scroll) - parkedAgain > (fullHeight - parkedAgain) / 2
        }

        // And a reader who scrolls up to it finds its rows built.
        let tailRows = builtRows(in: thread.window.host)
        let clip = scroll.contentView
        for _ in 0..<12 {
            thread.input.readerScrolled(upward: true)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - 600), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(thread.window)
        }
        #expect(builtRows(in: thread.window.host) > tailRows, "the history above the tail is laid out again for a reader who scrolls to it")
    }
}
