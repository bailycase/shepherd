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

/// What the app costs while nothing changes (DESIGN.md › Performance): motion no one sees costs
/// nothing, and motion on screen costs the app no frames. The spinner and the glow turn on the
/// render server (a Core Animation animation on their layer); a spinner in a layout the
/// workspace keeps mounted but hidden, or in a row a lazy stack has let go of, rests. Counted in
/// frames the clock-driven motions draw (`NWRenderProbe`), host layout passes, and the layers
/// carrying an animation, none of which a slow machine changes.
@Suite("Idle cost", .mainActorExclusive)
@MainActor
struct IdleCostTests {
    static let clockKeys = ["ui.spinnerFrame", "ui.glowFrame", "ui.shimmerFrame"]

    /// Clock frames drawn over `seconds` of run loop.
    static func clockFrames(over seconds: Double = 1) async -> Int {
        NWRenderProbe.start()
        try? await Task.sleep(for: .seconds(seconds))
        let counts = NWRenderProbe.stop()
        return clockKeys.reduce(0) { $0 + counts[$1, default: 0] }
    }

    static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// Spinners in `root`, and how many of them turn.
    static func spinners(in root: NSView) -> (all: Int, turning: Int) {
        let all = views(NWSpinnerLayerView.self, in: root)
        return (all.count, all.filter { $0.arc.animation(forKey: NWLayerMotion.spinKey) != nil }.count)
    }

    static func glows(in root: NSView) -> (all: Int, pulsing: Int) {
        let all = views(NWGlowLayerView.self, in: root)
        return (all.count, all.filter { $0.dot.animation(forKey: NWLayerMotion.glowKey) != nil }.count)
    }

