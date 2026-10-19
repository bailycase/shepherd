import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Late bootstrap history still has to land whole before the thread can serve.
@Suite("Thread history after a slow start", .integrationTimeLimit)
struct SlowStartHistoryTests {
    @Test func aPiSlowerThanTheDeadlineIsNotServedWithoutItsHistory() async throws {
        let t = try ThreadEventTests.Thread(bootstrap: false, env: ["STUB_PI_STARTUP_GATE": "release-pi", "STUB_PI_HISTORY_BYTES": "1048576"])
        defer { t.stop() }
        let decoding = Locked(false)
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }
        t.session.beforeOffQueueDecode = {
            decoding.withValue { $0 = true }
            hold.wait()
        }
        t.queue.async { t.state.bootstrap(timeout: 0.2) }
        try await eventually("the readiness deadline to expire") {
            await t.request(.snapshot()).failureCode == NativeThreadCode.unavailable
        }
        FileManager.default.createFile(atPath: t.dir.appendingPathComponent("release-pi").path, contents: nil)
        try await eventually("pi to answer state and start decoding its late history") {
            let hasState = await withCheckedContinuation { continuation in
                t.queue.async { continuation.resume(returning: t.state.piSessionID != nil) }
            }
            return hasState && decoding.current
        }

        #expect(await t.request(.snapshot()).failureCode == NativeThreadCode.unavailable, "not served empty while history is decoding")
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
