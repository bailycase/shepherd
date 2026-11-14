import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var tailFollowUps: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            // The long thread re-opened `remountCycles` times by a reader who left it holding the bottom marker (they dragged to the
            // end): the first row shows from the first frame, no repair and no mount jump is needed where the stack opens at the tail
            // by its landings (iOS 27.1), and the view rests on its tail, not past it.
            FixtureScreen(name: "thread-remount-marker", hosts: TailFixture.remountHosts(), routes: [.thread(thread)],
                          prepare: { app in await TailFixture.remountTail(app, holdingMarker: true) }),
            // The network drops under the connection while the reader follows the tail of the long thread: the offline notice joins the
            // top of the transcript, and leaves it when the app has reconnected. The view stays on its tail, on every display frame.
            FixtureScreen(name: "thread-banner-drop-tail", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.bannerAppears),
            // The Design tool's chat pane on an iPad in landscape gets another agent for its design (the host replaced it: the view is
            // reused, its ref changes): the long thread of the new agent draws from the first frames and rests on its tail, like a
            // transcript that mounts.
            FixtureScreen(name: "pad-design-chat-remount", hosts: TailFixture.designChatHosts(),
                          routes: [.padDesign(.list), .padDesign(.design(DesignPadFixtures.ref))],
                          prepare: { app in await TailFixture.designChatRemount(app) }),
        ]
    }
}

extension TailFixture {
    static let otherAgent = AgentID(rawValue: "agent-design-checkout-2")

    /// A frame this far above the tail shows the middle of the thread where the end should be. A screen is about 850 pt.
    static let bannerJolt: CGFloat = 400
    /// Frames beyond the limit that the screen allows: none.
    static let bannerJoltBudget = 0

    /// "thread-banner-drop-tail": the thread's host ends its connection while the reader follows the tail, and the notice (and its Retry
    /// button) joins the top of the transcript, above 150 turns and a 24 KB reply, then changes as the app reconnects and leaves it.
    /// Where the notice was a row of the lazy stack, each of those made the stack estimate its height again: the view was thrown
    /// hundreds of thousands of points from the tail for a few frames on a phone, and for two seconds on the Duo's open display. Every
    /// display frame from the drop until the view has rested is read against the tail: the screen fails when a frame is more than
    /// `bannerJolt` points above it, or the view does not rest on its tail with the transcript drawn.
    @MainActor static func bannerAppears(_ app: MobileApp) async {
        await ready(app)
        MainQueueWatchdog.start(limit: 5)
        _ = await shown(within: .seconds(5)) { $0.atTail && $0.ink >= inkFloor }
        let before = shown()
        let phase = { app.hosts.host(FixtureData.studio)?.phase.word ?? "gone" }
        let watch = TailWatch(jolt: bannerJolt, phase: phase)
        SHRenderProbe.start()
        watch.start()
        FixtureHost.running(FixtureData.studio)?.dropConnections()
        await FixtureWindows.wait("the drop", seconds: 5) { app.hosts.host(FixtureData.studio)?.phase.isConnected == false }
        let host = app.hosts.host(FixtureData.studio)?.phase
        // The app reconnects within a second or two, which takes the notice away again.
        await FixtureWindows.wait("the reconnect", seconds: 20) { app.hosts.host(FixtureData.studio)?.phase.isConnected == true }
        try? await Task.sleep(for: .seconds(3))
        let counts = SHRenderProbe.stop()
        let result = watch.stop()
        let rest = shown()
        FixtureCheck.report("FIXTURE CHECK ok: before the notice \(before.distance)pt from the tail, \(Int((before.ink * 100).rounded()))% ink; host \(host.map { "\($0)" } ?? "gone")")
        FixtureCheck.report("FIXTURE CHECK ok: over \(result.frames) frames the view was away from the tail on \(result.away) (\(Int(result.awayMilliseconds.rounded())) ms from the "
            + "first to the last), up to \(result.farthest)pt, \(result.beyondJolt) beyond \(Int(bannerJolt))pt, \(result.blank) with no row in view; "
            + "\(counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]) landings, \(counts["thread.tailRepair", default: 0]) repairs, "
            + "\(counts["thread.tailMountJump", default: 0]) mount jumps; first frames away \(result.trace); at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink")
        FixtureCheck.report("FIXTURE CHECK \(result.beyondJolt <= bannerJoltBudget ? "ok" : "FAILED"): the notice joining moves the view no more than \(Int(bannerJolt))pt from the tail")
        FixtureCheck.report("FIXTURE CHECK \(rest.atTail && rest.ink >= inkFloor ? "ok" : "FAILED"): the view rests on its tail, drawn")
    }
}

/// How far from its tail the thread's view is on each display frame from `start()`, with the rows in view.
@MainActor final class TailWatch {
    struct Result {
        var frames = 0
        /// Frames more than a landing's slack from where a landing leaves the view, and the farthest of them.
        var away = 0
        var farthest = 0
        /// Frames more than `jolt` points from the tail.
        var beyondJolt = 0
        /// Frames with the scroll view in place and no built row in view.
        var blank = 0
        /// From the first frame away from the tail to the last.
        var awayMilliseconds = 0.0
        /// The first frames away: when (ms from `start()`), how far, and the host's phase then.
        var trace: [String] = []
    }

