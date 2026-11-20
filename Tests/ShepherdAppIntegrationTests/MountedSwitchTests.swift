import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Switching between two mounted threads is a visibility flip: it evaluates what the flip
/// changes and then leaves both layouts alone, bar one thing: the composer's focus ring fades
/// in, in the layout that comes on screen only, over the hover motion's duration and on no
/// spring. A spring left running in either layout lays that layout out again on every frame for
/// a third of a second, whoever sees it, and the window's display cycle with it.
@Suite("Mounted switch", .mainActorExclusive)
@MainActor
struct MountedSwitchTests {
    /// How long the ring takes to come in: the hover motion's duration, the shortest there is.
    private static let fade = Duration.seconds(SH.Motion.hover.duration)

    /// How long the window runs while the ring fades: its duration, and a little room for a late frame.
    /// A spring set off with it (`SH.Motion.hover`) would run on for another 150 ms.
    private static let fading = fade + .milliseconds(80)

    /// How long the window runs once it has faded, longer than any of the springs a switch could set off.
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

    /// The probe counts of running `window` for `span`, and on until `ready` holds if it does not yet.
    private static func counts(running window: OffscreenWindow, for span: Duration,
                               until ready: @MainActor () -> Bool = { true }) async throws -> [String: Int] {
        let end = ContinuousClock.now + span
        SHRenderProbe.start()
        do {
            try await eventuallyOnMain("the window to run for \(span)", timeout: .seconds(30)) {
                ListPerf.settle(window)
                return ContinuousClock.now >= end && ready()
            }
        } catch {
            SHRenderProbe.stop()
            throw error
        }
        return SHRenderProbe.stop()
    }

    /// Whether the keyboard is in `host`.
    private static func holdsKeyboard(_ host: NSView, in window: OffscreenWindow) -> Bool {
        (window.window.firstResponder as? NSView)?.isDescendant(of: host) == true
    }

    @Test func aSwitchLeavesNothingRunningOnceTheShownRingHasFaded() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(4, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await Self.mountAll(agents, in: vm, window: window, app: app)

        for round in 0..<4 {
            let target = agents[round % 2 == 0 ? 1 : 0]
            let shown = try #require(try WorkspaceNavigationTests.deck(in: window).pages[target.tab.id]).host
            let frame = ListPerf.counting {
                vm.selectAgent(target.agent.id)
                ListPerf.settle(window)
            }
            // The composer takes the keyboard in one more body, and the ring starts to fade with it.
            let landing = try await Self.counts(running: window, for: .zero) { Self.holdsKeyboard(shown, in: window) }
            let during = try await Self.counts(running: window, for: Self.fading)
            let after = try await Self.counts(running: window, for: Self.afterwards)
            #expect(Self.holdsKeyboard(shown, in: window), "round \(round): the composer holds the keyboard")

            // The switch's own frame: the two rows, the two layouts, one pass over each host.
            #expect(frame["sidebar.row", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["layout.agentLayout", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["thread.view", default: 0] <= 2, "round \(round): \(frame)")
            #expect(frame["deck.hiddenLayout", default: 0] <= 2, "round \(round): \(frame)")
            // The layout that went off screen lets go of its ring at once: no pass over it, ever after.
            #expect(landing["deck.hiddenLayout", default: 0] + during["deck.hiddenLayout", default: 0] == 0,
                    "round \(round), as the ring fades: \(landing) \(during)")
            #expect(after["deck.hiddenLayout", default: 0] == 0, "round \(round), after the fade: \(after)")
            // The ring's fade is over by then: nothing is left to lay the shown layout out again (a spring's tail is a hundred
            // passes in 50 ms), and no body to run.
            #expect(after["deck.layout", default: 0] <= 2, "round \(round), after the fade: \(after)")
            #expect(frame["composer.body", default: 0] <= 2, "round \(round): \(frame)")
            #expect(landing["composer.body", default: 0] + during["composer.body", default: 0] <= 1, "round \(round): \(landing) \(during)")
            #expect(after["composer.body", default: 0] == 0, "round \(round), after the fade: \(after)")
        }
    }

    /// The ring where it comes on screen: a strip across the shown card's leading edge at the
    /// field's middle, three points of the thread's background and then the ring (its inner edge is the card's line).
    private static func ringStrip(in window: OffscreenWindow) async throws -> CGRect {
        let field = try #require(window.window.firstResponder as? NSView, "the shown composer holds the keyboard")
        let frame = field.convert(field.bounds, to: window.host)
        let reach: CGFloat = 60
        let search = CGRect(x: frame.minX - reach, y: frame.midY, width: reach, height: 1)
        let row = await MotionProbe.record(window, region: search, timeout: 0.05) {}.before
        let background = row.lightness(x: 0)
        let ring = try #require((0..<Int(reach)).first { abs(row.lightness(x: $0) - background) > 0.02 }, "the ring on the shown composer")
        return CGRect(x: search.minX + CGFloat(ring) - SHComposerMetrics.focusRing, y: frame.midY,
                      width: SHComposerMetrics.focusRing * 2, height: 1)
    }

    /// How far the ring has come in a frame of its strip: 0 where the background shows, 1 where it is all there.
    private static func level(_ frame: MotionRecording.Frame, on: Double) -> Double {
        (frame.lightness(x: 4) - frame.lightness(x: 0)) / on
    }

    /// The composer's ring fades in on a switch, in the layout that comes on screen, and is in by
    /// the hover motion's duration; under Reduce Motion it lands at once. Read from where the ring
    /// draws, frame by frame.
    @Test(.timingSensitive, arguments: [false, true]) func theShownRingFadesInOverTheHoverDurationUnlessReduceMotion(reduceMotion: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(2, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                     RootView(vm: vm).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        try await Self.mountAll(agents, in: vm, window: window, app: app)
        let strip = try await Self.ringStrip(in: window)

        for round in 0..<2 {
            let target = agents[round % 2 == 0 ? 1 : 0]
            let recording = await MotionProbe.record(window, region: strip) {
                vm.selectAgent(target.agent.id)
                ListPerf.settle(window)
            }
            let on = Self.level(recording.settled, on: 1)
            try #require(abs(on) > 0.03, "round \(round): the ring shows against the background")
            // The first frame is the layout that was on screen, ring and all; the ring then comes from the last frame without it.
            let levels = recording.frames.dropFirst().map { (time: $0.time, level: Self.level($0, on: on)) }
            let off = levels.lastIndex { $0.level < 0.02 }
            let coming = off.map { Array(levels[($0 + 1)...]) } ?? levels
            let partial = coming.filter { $0.level < 0.98 }
            let summary = levels.map { "\(Int($0.time * 1000))ms:\(Int($0.level * 100))" }.joined(separator: " ")

            #expect(coming.last.map { $0.level >= 0.98 } == true, "round \(round): the ring came: \(summary)")
            if reduceMotion {
                #expect(partial.isEmpty, "round \(round): it lands at once: \(summary)")
            } else {
                #expect(!partial.isEmpty, "round \(round): it fades in over frames: \(summary)")
                #expect(zip(coming, coming.dropFirst()).allSatisfy { $1.level >= $0.level - 0.03 }, "round \(round): it only comes in: \(summary)")
                let started = off.map { levels[$0].time } ?? coming.first?.time ?? 0
                let done = coming.first { $0.level >= 0.98 }?.time ?? .infinity
                #expect(done - started <= SH.Motion.hover.duration + 0.06,
                        "round \(round): it is in by the hover duration: \(Int((done - started) * 1000)) ms, \(summary)")
            }
        }
    }
}
