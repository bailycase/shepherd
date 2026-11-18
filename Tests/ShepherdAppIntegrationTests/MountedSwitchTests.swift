import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Switching between two mounted threads is a visibility flip: it evaluates what the flip
/// changes and then leaves both layouts alone. A spring left running in either one (the
/// composer's ring fading with focus) lays that layout out again on every frame for a third of a
/// second, whoever sees it, and the window's display cycle with it.
@Suite("Mounted switch", .mainActorExclusive)
@MainActor
struct MountedSwitchTests {
    /// How long the window runs after a switch's frame, longer than any of the springs a switch could set off.
    private static let afterwards = Duration.milliseconds(700)

    /// Every thread mounted and shown once, and the window held still.
    private static func mountAll(_ agents: [AgentFixture], in vm: ShepherdViewModel, window: OffscreenWindow, app: AppHarness) async throws {
        for agent in agents { _ = try await app.readyThread(agent.agent.id) }
        var quiet = 0
        try await eventuallyOnMain("the mounted workspace to settle", timeout: .seconds(60)) {
            ListPerf.settle(window)
            guard vm.mountedTabs.count == agents.count, vm.threadStores.store(for: agents[0].agent.id).ready else { return false }
            let counts = ListPerf.counting { ListPerf.settle(window) }
            quiet = ["shell.root", "shell.workspace", "thread.view", "deck.hiddenLayout"].allSatisfy { counts[$0, default: 0] == 0 } ? quiet + 1 : 0
            return quiet >= 10
        }
        for agent in agents.dropFirst() + [agents[0]] {
            try await MountedWorkspace.show(agent, in: vm, window: window)
            try await holdStill(window)
        }
    }

    /// Runs the window until a spring has no more to do and a stretch of passes finds nothing to lay out.
    private static func holdStill(_ window: OffscreenWindow) async throws {
        var quiet = 0
        try await eventuallyOnMain("the window to hold still", timeout: .seconds(30)) {
            ListPerf.settle(window)
            let counts = ListPerf.counting { ListPerf.settle(window) }
            quiet = counts["deck.layout", default: 0] + counts["deck.hiddenLayout", default: 0] == 0 ? quiet + 1 : 0
            return quiet >= 30
        }
    }

    /// The probe counts of running `window` for `span`.
    private static func counts(running window: OffscreenWindow, for span: Duration) async throws -> [String: Int] {
        let end = ContinuousClock.now + span
        SHRenderProbe.start()
        do {
            try await eventuallyOnMain("the window to run for \(span)", timeout: .seconds(30)) {
                ListPerf.settle(window)
                return ContinuousClock.now >= end
            }
        } catch {
            SHRenderProbe.stop()
            throw error
        }
        return SHRenderProbe.stop()
    }

    @Test func aSwitchLeavesNeitherLayoutRunningASpringAfterItsFrame() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(4, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await Self.mountAll(agents, in: vm, window: window, app: app)

        for round in 0..<4 {
            let target = agents[round % 2 == 0 ? 1 : 0]
            let frame = ListPerf.counting {
                vm.selectAgent(target.agent.id)
                ListPerf.settle(window)
            }
            let after = try await Self.counts(running: window, for: Self.afterwards)
            // The claim still lands, only without the fade: the shown thread's composer holds the keyboard.
            let shown = try #require(try WorkspaceNavigationTests.deck(in: window).pages[target.tab.id]).host
            #expect((window.window.firstResponder as? NSView)?.isDescendant(of: shown) == true, "round \(round): the composer holds the keyboard")

            // The switch's own frame: the two rows, the two layouts, one pass over each host.
            #expect(frame["sidebar.row", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["layout.agentLayout", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["thread.view", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["deck.hiddenLayout", default: 0] <= 2, "round \(round): \(frame)")
            // And then nothing: the composer takes the keyboard in one more body, and no host is laid out again.
            #expect(after["deck.hiddenLayout", default: 0] == 0, "round \(round), after the frame: \(after)")
            #expect(after["deck.layout", default: 0] <= 2, "round \(round), after the frame: \(after)")
            #expect(after["composer.body", default: 0] <= 1, "round \(round), after the frame: \(after)")
        }
    }
}
