import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// "duo-pane-long-reply": a following thread whose newest reply is 24 KB, with the side pane
/// opened and closed ten times in a row (`withSHAnimation(.pane)`, as the toolbar button does).
/// Where the pane toggle rebuilds the detail column, the new transcript mounts on the long reply
/// and lands on its tail inside the layout pass; the audit saw that spin the main thread
/// (ios-duo-1). After each toggle it checks that the landings stayed few, the pin did not give
/// up, the reply ends above the composer and the transcript draws. A watchdog thread fails the
/// run if the main queue stops answering. Run it posed open on the Duo, or in landscape on an
/// iPad; where there is no side pane it says so.
enum TailFixture {
    static let toggles = 10
    /// Landings with the content moving by itself one toggle may make: the pin stops after this many.
    static let landingCeiling = 2 * NativeTailRepin.limit + 1
    /// A drawn transcript is mostly text on a background; a blank one has no ink.
    static let inkFloor = 0.02

    static func hosts() -> [FixtureHostData] {
        ThreadFixtures.hosts(preview: thread())
    }

    /// 150 short turns, then a question and a reply that runs 24 KB.
    static func thread() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        for turn in 0..<150 {
            let at = Double(turn) * 20_000
            messages.append(F.user("t\(turn)u", "Reply with exactly: tail-\(turn)", at: at))
            messages.append(F.assistant("t\(turn)a", "tail-\(turn)", at: at + 2_000))
        }
        messages.append(F.user("lu", "Write up the whole outbox design, section by section.", at: 3_100_000))
        messages.append(F.assistant("la", longReply(cycles: 24), at: 3_110_000))
        return F.snapshot(messages)
    }

    /// About 1 KB of prose, a list and a code block per cycle.
    static func longReply(cycles: Int) -> String {
        let topics = ["queue", "outbox", "ledger", "retry", "lease", "cursor", "batch", "replay"]
        return (1...cycles).map { n in
            let topic = topics[n % topics.count]
            return """
            ## Part \(n): the \(topic) path

            Every message the service sends first lands in the \(topic) table inside the same transaction as the change that caused it, \
            so a crash between the two can never lose one or send one twice. A relay reads the rows in order, hands each to the broker, \
            and marks it sent only after the broker has acknowledged it; a row whose acknowledgement never arrives is read again on the next pass.

            - Keep the \(topic) rows small and append-only.
            - Number them per aggregate so a consumer can drop a duplicate.
            - Delete a row only after every consumer has moved past it.

            ```swift
            func relay\(n)(batch: [Row]) async throws {
                for row in batch { try await broker.send(row.payload, key: row.aggregate) }
            }
            ```
            """
        }.joined(separator: "\n\n")
    }

    @MainActor static func togglePane(_ app: MobileApp) async {
        let navigator = app.navigator
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(1.5))
        guard FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular else {
            return FixtureCheck.report("FIXTURE CHECK ok: no side pane on this layout")
        }
        MainQueueWatchdog.start(limit: 5)
        // Every toggle is measured before any verdict, so a failing run still shows all ten.
        var measured: [String] = []
        var verdicts: [(ok: Bool, line: String)] = []
        for toggle in 1...toggles {
            SHRenderProbe.start()
            withSHAnimation(.pane) { navigator.sidePane.isOpen.toggle() }
            await settle()
            let counts = SHRenderProbe.stop()
            let content = counts["thread.tailLanding", default: 0]
            let resized = counts["thread.tailLandingResized", default: 0]
            let stalled = counts["thread.tailStalled", default: 0]
            let pane = navigator.sidePane.isOpen ? "open" : "closed"
            let gutter = FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular ? MobileLayout.padThreadGutter : MobileLayout.gutter
            let tail = FollowFixture.tail { $0 <= gutter + 1 }
            let distance = Int((tail?.distance ?? .infinity).rounded())
            let ink = FollowFixture.transcriptInk()
            let percent = Int((ink * 100).rounded())
            measured.append("toggle \(toggle) (pane \(pane)): \(content) landings with the content moving, \(resized) with the width, \(stalled) stalls, \(distance)pt above the tail, \(percent)% ink")
            verdicts.append((content <= landingCeiling && stalled == 0, "toggle \(toggle): at most \(landingCeiling) landings with the content moving, none stalled"))
            verdicts.append((tail?.valid == true, "toggle \(toggle): the reply ends above the composer"))
            verdicts.append((ink >= inkFloor, "toggle \(toggle): the transcript draws"))
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(toggles) toggles")
    }

    /// Waits until 300 ms pass with no landing and no stretch where the main thread was too busy to
    /// answer (a landing may be queued behind what blocked it), at most 3 s.
    @MainActor private static func settle() async {
        func landings() -> Int { SHRenderProbe.count("thread.tailLanding") + SHRenderProbe.count("thread.tailLandingResized") }
        let clock = ContinuousClock()
        let started = clock.now
        var last = landings()
        var quietSince = started
        var woke = started
        while clock.now - started < .seconds(3), clock.now - quietSince < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(20))
            let now = clock.now
            if now - woke > .milliseconds(100) || landings() != last {
                last = landings()
                quietSince = now
            }
            woke = now
        }
    }
}

/// Fails the run when the main queue stops answering: a thread asks it for a heartbeat every 50 ms.
final class MainQueueWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = ProcessInfo.processInfo.systemUptime
    private static var shared: MainQueueWatchdog?

    static func start(limit: Double) {
        let watchdog = MainQueueWatchdog()
        shared = watchdog
        Thread.detachNewThread {
            while true {
                DispatchQueue.main.async { watchdog.answer() }
                Thread.sleep(forTimeInterval: 0.05)
                let silent = ProcessInfo.processInfo.systemUptime - watchdog.lastAnswer
                if silent > limit {
                    FixtureCheck.fail("the main queue did not answer for \(Int(silent)) s (a landing loop in the transcript?)")
                }
            }
        }
    }

    private func answer() {
        lock.withLock { answered = ProcessInfo.processInfo.systemUptime }
    }

    private var lastAnswer: Double { lock.withLock { answered } }
}
