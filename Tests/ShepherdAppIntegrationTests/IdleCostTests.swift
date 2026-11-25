import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import QuartzCore
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// What the app costs while nothing changes: motion no one sees costs
/// nothing, and motion on screen costs the app no frames. The shimmer and the glow move on the
/// render server (a Core Animation animation on their layer); a shimmer in a layout the
/// workspace keeps mounted but hidden, or in a row a lazy stack has let go of, rests. Counted in
/// frames the clock-driven motions draw (`SHRenderProbe`), host layout passes, and the layers
/// carrying an animation, none of which a slow machine changes.
@Suite("Idle cost", .mainActorExclusive)
@MainActor
struct IdleCostTests {
    static let clockKeys = ["ui.glowFrame", "ui.pulseFrame"]

    /// Clock frames drawn over `seconds` of run loop.
    static func clockFrames(over seconds: Double = 1) async -> Int {
        SHRenderProbe.start()
        try? await Task.sleep(for: .seconds(seconds))
        let counts = SHRenderProbe.stop()
        return clockKeys.reduce(0) { $0 + counts[$1, default: 0] }
    }

    static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// Live text's shimmer bands in `root`, and how many of them move.
    static func shimmers(in root: NSView) -> (all: Int, moving: Int) {
        let all = views(SHShimmerLayerView.self, in: root)
        return (all.count, all.filter { $0.band.animation(forKey: SHLayerMotion.shimmerKey) != nil }.count)
    }

    static func glows(in root: NSView) -> (all: Int, pulsing: Int) {
        let all = views(SHGlowLayerView.self, in: root)
        return (all.count, all.filter { $0.dot.animation(forKey: SHLayerMotion.glowKey) != nil }.count)
    }

