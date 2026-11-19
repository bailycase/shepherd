import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What dragging the window's edge costs, counted: the layouts out of sight take no pass in it, and the threads out of sight do not
/// hear of it. Counts hold on a busy runner; timings don't.
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
}
