import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What dragging the side pane's divider, dragging the terminal panel's divider and scrolling the subagent inspector cost, as
/// counts a busy machine cannot move: bodies evaluated (`SHRenderProbe`) and what each frame did to Core Animation's layers
/// (`LayerWatch`). The drags are real mouse events sent to an off-screen window (`PointerDrag`), through the divider's own
/// gesture, in the full shell with the thread, its composer, and other layouts mounted behind.
@Suite("Pane resize and scroll budgets", .mainActorExclusive)
@MainActor
struct PaneResizePerformanceTests {
    @Test func draggingTheSidePaneDividerRedrawsOnlyTheTwoSides() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.paneDrag() }
        }
        Self.echo(result)
        expectScenarioCompleted(result)
    }

    @Test func draggingTheTerminalDividerRedrawsOnlyTheThreadAndTheTerminal() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.terminalDrag() }
        }
        Self.echo(result)
        expectScenarioCompleted(result)
    }

    @Test(arguments: ["running", "complete"])
    func scrollingTheInspectorBuildsNoRowItDoesNotShow(state: String) async throws {
        try await Self.inspectorScroll(state: state)
    }

    private static func echo(_ result: ExitTest.Result?) {
        for line in String(decoding: result?.standardOutputContent ?? [], as: UTF8.self).split(separator: "\n") where line.hasPrefix("PERF |") {
            print(line)
        }
    }

    // MARK: The shell

    /// The real root view over three agents on stub pis that each hold a thread of 24 turns, the first on screen with its composer.
    @MainActor private struct Shell {
        let app: AppHarness
        let vm: ShepherdViewModel
        let window: OffscreenWindow
        let agents: [AgentFixture]

        static func open(in app: AppHarness, size: CGSize = CGSize(width: 1500, height: 900)) async throws -> Shell {
            let history = app.dir.appendingPathComponent("history.json")
            let turns: [[String: Any]] = (0..<24).flatMap { n -> [[String: Any]] in
                let at = 1_800_000_000_000 + Double(n) * 60_000
                return [["role": "user", "content": [["type": "text", "text": "Question \(n): what changed in the checkout flow?"]], "timestamp": at],
                        ["role": "assistant", "stopReason": "stop", "timestamp": at + 5_000,
                         "content": [["type": "text", "text": ListFixtures.answer + "\n\n" + ListFixtures.answer]]]]
            }
            try JSONSerialization.data(withJSONObject: turns).write(to: history)
            let (vm, agents) = try await MountedWorkspace.start(3, in: app, env: { _ in ["STUB_PI_MESSAGES_FILE": history.path] })
            let window = OffscreenWindow(size: size, dark: true, RootView(vm: vm))
            let visible = vm.threadStores.store(for: agents[0].agent.id)
            try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready && !visible.messages.isEmpty }
            try await eventuallyOnMain("every layout to mount") { ListPerf.settle(window); return vm.mountedTabs.count == agents.count }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                ListPerf.settle(window)
            }
            return Shell(app: app, vm: vm, window: window, agents: agents)
        }

        /// The accessibility element that says `label`, in the window's own coordinates (origin bottom left).
        func element(_ label: String) -> CGRect? {
            window.element(label).map { $0.frame.offsetBy(dx: -window.window.frame.minX, dy: -window.window.frame.minY) }
        }
    }

    /// Runs `frames` moves of a drag, each waited out until `arrived` says the window drew it, and counts the bodies and layers.
    @MainActor private struct Drag {
        var bodies: [String: Int] = [:]
        var layers = LayerWatch.Frame()
        var worst = LayerWatch.Frame()
        var summary = ""
        var frames = 0

        /// The divider is followed by what the window draws: `position` is where it is drawn now and `axis` the pointer's coordinate
        /// along the drag. The first move shows how far the drawn divider sits from the pointer (a handle's own offset); every
        /// later frame is waited out until it has taken the pointer's place plus that.
        static func run(_ shell: Shell, from start: CGPoint, to points: [CGPoint], axis: (CGPoint) -> CGFloat,
                        position: () -> CGFloat?) async throws -> Drag {
            let window = shell.window
            let pointer = PointerDrag(window: window.window)
            try pointer.press(at: start)
            let watch = LayerWatch(window)
            let before = position()
            var offset: CGFloat?
            SHRenderProbe.start()
            for point in points {
                try pointer.move(to: point)
                try await eventuallyOnMain("the window to draw the pointer at \(point)") {
                    window.layout()
                    guard let drawn = position() else { return false }
                    if offset == nil {
                        guard before.map({ abs(drawn - $0) > 0.5 }) != false else { return false }
                        offset = drawn - axis(point)
                    }
                    return abs(drawn - axis(point) - (offset ?? 0)) <= 1.5
                }
                ListPerf.settle(window)
                watch.frame(window)
            }
            let bodies = SHRenderProbe.stop()
            try pointer.release(at: points.last ?? start)
            ListPerf.settle(window)
            return Drag(bodies: bodies, layers: watch.total, worst: watch.worst, summary: watch.summary, frames: points.count)
        }

        func perFrame(_ key: String) -> Double { Double(bodies[key, default: 0]) / Double(max(frames, 1)) }

        func report(_ name: String) {
            let keys = ["shell.root", "shell.workspace", "layout.agentLayout", "layout.paneTreeGeo", "thread.view", "thread.header",
                        "thread.rowBuilder", "thread.agentTurn", "thread.userTurn", "composer.body", "toolbar.thread", "deck.update", "deck.layout",
                        "deck.hiddenLayout", "layout.composerFieldMeasured", "layout.composerControlsMeasured"]
            let counts = keys.map { "\($0) \(bodies[$0, default: 0])" }.joined(separator: ", ")
            print("PERF | \(name) | bodies over \(frames) frames | \(counts)")
            print("PERF | \(name) | layers | \(summary)")
        }
    }

    // MARK: Side pane divider

    /// A real press, thirty moves and a release at the side pane's divider: the pane's width follows the pointer, and each frame
    /// redraws the layout that owns the divider, never the shell, the toolbar or another layout, and casts no shadow offscreen.
    @MainActor private static func paneDrag() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let shell = try await Shell.open(in: app)
        defer { shell.window.close() }
        AccessibilityNode.enable()
        // Each drag starts from the defaults, not from the width an earlier run saved.
        shell.vm.subagentInspector.width = 0
        shell.vm.openReview(agentID: shell.agents[0].agent.id, path: nil)
        try await eventuallyOnMain("the pane's divider") { ListPerf.settle(shell.window); return shell.element("Pane width") != nil }
        try await Task.sleep(for: .milliseconds(300))
        ListPerf.settle(shell.window)
        let handle = try #require(shell.element("Pane width"))
        let start = CGPoint(x: handle.midX, y: handle.midY)
        // Right 6pt at a time (the pane narrows, away from the widest the column allows), then left again.
        let out = (1...15).map { CGPoint(x: start.x + CGFloat($0) * 6, y: start.y) }
        let points = out + out.reversed().dropFirst() + [start]
        let drag = try await Drag.run(shell, from: start, to: points, axis: { $0.x }, position: { shell.element("Pane width")?.midX })
        drag.report("side pane divider drag")
        // The drag's own layout is the one that owns the divider; the thread under it takes each new width once.
        let frames = Double(drag.frames)
        #expect(drag.perFrame("shell.root") == 0, "the shell reran: \(drag.bodies)")
        #expect(drag.perFrame("shell.workspace") == 0, "the workspace reran: \(drag.bodies)")
        #expect(drag.perFrame("layout.agentLayout") == 0, "the layout's model did not change: \(drag.bodies)")
        #expect(Double(drag.bodies["layout.paneTreeGeo", default: 0]) <= frames, "the thread's tree is measured once a frame: \(drag.bodies)")
        // The composer takes each new width: its body at most a couple of times a frame.
        #expect(drag.perFrame("composer.body") <= 3, "the composer reran too often: \(drag.bodies)")
        #expect(drag.perFrame("thread.header") == 0, "the thread header reran: \(drag.bodies)")
        #expect(drag.perFrame("toolbar.thread") == 0, "the toolbar reran: \(drag.bodies)")
        #expect(drag.bodies["deck.update", default: 0] == 0 && drag.bodies["deck.hiddenLayout", default: 0] == 0, "other layouts reran: \(drag.bodies)")
        #expect(drag.layers.shadowRenders == 0, "a shadow with no path was drawn offscreen again: \(drag.layers) \(drag.summary)")
        #expect(drag.layers.pathShadows > 0, "the cards no longer cast their lift: \(drag.summary)")
    }

    // MARK: Terminal divider

    /// A real press, thirty moves and a release at the terminal panel's divider.
    @MainActor private static func terminalDrag() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let shell = try await Shell.open(in: app)
        defer { shell.window.close() }
        AccessibilityNode.enable()
        shell.vm.terminalPanels.height = AppLayout.terminalPanelHeight
        shell.vm.toggleTerminalPanel()
        try await eventuallyOnMain("the terminal and its divider") {
            ListPerf.settle(shell.window)
            return shell.vm.isTerminalPanelShowing && shell.vm.terminalTarget?.tabs.count == 1 && shell.element("Terminal height") != nil
        }
        try await Task.sleep(for: .milliseconds(500))
        ListPerf.settle(shell.window)
        let handle = try #require(shell.element("Terminal height"))
        // The strip's top edge, inside the handle's lower half: the terminal's own surface sits over its upper half.
        let start = CGPoint(x: handle.midX, y: handle.midY - 3)
        // Up 5pt at a time (the panel grows), then down again; the range clear of the divider's snaps.
        let up = (1...12).map { CGPoint(x: start.x, y: start.y + CGFloat($0) * 5) }
        let points = up + up.reversed().dropFirst() + [start]
        let drag = try await Drag.run(shell, from: start, to: points, axis: { $0.y }, position: { shell.element("Terminal height")?.midY })
        drag.report("terminal divider drag")
        let frames = Double(drag.frames)
        #expect(drag.perFrame("shell.root") == 0, "the shell reran: \(drag.bodies)")
        #expect(drag.perFrame("shell.workspace") == 0, "the workspace reran: \(drag.bodies)")
        #expect(drag.perFrame("layout.agentLayout") == 0, "the layout's model did not change: \(drag.bodies)")
        #expect(Double(drag.bodies["layout.paneTreeGeo", default: 0]) <= frames, "the tree is measured once a frame: \(drag.bodies)")
        #expect(drag.perFrame("composer.body") == 0, "the composer reran: \(drag.bodies)")
        #expect(drag.perFrame("thread.header") == 0, "the thread header reran: \(drag.bodies)")
        #expect(drag.bodies["deck.update", default: 0] == 0 && drag.bodies["deck.hiddenLayout", default: 0] == 0, "other layouts reran: \(drag.bodies)")
        #expect(drag.layers.shadowRenders == 0, "a shadow with no path was drawn offscreen again: \(drag.summary)")
        #expect(drag.layers.pathShadows > 0, "the panel no longer casts its lift: \(drag.summary)")
    }

    // MARK: Inspector

    /// Sixty scroll steps through a 500-turn run's transcript in the inspector's own card: rows are built as they come on
    /// screen, not again for each step, and neither the card's shadow nor its fill is drawn again.
    @MainActor private static func inspectorScroll(state: String) async throws {
        let store = NativeThreadStore()
        let run = ListFixtures.run(0, state: state)
        let messages = ListFixtures.conversation(turns: 500, prefix: "c")
        var pages = 0
        let task = Task { [store] in
            await store.run { request in
                if case .subagentTranscript(_, let runID, _) = request {
                    pages += 1
                    return .transcript(value: NativeSubagentTranscript(runID: runID, messages: messages))
                }
                return .snapshot(value: NativeThreadSnapshot(
                    piSessionID: "s", generation: "g", revision: 1, running: true, supportedActions: ["send", "subagents"],
                    dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false, subagents: [run]))
            }
        }
        defer {
            task.cancel()
            store.stop()
        }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        let size = CGSize(width: 1200, height: 800)
        func card() -> some View {
            RightPaneSplit(state: RightPaneState(defaults: ScratchDefaults()), showPane: true, card: true, inspector: true) {
                Color.clear
            } pane: {
                SubagentInspector(store: store, runID: run.runID, active: true, close: {})
            }
            .environment(\.workspaceTopInset, 52)
        }
        let window = OffscreenWindow(size: size, dark: true, card())
        defer { window.close() }
        try await eventuallyOnMain("the transcript to load") {
            ListPerf.settle(window)
            return pages >= 1 && (ListPerf.scrollView(in: window)?.documentView?.bounds.height ?? 0) > 2000
        }
        let scroll = try #require(ListPerf.scrollView(in: window))
        ListPerf.jump(window, scroll, toEnd: true)
        for _ in 0..<5 { ListPerf.settle(window) }
        let watch = LayerWatch(window)
        var steps = 0
        let bodies = ListPerf.counting {
            let clip = scroll.contentView
            for _ in 0..<60 {
                let before = clip.bounds.origin.y
                let target = NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: before - 120), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(target).origin)
                scroll.reflectScrolledClipView(clip)
                ListPerf.settle(window)
                watch.frame(window)
                steps += 1
            }
        }
        let keys = ["inspector.body", "thread.agentTurn", "thread.userTurn", "thread.liveRow"]
        print("PERF | inspector scroll (\(state) run) | bodies over \(steps) steps | " + keys.map { "\($0) \(bodies[$0, default: 0])" }.joined(separator: ", "))
        print("PERF | inspector scroll (\(state) run) | layers | \(watch.summary)")
        // 120pt a step moves a few turns into view: each is built about once, and the inspector around them never reruns.
        #expect(bodies["inspector.body", default: 0] == 0, "the whole inspector reran on scroll: \(bodies)")
        let rows = bodies["thread.agentTurn", default: 0] + bodies["thread.userTurn", default: 0]
        #expect(rows <= 3 * steps, "rows were evaluated again as the card scrolled: \(bodies)")
        #expect(watch.total.shadowRenders == 0, "the card's shadow was drawn offscreen again: \(watch.summary)")
        #expect(watch.total.maskedGroups == 0, "the scrolling transcript sits under a rounded clip, drawn offscreen each step: \(watch.summary)")
    }
}

/// A left-button drag sent to an off-screen window through `NSWindow.sendEvent`, as AppKit routes a click: never posted, so the
/// user's pointer and focus are never involved. Points are window coordinates (origin bottom left).
@MainActor
struct PointerDrag {
    let window: NSWindow
    private let clock = Clock()
    private final class Clock { var time = ProcessInfo.processInfo.systemUptime }

    init(window: NSWindow) { self.window = window }

    func press(at point: CGPoint) throws { try send(.leftMouseDown, point) }
    func move(to point: CGPoint) throws { try send(.leftMouseDragged, point) }
    func release(at point: CGPoint) throws { try send(.leftMouseUp, point) }

    private func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
        clock.time += 0.016
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: clock.time,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: 1) else { throw NoEvent() }
        window.sendEvent(event)
    }

    private struct NoEvent: Error {}
}