    private let jolt: CGFloat
    private let phase: () -> String
    private var began = CACurrentMediaTime()
    private var result = Result()
    private var link: CADisplayLink?
    private var ticker: Ticker?
    private var firstAway: CFTimeInterval?
    private var lastAway: CFTimeInterval?
    private weak var scroll: UIScrollView?

    init(jolt: CGFloat, phase: @escaping () -> String) {
        self.jolt = jolt
        self.phase = phase
    }

    func start() {
        began = CACurrentMediaTime()
        let ticker = Ticker { [weak self] in self?.tick() }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire))
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link
    }

    func stop() -> Result {
        link?.invalidate()
        link = nil
        var done = result
        if let firstAway, let lastAway { done.awayMilliseconds = (lastAway - firstAway) * 1000 }
        return done
    }

    private func tick() {
        result.frames += 1
        if scroll?.window == nil { scroll = FollowFixture.threadScrollView() }
        guard let scroll else { return }
        let distance = TailFixture.tailDistance(of: scroll)
        if TailFixture.builtRows(in: scroll) == 0 { result.blank += 1 }
        guard distance > NativeScrollFollower.repinSlack + TailFixture.gutter(of: scroll) else { return }
        let now = CACurrentMediaTime()
        firstAway = firstAway ?? now
        lastAway = now
        result.away += 1
        if result.trace.count < 8 { result.trace.append("\(Int(((now - began) * 1000).rounded())) ms \(Int(distance.rounded()))pt \(phase())") }
        result.farthest = max(result.farthest, Int(distance.rounded()))
        if distance > jolt { result.beyondJolt += 1 }
    }

    private final class Ticker: NSObject {
        let tick: () -> Void
        init(_ tick: @escaping () -> Void) { self.tick = tick }
        @objc func fire() { tick() }
    }
}

extension TailFixture {
    /// The design host with the long thread as the chat of its design's agent and of the agent that replaces it.
    static func designChatHosts() -> [FixtureHostData] {
        var hosts = DesignPadFixtures.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        var agent = FixtureData.agent(otherAgent, "Checkout funnel dashboard", .done)
        agent.designID = DesignPadFixtures.designID
        hosts[index].state.agents.append(agent)
        hosts[index].threads[DesignPadFixtures.agentID] = thread()
        hosts[index].threads[otherAgent] = thread()
        return hosts
    }

    /// "pad-design-chat-remount": the design pane shows the long thread of its design's agent, then the host gives the design
    /// another agent with the same long thread. The chat's scroll view is read on every display frame from the change: at most
    /// `remountBlankFrames` of them with no built row in view, and the view rests on its tail with the transcript drawn.
    @MainActor static func designChatRemount(_ app: MobileApp) async {
        let first = DesignPadFixtures.agentRef
        let second = AgentRef(host: FixtureData.studio, agent: otherAgent)
        _ = await DesignPadFixtures.settle(app)
        await FixtureWindows.wait("the first design's chat", seconds: 30) { app.threads.store(for: first).rows.count > 150 && shownThreadScroll() != nil }
        try? await Task.sleep(for: .seconds(2))
        guard let scroll = shownThreadScroll(), scroll.traitCollection.horizontalSizeClass == .regular else {
            return FixtureCheck.report("FIXTURE CHECK ok: no design pane beside the canvas on this layout")
        }
        MainQueueWatchdog.start(limit: 5)
        let before = shown()
        let watch = TailWatch(jolt: bannerJolt, phase: { "" })
        SHRenderProbe.start()
        watch.start()
        guard let host = FixtureHost.running(FixtureData.studio), let design = host.data.state.designs.firstIndex(where: { $0.id == DesignPadFixtures.designID }) else {
            return FixtureCheck.report("FIXTURE CHECK FAILED: no design host")
        }
        var state = host.data.state
        state.designs[design].agentID = otherAgent
        host.push(state)
        await FixtureWindows.wait("the new agent's chat", seconds: 30) { app.threads.store(for: second).rows.count > 150 }
        try? await Task.sleep(for: .seconds(3))
        let counts = SHRenderProbe.stop()
        let result = watch.stop()
        let reused = shownThreadScroll() === scroll
        let shownAgent = PadDesigns.of(app.hosts).design(DesignPadFixtures.ref)?.agentID
        let rest = shown()
        FixtureCheck.report("FIXTURE CHECK ok: chat view \(reused ? "reused" : "rebuilt"), design's agent \(shownAgent == otherAgent ? "replaced" : "unchanged"); before \(before.distance)pt from the tail; over \(result.frames) frames \(result.blank) with no row "
            + "in view, \(result.away) away from the tail (farthest \(result.farthest)pt); \(counts["thread.tailMountJump", default: 0]) mount jumps, "
            + "\(counts["thread.tailRepair", default: 0]) repairs, \(counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]) landings; "
            + "at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink")
        FixtureCheck.report("FIXTURE CHECK \(result.blank <= remountBlankFrames ? "ok" : "FAILED"): the new agent's chat shows a row on all but \(remountBlankFrames) frames")
        FixtureCheck.report("FIXTURE CHECK \(rest.atTail && rest.ink >= inkFloor ? "ok" : "FAILED"): the new agent's chat rests on its tail, drawn")
    }
}
