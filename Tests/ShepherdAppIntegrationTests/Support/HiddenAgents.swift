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

/// The real `WorkspaceView` with one agent on screen and `hidden` more mounted behind it, each
/// on a stub pi: the hidden threads show 50 turns each (history previewed as at launch), and the
/// visible agent has its Changes pane open on a 3,000-line file to scroll. It measures what an
/// update in the visible layout costs beside the hidden ones (`ListPerformanceTests`,
/// `HiddenAgentsReport`).
@MainActor
struct HiddenAgentsWorkspace {
    let vm: ShepherdViewModel
    let agents: [AgentFixture]
    let window: OffscreenWindow
    /// The Changes pane's diff.
    let diff: NSScrollView

    var visible: NativeThreadStore { vm.threadStores.store(for: agents[0].agent.id) }

    static func open(hidden: Int, in app: AppHarness) async throws -> HiddenAgentsWorkspace {
        let (vm, agents) = try await MountedWorkspace.start(hidden + 1, in: app)
        vm.changesEngineOverride = { _, _ in .fixed([ListFixtures.diffFile("Notes.txt", lines: 3000)]) }
        for agent in agents.dropFirst() {
            vm.threadStores.store(for: agent.agent.id).preview(ListFixtures.threadSnapshot(turns: 50))
        }
        let window = OffscreenWindow(size: CGSize(width: 1300, height: 800), dark: true, WorkspaceView(vm: vm))
        // As in a titled window, the content hangs in a view tree with an Auto Layout engine: a
        // borderless window's has none, and AppKit then scans every view on each layout.
        let container = NSView(frame: window.host.frame)
        window.window.contentView = container
        window.host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(window.host)
        NSLayoutConstraint.activate([
            window.host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            window.host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            window.host.topAnchor.constraint(equalTo: container.topAnchor),
            window.host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        vm.openReview(agentID: agents[0].agent.id, path: nil)
        try await eventuallyOnMain("the diff to load", timeout: .seconds(60)) {
            ListPerf.settle(window)
            return (shownScrollViews(in: window).max { height($0) < height($1) }).map(height) ?? 0 > 10_000
        }
        // Let what opening set off land (the model catalog, the hidden threads' previews).
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            ListPerf.settle(window)
        }
        let diff = try #require(shownScrollViews(in: window).max { height($0) < height($1) })
        ListPerf.jump(window, diff, toEnd: false)
        return HiddenAgentsWorkspace(vm: vm, agents: agents, window: window, diff: diff)
    }

    private static func height(_ scroll: NSScrollView) -> CGFloat { scroll.documentView?.frame.height ?? 0 }

    /// The scroll views on screen: none inside a hidden layout.
    static func shownScrollViews(in window: OffscreenWindow) -> [NSScrollView] {
        func all(_ view: NSView) -> [NSScrollView] {
            guard !view.isHidden else { return [] }
            return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return all(window.window.contentView!)
    }

    /// What of the window AppKit walks on each update: views and layers not hidden, and the
    /// tracking areas of those views.
    struct Census: Equatable, CustomStringConvertible {
        var views = 0
        var trackingAreas = 0
        var layers = 0

        var description: String { "\(views) views, \(trackingAreas) tracking areas, \(layers) layers" }
    }

    func census() -> Census {
        var census = Census()
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            census.views += 1
            census.trackingAreas += view.trackingAreas.count
            view.subviews.forEach(walk)
        }
        func walk(_ layer: CALayer) {
            guard !layer.isHidden else { return }
            census.layers += 1
            layer.sublayers?.forEach(walk)
        }
        walk(window.window.contentView!)
        window.window.contentView?.layer.map(walk)
        return census
    }

    /// Scrolls the diff `steps` steps of `step` points, from the top.
    func scroll(step: CGFloat, steps: Int) -> ListPerf.Scroll {
        ListPerf.jump(window, diff, toEnd: false)
        return ListPerf.scroll(window, diff, step: step, steps: steps)
    }

    /// Types `count` characters into the visible thread's draft, one update each, and clears it.
    func type(_ count: Int, each: (() -> Void) -> Void = { $0() }) {
        for step in 0..<count {
            each {
                visible.draft += step.isMultiple(of: 12) ? " " : "x"
                ListPerf.settle(window)
            }
        }
        visible.draft = ""
        ListPerf.settle(window)
    }

    /// `count` status reports, one update each: a hidden agent's when there is one, else the
    /// visible agent's.
    func reportStatus(_ count: Int, each: (() -> Void) -> Void = { $0() }) {
        for round in 0..<count {
            let agent = agents.count > 1 ? agents[1 + round % (agents.count - 1)] : agents[0]
            var next = vm.state
            if let index = next.agents.firstIndex(where: { $0.id == agent.agent.id }) {
                next.agents[index].status = next.agents[index].status == .working ? .done : .working
            }
            each {
                vm.adopt(next)
                ListPerf.settle(window)
            }
        }
    }

    /// A reply of 40 deltas streamed into the visible thread, until it has landed. The window
    /// updates as the app's does, once per pull that brought something.
    func stream() async throws {
        let before = visible.messages.count
        await visible.send(text: "stream")
        try await eventuallyOnMain("the streamed reply to land", timeout: .seconds(30)) {
            visible.messages.count == before + 2 && !visible.running
        }
        ListPerf.settle(window)
    }

    func close() { window.close() }
}