    /// A thread that has loaded draws no shimmer: "Starting…" is gone for good, not moving
    /// where no one sees it.
    @Test func aLoadedThreadDrawsNoShimmerFrames() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)))
        defer { thread.close() }
        try await thread.waitUntilReady()

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        #expect(Self.shimmers(in: thread.window.host).moving == 0)
    }

    /// The control: a thread whose pi keeps it waiting says so in its composer, and those words
    /// shimmer, once.
    @Test func aVisibleStartingThreadStillShimmers() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]), starting: true, reduceMotion: false)
        defer { thread.close() }
        let store = thread.store
        let host = thread.window.host
        try await eventuallyOnMain("pi to be reported starting") { store.starting }
        try await eventuallyOnMain("the composer to say pi is starting") {
            ListPerf.settle(thread.window)
            return Self.shimmers(in: host).all == 1
        }

        #expect(Self.shimmers(in: host).moving == 1)
    }

    /// Layouts the workspace keeps mounted behind the visible one draw no clock frames, and
    /// nothing in them moves or turns. Each hidden thread has a turn running (stub pi `slow`, held at its
    /// second pause, mid-tool), so it keeps a live line whose shimmer must rest while its layout
    /// is hidden.
    @Test func hiddenLayoutsDrawNoClockFrames() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<4 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }
        // Every stub pi runs in this directory: past its first pause (mid-reply, where nothing but
        // the text moves) at once, and every held turn released at the end.
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("continue-1").path, contents: nil)
        defer {
            for name in ["continue-1", "continue-2"] {
                FileManager.default.createFile(atPath: app.dir.appendingPathComponent(name).path, contents: nil)
            }
        }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        // Reduce Motion pinned off: the hidden shimmers must be ones that would otherwise move.
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true,
                                     WorkspaceView(vm: vm).environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(30)) { visible.ready }
        for agent in agents.dropFirst() {
            vm.selectAgent(agent.agent.id)
            let store = vm.threadStores.store(for: agent.agent.id)
            try await eventuallyOnMain("\(agent.agent.name)'s thread to load", timeout: .seconds(30)) { store.ready }
            await store.send(text: "slow")
            try await eventuallyOnMain("\(agent.agent.name)'s turn to hold mid-tool", timeout: .seconds(30)) {
                ListPerf.settle(window)
                return store.running && Self.shimmers(in: window.host).moving >= 1
            }
        }
        vm.selectAgent(agents[0].agent.id)
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        ListPerf.settle(window)

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        let shimmers = Self.shimmers(in: window.host)
        #expect(shimmers.moving == 0, "\(shimmers)")
        // Each hidden turn's live line wears one shimmer (ToolFeed › A); in a hidden layout it rests.
        #expect(shimmers.all == agents.count - 1, "one shimmer per hidden live line: \(shimmers)")
    }

    /// A paused shimmer moves again as its layout comes back on screen. Between tools the
    /// thread's live line is "Thinking…".
    @Test func aLayoutShownAgainResumesItsShimmer() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2) + [ThreadFixture.user("u", "Go")], running: true),
                                reduceMotion: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.visibility.motionPaused = true
        ListPerf.settle(thread.window)
        let paused = Self.shimmers(in: thread.window.host)
        #expect(paused.all > 0 && paused.moving == 0, "rests while hidden: \(paused)")

        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)

        let shown = Self.shimmers(in: thread.window.host)
        #expect(shown.moving == shown.all, "\(shown)")
    }

    /// ToolFeed › A: a running thread's one live line shimmers, and a steering message in "Up next"
    /// waits still (waiting isn't working), so that shimmer is the thread's only one. It rests
    /// while the layout is hidden and moves again on screen.
    @Test func aRunningThreadWithASteerShimmersOnce() async throws {
        var snapshot = ThreadFixture.snapshot(ThreadFixture.history(2) + [ThreadFixture.user("u", "Go")],
                                              provisional: [ThreadFixture.streaming("Working on it.")], running: true)
        snapshot.provisional = [NativeThreadMessage(entryID: "provisional:tool:b", role: "toolResult", blocks: [], toolName: "bash",
                                                    toolCallID: "b", argumentsText: #"{"command":"swift test"}"#, status: "running")]
        snapshot.queue = NativeQueue(items: QueueFixture.messages(["Use the staging database", "Then run the tests"], steering: 1), mode: .all)
        snapshot.supportedActions.append("queue")
        let thread = FakeThread(snapshot, reduceMotion: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        ListPerf.settle(thread.window)
        let shown = Self.shimmers(in: thread.window.host)
        #expect(shown.all == 1 && shown.moving == 1, "only the live line's shimmer moves: \(shown)")

        thread.visibility.motionPaused = true
        ListPerf.settle(thread.window)
        let hidden = Self.shimmers(in: thread.window.host)
        #expect(hidden.all == shown.all && hidden.moving == 0, "\(hidden)")

        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        let back = Self.shimmers(in: thread.window.host)
        #expect(back.all == 1 && back.moving == 1, "\(back)")
    }

    /// A shimmer on screen costs the app no frames: its band slides on the render server, in
    /// step with the clock.
    @Test func aShimmerSlidesOnTheRenderServer() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 240, height: 60),
                                          Text("Running tests").shShimmer(active: true).padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        try await eventuallyOnMain("the band to slide") { Self.shimmers(in: window.host) == (1, 1) }
        // The window's first passes (fonts, the band's host) settle before the idle stretch.
        _ = await Self.clockFrames(over: 0.3)
        let before = window.host.layouts

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        // A busy shared runner can hand the host a late layout pass that is not the band's doing
        // (the rule it proves, no frames, holds either way): a speed sample, like a motion control.
        if TimingTests.enabled {
            #expect(window.host.layouts == before, "\(window.host.layouts - before) host layout passes")
        }
        let band = try #require(Self.views(SHShimmerLayerView.self, in: window.host).first)
        let group = try #require(band.band.animation(forKey: SHLayerMotion.shimmerKey) as? CAAnimationGroup)
        #expect(group.duration == SH.Motion.shimmer.duration && group.repeatCount == .infinity)
    }

    /// Under Reduce Motion live text is plain secondary text: no band at all.
    @Test func reduceMotionDrawsLiveTextStill() {
        let window = LayoutCountingWindow(size: CGSize(width: 240, height: 60),
                                          Text("Running tests").shShimmer(active: true).padding(10)
                                              .environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        #expect(Self.shimmers(in: window.host).all == 0)
    }

    // MARK: Render-server motion

    /// A shimmer moving and an attention dot glowing, on screen: SwiftUI draws no frame for them
    /// and never lays the window out again.
    @Test func aShimmerAndAGlowingDotCostTheAppNoFrames() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { Text("Running").shShimmer(active: true); SHStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.shimmers(in: window.host).moving == 1 && Self.glows(in: window.host).pulsing == 1)
        let layouts = window.host.layouts

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        #expect(window.host.layouts - layouts == 0, "\(window.host.layouts - layouts) host layout passes")
    }

    @Test func theShimmerAndTheGlowRepeatAtTheirAnchors() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { Text("Running").shShimmer(active: true); SHStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        let band = try #require(Self.views(SHShimmerLayerView.self, in: window.host).first)
        let dot = try #require(Self.views(SHGlowLayerView.self, in: window.host).first)

        let slide = try #require(band.band.animation(forKey: SHLayerMotion.shimmerKey) as? CAAnimationGroup)
        #expect(slide.duration == SH.Motion.shimmer.duration && slide.repeatCount == .infinity)
        #expect(slide.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath }.sorted() == ["endPoint", "startPoint"], "the band slides, nothing turns")
        let glow = try #require(dot.dot.animation(forKey: SHLayerMotion.glowKey) as? CAKeyframeAnimation)
        #expect(glow.keyPath == "opacity" && glow.duration == SH.Motion.glow.duration && glow.repeatCount == .infinity)
    }

    /// Reduce Motion draws no band at all; a hidden layout leaves the band and the dot at rest.
    @Test(arguments: ["reduce motion", "paused"]) func nothingTurnsOrGlowsAtRest(reason: String) async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { Text("Running").shShimmer(active: true); SHStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, reason == "reduce motion")
                                              .environment(\.shMotionPaused, reason == "paused"))
        defer { window.close() }

        let shimmers = Self.shimmers(in: window.host), glows = Self.glows(in: window.host)

        #expect(shimmers.all == (reason == "paused" ? 1 : 0) && shimmers.moving == 0)
        #expect(glows.all == 1 && glows.pulsing == 0)
        #expect(Self.views(SHGlowLayerView.self, in: window.host).first?.dot.opacity == 1, "a resting dot is fully lit")
    }

    @MainActor @Observable final class Scheme {
        var value: ColorScheme = .light
    }

    private struct SchemedShimmer: View {
        let scheme: Scheme

        var body: some View {
            HStack { Text("Running").shShimmer(active: true); SHStatusDot(.attention) }
                .padding(10)
                .environment(\._accessibilityReduceMotion, false)
                .environment(\.colorScheme, scheme.value)
        }
    }

    /// The layers take their colors from the theme's tokens as the view's appearance resolves
    /// them, again whenever it changes: switching to dark recolors a shimmer and a dot in place.
    @Test func anAppearanceSwitchRecolorsTheShimmerAndTheDot() throws {
        let scheme = Scheme()
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60), SchemedShimmer(scheme: scheme))
        defer { window.close() }
        let band = try #require(Self.views(SHShimmerLayerView.self, in: window.host).first)
        let dot = try #require(Self.views(SHGlowLayerView.self, in: window.host).first)
        func expected(_ color: Color, _ scheme: ColorScheme) -> CGColor {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            return color.resolve(in: environment).cgColor
        }
        #expect((band.band.colors as? [CGColor]) == [expected(Color.sh.textTertiary, .light), expected(Color.sh.textPrimary, .light),
                                                     expected(Color.sh.textTertiary, .light)])
        #expect(dot.dot.fillColor == expected(AgentState.attention.color, .light))

        scheme.value = .dark
        window.window.layoutIfNeeded()
        window.host.layoutSubtreeIfNeeded()

        #expect((band.band.colors as? [CGColor]) == [expected(Color.sh.textTertiary, .dark), expected(Color.sh.textPrimary, .dark),
                                                     expected(Color.sh.textTertiary, .dark)])
        #expect(dot.dot.fillColor == expected(AgentState.attention.color, .dark))
        #expect(expected(Color.sh.textPrimary, .light) != expected(Color.sh.textPrimary, .dark), "the token has two colors")
    }

    /// Every shimmer moves in step with the clock (`SHPhase`), as the timeline-drawn one did.
    @Test(.timingSensitive) func aShimmerMovesInStepWithTheClock() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 160, height: 60),
                                          Text("Running tests").shShimmer(active: true).padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        let band = try #require(Self.views(SHShimmerLayerView.self, in: window.host).first)
        try await Task.sleep(for: .milliseconds(100))

        let start = try #require(band.band.presentation()?.startPoint)
        let expected = SHPhase.shimmerPoints(center: SHPhase.shimmerCenter(Date())).start

        #expect(abs(start.x - expected.x) < 0.5, "at \(start.x), the clock's phase is \(expected.x)")
    }

    // MARK: The look

    private static func bitmap(_ view: some View, size: CGSize, dark: Bool) -> NSBitmapImageRep {
        let window = OffscreenWindow(size: size, dark: dark, view.frame(width: size.width, height: size.height)
            .background(Color.sh.bgWindow).environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        ListPerf.settle(window)
        let bitmap = window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds)!
        window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
        return bitmap
    }

    /// How far a pixel is from the background (0) toward the ink (1), in its strongest channel.
    private static func coverage(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int, background: NSColor, ink: NSColor) -> Double {
        let p = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let channels: [(CGFloat, CGFloat, CGFloat)] = [(p.redComponent, background.redComponent, ink.redComponent),
                                                        (p.greenComponent, background.greenComponent, ink.greenComponent),
                                                        (p.blueComponent, background.blueComponent, ink.blueComponent)]
        let (value, from, to) = channels.max { abs($0.2 - $0.1) < abs($1.2 - $1.1) }!
        return Double((value - from) / (to - from))
    }

    /// Pixels inked (more than half covered) in one bitmap and not the other, and the ink in `a`.
    /// Two rasterizers shade a curve's edge differently, so a pixel-for-pixel match is too strict.
    private static func mismatch(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, ink: Color, dark: Bool) -> (mismatched: Int, ink: Int) {
        let background = a.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var inkColor = NSColor.black
        appearance.performAsCurrentDrawingAppearance { inkColor = NSColor(ink).usingColorSpace(.sRGB)! }
        var mismatched = 0, inked = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                let p = coverage(a, x, y, background: background, ink: inkColor) > 0.5
                let q = coverage(b, x, y, background: background, ink: inkColor) > 0.5
                if p { inked += 1 }
                if p != q { mismatched += 1 }
            }
        }
        return (mismatched, inked)
    }

    @Test(arguments: [false, true]) func theGlowingDotDrawsTheDotItReplaced(dark: Bool) {
        let size = CGSize(width: 24, height: 24)
        let shape = Self.bitmap(Circle().fill(AgentState.attention.color), size: size, dark: dark)
        let layer = Self.bitmap(SHStatusDot(.attention, size: 24), size: size, dark: dark)

        let difference = Self.mismatch(shape, layer, ink: AgentState.attention.color, dark: dark)

        #expect(difference.ink > 300, "the dot drew: \(difference)")
        #expect(Double(difference.mismatched) < Double(difference.ink) * 0.1, "\(difference)")
    }
}

