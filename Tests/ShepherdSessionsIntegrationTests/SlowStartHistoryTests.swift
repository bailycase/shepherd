import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A pi slower than the request deadline is asked again (`RPCThreadState.bootstrap`). The history
/// it sends for the retry can take a while to arrive, and until it has the thread is starting, not
/// served empty and clipped.
@Suite("Thread history after a slow start", .integrationTimeLimit)
struct SlowStartHistoryTests {
    @Test func aPiSlowerThanTheDeadlineIsNotServedWithoutItsHistory() async throws {
        let t = try ThreadEventTests.Thread(bootstrap: false, env: ["STUB_PI_STARTUP_GATE": "release-pi", "STUB_PI_HISTORY_BYTES": "1048576"])
        defer { t.stop() }
        let decodes = Locked(0)
        let hold = DispatchSemaphore(value: 0)
        t.session.beforeOffQueueDecode = {
            // The first big record answers the attempt that gave up; the retry's is held.
            if decodes.withValue({ $0 += 1; return $0 }) >= 2 { hold.wait() }
        }
        t.queue.async { t.state.bootstrap(timeout: 1) }
        try await eventually("the bootstrap to ask again") {
            await withCheckedContinuation { continuation in t.queue.async { continuation.resume(returning: t.state.bootstrapAttempts >= 2) } }
        }
        FileManager.default.createFile(atPath: t.dir.appendingPathComponent("release-pi").path, contents: nil)
        try await eventually("pi to answer the retry's state while its history is held") {
            await withCheckedContinuation { continuation in t.queue.async { continuation.resume(returning: t.state.piSessionID != nil) } }
        }

        #expect(await t.request(.snapshot()).failureCode == NativeThreadCode.starting, "the history is still on its way")
        hold.signal()
        var landed: NativeThreadSnapshot?
        try await eventually("the history to land") {
            landed = await t.request(.snapshot()).snapshotValue
            return landed?.messages.isEmpty == false
        }
        #expect(landed?.clipped == false && landed?.clips == nil, "the history landed whole, so nothing is clipped")
    }

    /// A fetch that failed says the history is unread; the next one that lands whole clears it.
    @Test func aHistoryThatLandsAfterAFailedFetchIsNotClipped() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.historyUnread = true
                t.state.commit()
                continuation.resume()
            }
        }
        let unread = try await t.snapshot()
        #expect(unread.clips == NativeThreadClips(history: true) && unread.clipped)
        await withCheckedContinuation { continuation in
            t.queue.async { t.state.refreshMessages { _ in continuation.resume() } }
        }
        let landed = try await t.snapshot()
        #expect(landed.clipped == false && landed.clips == nil)
        #expect(landed.revision > unread.revision, "clients see the notice go")
    }
}