    /// A thread that has loaded draws no spinner: "Starting pi…" is gone for good, not turning
    /// where no one sees it.
    @Test func aLoadedThreadDrawsNoSpinnerFrames() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)))
        defer { thread.close() }
        try await thread.waitUntilReady()

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        #expect(Self.spinners(in: thread.window.host).turning == 0)
    }

    /// The control: a thread whose pi keeps it waiting says so in its composer, and that spinner
    /// turns.
    @Test func aVisibleStartingThreadStillSpins() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]), starting: true, reduceMotion: false)
        defer { thread.close() }
        let store = thread.store
        let host = thread.window.host
        try await eventuallyOnMain("pi to be reported starting") { store.starting }
        try await eventuallyOnMain("the composer to say pi is starting") {
            ListPerf.settle(thread.window)
            return Self.spinners(in: host).all == 1
        }

        #expect(Self.spinners(in: host).turning == 1)
    }

    /// Layouts the workspace keeps mounted behind the visible one draw no clock frames, and
    /// nothing in them turns. Each hidden thread has a turn running (stub pi `slow`, held at its
    /// first pause), so it keeps a working row whose spinner must rest while its layout is hidden.
    @Test func hiddenLayoutsDrawNoClockFrames() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<4 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }
        // Every stub pi runs in this directory, so these release every held turn at the end.
        defer {
            for name in ["continue-1", "continue-2"] {
                FileManager.default.createFile(atPath: app.dir.appendingPathComponent(name).path, contents: nil)
            }
        }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        // Reduce Motion pinned off: the hidden spinners must be ones that would otherwise turn.
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
            try await eventuallyOnMain("\(agent.agent.name)'s turn to hold at its first pause", timeout: .seconds(30)) {
                ListPerf.settle(window)
                return store.running && Self.spinners(in: window.host).turning >= 1
            }
        }
        vm.selectAgent(agents[0].agent.id)
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        ListPerf.settle(window)

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        let spinners = Self.spinners(in: window.host)
        #expect(spinners.all >= agents.count - 1 && spinners.turning == 0, "\(spinners)")
    }

    /// A paused spinner resumes as its layout comes back on screen.
    @Test func aLayoutShownAgainResumesItsSpinner() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2) + [ThreadFixture.user("u", "Go")],
                                                       provisional: [ThreadFixture.streaming("Working on it.")], running: true),
                                reduceMotion: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.visibility.motionPaused = true
        ListPerf.settle(thread.window)
        let paused = Self.spinners(in: thread.window.host)
        #expect(paused.all > 0 && paused.turning == 0, "rests while hidden: \(paused)")

        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)

        let shown = Self.spinners(in: thread.window.host)
        #expect(shown.turning == shown.all, "\(shown)")
    }

    // MARK: Render-server motion

    /// A spinner turning and an attention dot glowing, on screen: SwiftUI draws no frame for them
    /// and never lays the window out again.
    @Test func aRunningSpinnerAndAGlowingDotCostTheAppNoFrames() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { ProgressView().progressViewStyle(.nwSpinner); NWStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.spinners(in: window.host).turning == 1 && Self.glows(in: window.host).pulsing == 1)
        let layouts = window.host.layouts

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
        #expect(window.host.layouts - layouts == 0, "\(window.host.layouts - layouts) host layout passes")
    }

    @Test func theSpinnerAndTheGlowRepeatAtTheirAnchors() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { ProgressView().progressViewStyle(.nwSpinner); NWStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, false))
        defer { window.close() }
        let spinner = try #require(Self.views(NWSpinnerLayerView.self, in: window.host).first)
        let dot = try #require(Self.views(NWGlowLayerView.self, in: window.host).first)

        let spin = try #require(spinner.arc.animation(forKey: NWLayerMotion.spinKey) as? CABasicAnimation)
        #expect(spin.keyPath == "transform.rotation.z" && spin.duration == NW.Motion.spin.duration && spin.repeatCount == .infinity)
        #expect(abs(abs((spin.toValue as? Double) ?? 0) - 2 * .pi) < 1e-9, "one turn per period")
        let glow = try #require(dot.dot.animation(forKey: NWLayerMotion.glowKey) as? CAKeyframeAnimation)
        #expect(glow.keyPath == "opacity" && glow.duration == NW.Motion.glow.duration && glow.repeatCount == .infinity)
    }

    /// Reduce Motion, and a hidden layout, leave the arc and the dot at rest.
    @Test(arguments: ["reduce motion", "paused"]) func nothingTurnsOrGlowsAtRest(reason: String) async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60),
                                          HStack { ProgressView().progressViewStyle(.nwSpinner); NWStatusDot(.attention) }.padding(10)
                                              .environment(\._accessibilityReduceMotion, reason == "reduce motion")
                                              .environment(\.nwMotionPaused, reason == "paused"))
        defer { window.close() }

        let spinners = Self.spinners(in: window.host), glows = Self.glows(in: window.host)

        #expect(spinners.all == 1 && spinners.turning == 0)
        #expect(glows.all == 1 && glows.pulsing == 0)
        #expect(Self.views(NWGlowLayerView.self, in: window.host).first?.dot.opacity == 1, "a resting dot is fully lit")
    }

    @MainActor @Observable final class Scheme {
        var value: ColorScheme = .light
    }

    private struct SchemedSpinner: View {
        let scheme: Scheme

        var body: some View {
            HStack { ProgressView().progressViewStyle(.nwSpinner); NWStatusDot(.attention) }
                .padding(10)
                .environment(\.colorScheme, scheme.value)
        }
    }

    /// The layers take their colors from the theme's tokens as the view's appearance resolves
    /// them, again whenever it changes: switching to dark recolors a spinner and a dot in place.
    @Test func anAppearanceSwitchRecolorsTheSpinnerAndTheDot() throws {
        let scheme = Scheme()
        let window = LayoutCountingWindow(size: CGSize(width: 120, height: 60), SchemedSpinner(scheme: scheme))
        defer { window.close() }
        let spinner = try #require(Self.views(NWSpinnerLayerView.self, in: window.host).first)
        let dot = try #require(Self.views(NWGlowLayerView.self, in: window.host).first)
        func expected(_ color: Color, _ scheme: ColorScheme) -> CGColor {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            return color.resolve(in: environment).cgColor
        }
        #expect(spinner.arc.strokeColor == expected(Color.nw.running, .light))
        #expect(dot.dot.fillColor == expected(AgentState.attention.color, .light))

        scheme.value = .dark
        window.window.layoutIfNeeded()
        window.host.layoutSubtreeIfNeeded()

        #expect(spinner.arc.strokeColor == expected(Color.nw.running, .dark))
        #expect(dot.dot.fillColor == expected(AgentState.attention.color, .dark))
        #expect(expected(Color.nw.running, .light) != expected(Color.nw.running, .dark), "the token has two colors")
    }

    /// Every spinner turns in step with the clock (`NWPhase`), as the timeline-drawn one did.
    @Test(.timingSensitive) func aSpinnerTurnsInStepWithTheClock() async throws {
        let window = LayoutCountingWindow(size: CGSize(width: 60, height: 60), ProgressView().progressViewStyle(.nwSpinner).padding(10))
        defer { window.close() }
        let spinner = try #require(Self.views(NWSpinnerLayerView.self, in: window.host).first)
        try await Task.sleep(for: .milliseconds(100))

        let angle = try #require(spinner.arc.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
        let expected = -2 * .pi * NWPhase.fraction(Date(), .spin)

        let apart = abs(remainder(angle - expected, 2 * .pi))
        #expect(apart < 0.5, "at \(angle), the clock's phase is \(expected)")
    }

    // MARK: The look

    /// The arc as SwiftUI drew it before it turned on the render server.
    private struct ShapeArc: View {
        let size: CGFloat

        var body: some View {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.nw.running, style: StrokeStyle(lineWidth: max(1.5, size * 0.145), lineCap: .round))
                .padding(max(1.5, size * 0.145) / 2)
                .frame(width: size, height: size)
        }
    }

    private static func bitmap(_ view: some View, size: CGSize, dark: Bool) -> NSBitmapImageRep {
        let window = OffscreenWindow(size: size, dark: dark, view.frame(width: size.width, height: size.height)
            .background(Color.nw.bgWindow).environment(\._accessibilityReduceMotion, true))
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

    /// At rest the layer arc draws what the shape did: the same 3/4 ring, open from twelve to
    /// three o'clock, with its stroke, round caps, and color, in both appearances.
    @Test(arguments: [false, true]) func theSpinnerDrawsTheArcItReplaced(dark: Bool) {
        let size = CGSize(width: 48, height: 48)
        let shape = Self.bitmap(ShapeArc(size: 48), size: size, dark: dark)
        let layer = Self.bitmap(ProgressView().progressViewStyle(.nwSpinner(size: 48)), size: size, dark: dark)

        let difference = Self.mismatch(shape, layer, ink: Color.nw.running, dark: dark)

        #expect(difference.ink > 500, "the arc drew: \(difference)")
        #expect(Double(difference.mismatched) < Double(difference.ink) * 0.15, "\(difference)")
        // On the ring: open at half past one, drawn at half past four (a mirror swaps the two).
        let background = shape.colorAt(x: 0, y: 0)!
        for bitmap in [shape, layer] {
            #expect(bitmap.colorAt(x: 38, y: 9) == background, "the gap is top-right")
            #expect(bitmap.colorAt(x: 38, y: 38) != background, "the arc passes bottom-right")
        }
    }

    @Test(arguments: [false, true]) func theGlowingDotDrawsTheDotItReplaced(dark: Bool) {
        let size = CGSize(width: 24, height: 24)
        let shape = Self.bitmap(Circle().fill(AgentState.attention.color), size: size, dark: dark)
        let layer = Self.bitmap(NWStatusDot(.attention, size: 24), size: size, dark: dark)

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
                NWRenderProbe.start()
                try? await Task.sleep(for: .seconds(4))
                counted = NWRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
        }
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: clock frames", "\(frames)")
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }

    /// One spinner, one glowing dot, and an empty window for comparison, each alone in a window
    /// and idle for three seconds: main-thread CPU and the host's layout passes.
    @Test func continuousMotionIdle() async throws {
        let cases: [(String, AnyView)] = [
            ("empty window", AnyView(Color.clear.frame(width: 40, height: 40))),
            ("one spinner", AnyView(ProgressView().progressViewStyle(.nwSpinner))),
            ("one glowing dot", AnyView(NWStatusDot(.attention))),
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

    /// A running thread whose reply has paused (its working row's spinner turning), idle for
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
        report.add("running thread (working row)", "idle 3 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
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
                NWRenderProbe.start()
                try? await Task.sleep(for: .seconds(2))
                counted = NWRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
            thread.close()
        }
        report.add("loaded thread (2 messages)", "idle 2 s: clock frames", "\(frames)")
        report.add("loaded thread (2 messages)", "idle 2 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }
}
