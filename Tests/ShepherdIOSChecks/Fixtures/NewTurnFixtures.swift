import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var newTurn: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            // The reader drags to the end of the long thread, which ends in a 24 KB reply, and the host starts a new turn: the user's row
            // and a live reply that streams. On no display frame is the view more than `NewTurnFixture.jolt` above the tail, and it
            // rests on the tail with the reply drawn. On iOS 27.1 the view was thrown 8,900 to 12,219 pt back for 183 to 231 ms in
            // most launches on a phone, and 61,000 pt and up for 73 to 551 ms on the Duo's open display.
            FixtureScreen(name: "thread-new-turn", hosts: NewTurnFixture.hosts(), routes: [.thread(thread)],
                          prepare: { await NewTurnFixture.run($0, reader: .atTail) }),
            // The same new turn for a reader who scrolled up into the thread and dragged back down to the end.
            FixtureScreen(name: "thread-new-turn-from-above", hosts: NewTurnFixture.hosts(), routes: [.thread(thread)],
                          prepare: { await NewTurnFixture.run($0, reader: .backFromAbove) }),
        ]
    }
}

/// "thread-new-turn": a following transcript stays on its tail when a new turn starts, counted display frame by display frame.
///
/// The host's thread is 150 turns of prose, lists, code and tool rows, then a question and a 24 KB reply. The reader drags to the
/// end and follows it. Then the host pushes the next turn as pi does when it takes a message: the user's row and a live reply that
/// grows at 1,200 characters a second. Every frame from the push until the reply is drawn is read against the tail; the screen fails
/// when more than `jolt` points of it are over the limit.
@MainActor
enum NewTurnFixture {
    /// A frame this far above the tail shows the previous reply where the new turn should be. A screen is about 850 pt.
    static let jolt: CGFloat = 400
    /// Frames beyond the limit that the screen allows: none.
    static let joltBudget = 0
    private static let rate = 1_200.0
    private static let stepsPerSecond = 30.0
    /// Four seconds of the live reply: the jolts began within 35 ms of the new rows and ended within 0.6 s.
    private static let replyLength = 4_800

    enum Reader {
        /// Following the tail when the turn starts, as after a drag to the end.
        case atTail
        /// Scrolled up into the thread first, then dragged back down to the end.
        case backFromAbove
    }

    static func hosts() -> [FixtureHostData] {
        var hosts = ThreadFixtures.hosts(preview: Host.shared.snapshot())
        let earlier = hosts[0].reply
        hosts[0].reply = { request in
            guard case .nativeThread(let id, let agentID, .snapshot(_, _, let after)) = request, agentID == FixtureData.preview else {
                return earlier?(request)
            }
            let snapshot = Host.shared.snapshot()
            if after == snapshot.revision {
                return .nativeThread(id: id, result: .unchanged(piSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                                                revision: snapshot.revision))
            }
            return .nativeThread(id: id, result: .snapshot(value: snapshot))
        }
        return hosts
    }

