import Dispatch
import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// The background host's watchdog (#554 H4): a hung server queue used to go unnoticed while every
/// request to it timed out; now the host hears of it and exits, for launchd to start a fresh one.
@Suite("The host's watchdog")
struct HostWatchdogTests {
    @Test func aHungServerQueueIsReportedOnceAndAnAnsweringOneNever() async throws {
        let host = try ScratchServer()
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            host.stop()
        }
        let hung = Locked<[String]>([])
        let healthy = DispatchQueue(label: "test.healthy")
        let watchdog = HostWatchdog([("server", host.server.queue), ("healthy", healthy)],
                                    interval: .milliseconds(20), limit: .milliseconds(200)) { name in
            hung.withValue { $0.append(name) }
        }
        try await eventually("the watchdog to probe both queues") { watchdog.probesAnswered >= 4 }
        #expect(hung.current.isEmpty, "answering queues are left alone")

        host.server.queue.async { release.wait() }
        try await eventually("the hung server queue to be reported") { !hung.current.isEmpty }
        #expect(hung.current == ["server"])
    }
}