/// Main-thread CPU while idle, reported rather than asserted (it depends on the machine):
///
///     SHEPHERD_PERF_REPORT=1 swift test --filter IdleCostReport
@Suite("Idle cost report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
@MainActor
struct IdleCostReport {
    private let report = PerfReport()

    /// A relaunch restores twelve agents: one on screen, eleven mounted behind it and never
    /// visited. Idle for four seconds.
    @Test func restoredWorkspaceIdle() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<12 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        ListPerf.settle(window)

        var cpu: [Double] = []
        var frames: [Int] = []
        for _ in 0..<3 {
            var counted = 0
            cpu.append(await MainThreadCPU.milliseconds {
                SHRenderProbe.start()
                try? await Task.sleep(for: .seconds(4))
                counted = SHRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
        }
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: clock frames", "\(frames)")
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }

    /// One shimmer, one glowing dot, and an empty window for comparison, each alone in a window
    /// and idle for three seconds: main-thread CPU and the host's layout passes.
    @Test func continuousMotionIdle() async throws {
        let cases: [(String, AnyView)] = [
            ("empty window", AnyView(Color.clear.frame(width: 40, height: 40))),
            ("one shimmer", AnyView(Text("Running").shShimmer(active: true))),
            ("one glowing dot", AnyView(SHStatusDot(.attention))),
        ]
        for (name, view) in cases {
            var cpu: [Double] = []
            var layouts: [Int] = []
            for _ in 0..<3 {
                let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60), view.padding(10))
                try? await Task.sleep(for: .milliseconds(200))
                let before = window.host.layouts
                cpu.append(await MainThreadCPU.milliseconds { try? await Task.sleep(for: .seconds(3)) })
                layouts.append(window.host.layouts - before)
                window.close()
            }
            report.add(name, "idle 3 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
            report.add(name, "idle 3 s: host layout passes", "\(layouts)")
        }
    }

    /// A running thread whose reply has paused (nothing moves but the text it streams), idle for
    /// three seconds.
    @Test func runningThreadIdle() async throws {
        var cpu: [Double] = []
        for _ in 0..<3 {
            let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2) + [ThreadFixture.user("u", "Go")],
                                                           provisional: [ThreadFixture.streaming("Working on it.")], running: true))
            try await thread.waitUntilReady()
            cpu.append(await MainThreadCPU.milliseconds { try? await Task.sleep(for: .seconds(3)) })
            thread.close()
        }
        report.add("running thread (paused reply)", "idle 3 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }

    /// One loaded thread of two messages, idle for two seconds.
    @Test func loadedThreadIdle() async throws {
        var cpu: [Double] = []
        var frames: [Int] = []
        for _ in 0..<3 {
            let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)))
            try await thread.waitUntilReady()
            var counted = 0
            cpu.append(await MainThreadCPU.milliseconds {
                SHRenderProbe.start()
                try? await Task.sleep(for: .seconds(2))
                counted = SHRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
            thread.close()
        }
        report.add("loaded thread (2 messages)", "idle 2 s: clock frames", "\(frames)")
        report.add("loaded thread (2 messages)", "idle 2 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }
}