    static func run(_ app: MobileApp, reader: Reader) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        let place = app.navigator.composerPresentation.state(for: ref)
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(1.5))
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        let gutter = TailFixture.gutter(of: scroll)
        let rest = gutter + NativeScrollFollower.repinSlack
        if reader == .backFromAbove {
            await TailFixture.Finger(scroll: scroll).drag(by: -4_000)
            try? await Task.sleep(for: .seconds(1))
            FixtureCheck.report("FIXTURE CHECK ok: scrolled up, follows \(place.follows)")
        }
        // The synthetic drag can end while the content's estimate is still moving, which leaves a reader (correctly) detached: start
        // once the follower rests on the tail.
        var resting = false
        for _ in 1...6 {
            await TailFixture.Finger(scroll: scroll).toEnd()
            try? await Task.sleep(for: .seconds(1.5))
            resting = place.scrollFollower.sticky && distance(scroll) <= rest
            if resting { break }
        }
        let held = place.visibleTurn ?? "nil"
        guard resting else { return FixtureCheck.report("FIXTURE CHECK FAILED: the reader did not come to rest on the tail before the new turn") }
        let frames = Frames(scroll: scroll, gutter: gutter)
        SHRenderProbe.start()
        frames.start()
        Host.shared.start(length: replyLength, rate: rate, stepsPerSecond: stepsPerSecond)
        await FixtureWindows.wait("the new turn to finish", seconds: 60) { Host.shared.isFinished }
        await FixtureWindows.wait("the reply to be drawn", seconds: 30) { !store.running }
        let settled = await TailFixture.shown(within: .seconds(6)) { $0.atTail }
        let result = frames.stop()
        let counts = SHRenderProbe.stop()
        let landings = counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]
        let shown = TailFixture.shown()
        let drawn = store.rows.last?.turn.messages.last?.blocks.last?.text.count ?? -1
        FixtureCheck.report("FIXTURE CHECK ok: new turn, reader \(reader), turn held before \(held): \(result.frames) frames, "
            + "\(result.over) over \(Int(jolt))pt (from \(result.firstMs) ms to \(result.lastMs) ms), farthest \(Int(result.farthest.rounded()))pt above the tail, "
            + "\(result.backJumps) back jumps, \(result.shrinks) shrinks of the content, \(landings) landings, \(counts["thread.tailRepair", default: 0]) repairs "
            + "(counted in a debug build only), \(drawn) of \(replyLength) characters drawn, "
            + "\(shown.distance)pt above the tail at rest, \(Int((shown.ink * 100).rounded()))% ink")
        FixtureCheck.report("FIXTURE CHECK \(drawn == replyLength ? "ok" : "FAILED"): the new turn's reply reached the thread in full")
        FixtureCheck.report("FIXTURE CHECK \(result.over <= joltBudget ? "ok" : "FAILED"): the new turn leaves a following transcript within \(Int(jolt))pt of its tail on every frame")
        FixtureCheck.report("FIXTURE CHECK \(settled.atTail ? "ok" : "FAILED"): the transcript rests on its tail after the new turn")
        FixtureCheck.report("FIXTURE CHECK \(shown.ink >= TailFixture.inkFloor ? "ok" : "FAILED"): the transcript draws after the new turn")
    }

    /// Points the thread's visible bottom sits above the end of its content.
    private static func distance(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y - scroll.bounds.height
    }

    /// The thread's frames from the push on: how far each was above the tail's resting place.
    @MainActor private final class Frames {
        struct Result {
            var frames: Int
            var over: Int
            var firstMs: Int
            var lastMs: Int
            var farthest: CGFloat
            var backJumps: Int
            var shrinks: Int
        }

        private let gutter: CGFloat
        private var scroll: UIScrollView?
        private var link: CADisplayLink?
        private var began = 0.0
        private var frames = 0
        private var over = 0
        private var first = -1.0
        private var last = -1.0
        private var farthest: CGFloat = 0
        private var offset: CGFloat
        private var content: CGFloat
        private var backJumps = 0
        private var shrinks = 0

        init(scroll: UIScrollView, gutter: CGFloat) {
            self.scroll = scroll
            self.gutter = gutter
            offset = scroll.contentOffset.y
            content = scroll.contentSize.height
        }

        func start() {
            let ticker = Ticker { [weak self] now in self?.tick(now) }
            let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            began = CACurrentMediaTime()
        }

        private func tick(_ now: CFTimeInterval) {
            if scroll?.window == nil { scroll = FollowFixture.threadScrollView() }
            guard let scroll else { return }
            frames += 1
            let away = NewTurnFixture.distance(scroll) - gutter
            let at = (now - began) * 1000
            farthest = max(farthest, away)
            if away > NewTurnFixture.jolt {
                over += 1
                if first < 0 { first = at }
                last = at
            }
            if scroll.contentOffset.y < offset - 100 { backJumps += 1 }
            if scroll.contentSize.height < content - 100 { shrinks += 1 }
            offset = scroll.contentOffset.y
            content = scroll.contentSize.height
        }

        func stop() -> Result {
            link?.invalidate()
            link = nil
            return Result(frames: frames, over: over, firstMs: Int(max(first, 0).rounded()), lastMs: Int(max(last, 0).rounded()),
                          farthest: farthest, backJumps: backJumps, shrinks: shrinks)
        }
    }

    private final class Ticker: NSObject {
        let tick: @MainActor (CFTimeInterval) -> Void
        init(_ tick: @escaping @MainActor (CFTimeInterval) -> Void) { self.tick = tick }
        @objc func fire(_ link: CADisplayLink) {
            let now = link.timestamp
            MainActor.assumeIsolated { tick(now) }
        }
    }

    /// The host side of the new turn: the thread as it was, then, once started, the user's row and a live reply that grows; the
    /// finished reply joins the thread. A revision hint goes to the app after each step, as a pushing host sends it.
    private final class Host: @unchecked Sendable {
        static let shared = Host()

        private let lock = NSLock()
        private let history = NewTurnFixture.thread().messages
        private var text = ""
        private var revealed = 0
        private var revision: UInt64 = 2
        private var running = false
        private var finished = false

        var isFinished: Bool { lock.withLock { finished } }

        private func prompt() -> NativeThreadMessage {
            FixtureData.user("nt-u", "Now tighten that up: keep the lease and the retry rules, drop the rest.", at: 9_000_000)
        }

        private func reply(status: String?) -> NativeThreadMessage {
            FixtureData.assistant("nt-a", String(text.prefix(revealed)), at: 9_010_000, status: status)
        }

        func snapshot() -> NativeThreadSnapshot {
            lock.withLock {
                var snapshot: NativeThreadSnapshot
                if running {
                    snapshot = FixtureData.snapshot(history + [prompt()], running: true)
                    snapshot.provisional = [reply(status: "streaming")]
                } else if finished {
                    snapshot = FixtureData.snapshot(history + [prompt(), reply(status: nil)])
                } else {
                    snapshot = FixtureData.snapshot(history)
                }
                snapshot.revision = revision
                return snapshot
            }
        }

        func start(length: Int, rate: Double, stepsPerSecond: Double) {
            lock.withLock {
                text = String(TailFixture.longReply(cycles: 24).prefix(length))
                revealed = 0
                running = true
                revision += 1
            }
            notify()
            Thread.detachNewThread { [self] in
                let began = ProcessInfo.processInfo.systemUptime
                while true {
                    Thread.sleep(forTimeInterval: 1 / stepsPerSecond)
                    let elapsed = ProcessInfo.processInfo.systemUptime - began
                    let done: Bool = lock.withLock {
                        revealed = min(text.count, Int(elapsed * rate))
                        revision += 1
                        guard revealed >= text.count else { return false }
                        running = false
                        finished = true
                        return true
                    }
                    notify()
                    if done { return }
                }
            }
        }

        private func notify() {
            FixtureHost.running(FixtureData.studio)?.pushThreadChanged(FixtureData.preview)
        }
    }

    /// 150 turns of mixed rows, then a question and a 24 KB reply.
    nonisolated static func thread() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        var at = 0.0
        func step(_ ms: Double) -> Double { at += ms; return at }
        for turn in 0..<150 {
            messages.append(F.user("n\(turn)u", "Turn \(turn): look at the relay's retry path and tell me what it does when the broker is down.", at: step(20_000)))
            messages.append(F.assistant("n\(turn)a", prose(turn), at: step(3_000)))
            if turn % 3 == 0 {
                messages.append(F.tool("n\(turn)r", "read", args: #"{"path":"Sources/Relay/Retry\#(turn).swift"}"#,
                                       output: "func retry\(turn)() {\n    // backoff \(turn)\n}", at: step(1_500)))
            }
            if turn % 5 == 0 {
                messages.append(F.tool("n\(turn)e", "edit", args: #"{"path":"Sources/Relay/Outbox\#(turn).swift","oldText":"a","newText":"b"}"#,
                                       output: "Edited", at: step(1_500)))
            }
            if turn % 3 == 0 {
                messages.append(F.assistant("n\(turn)b", "Done: the retry path for turn \(turn) now backs off up to \(turn % 7 + 2) times before it parks the row.",
                                            at: step(2_000)))
            }
        }
        messages.append(F.user("nlu", "Write up the whole outbox design, section by section.", at: step(30_000)))
        messages.append(F.assistant("nla", TailFixture.longReply(cycles: 24), at: step(10_000)))
        return F.snapshot(messages)
    }

    private nonisolated static func prose(_ turn: Int) -> String {
        var text = "When the broker is down the relay keeps the row (\(turn)) in the outbox and tries again after a delay that doubles each time, up to a ceiling. "
        text += "It never drops a row, and it never sends one twice, because the lease on the row is only released after an acknowledgement."
        switch turn % 4 {
        case 0:
            text += "\n\n- Backoff starts at 200 ms.\n- The ceiling is 30 s.\n- A parked row is retried by the nightly sweep.\n\n```swift\nfunc next(after attempt: Int) -> Duration {\n    .milliseconds(min(200 << attempt, 30_000))\n}\n```"
        case 1:
            text += "\n\nThe interesting part is the **lease**: `Lease.renew()` runs every `ttl / 3`, so a slow broker never loses the row to another relay."
        case 2:
            text += "\n\n1. Read the next batch.\n2. Send each row.\n3. Mark the batch sent only after the last acknowledgement.\n\n> A crash between 2 and 3 repeats the batch, and consumers drop the duplicates by sequence number."
        default:
            break
        }
        return text
    }
}
