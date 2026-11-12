import Observation
import ShepherdCore
import ShepherdTestKit
import Testing
@testable import ShepherdApp

/// An agent's own box of what a turn changes: a view that reads it reruns for that agent's change, and a report that
/// repeats what it holds changes nothing.
@Suite("Agent live")
@MainActor
struct AgentLiveTests {
    /// Whether `read` is told of a change by the time `change` has run.
    private func notified(reading read: () -> Void, after change: () -> Void) -> Bool {
        let told = Locked(false)
        withObservationTracking(read) { told.withValue { $0 = true } }
        change()
        return told.current
    }

    @Test func reportReturnsTheStatusItHeld() {
        let live = AgentLive(status: .idle)
        #expect(live.report(.working) == .idle)
        #expect(live.report(.done) == .working)
        #expect(live.status == .done)
    }

    @Test func anEqualReportFiresNoChange() {
        let live = AgentLive(status: .working)
        #expect(!notified(reading: { _ = live.status }, after: { live.report(.working) }))
        #expect(live.status == .working)
    }

    @Test func aChangedReportFiresOnce() {
        let live = AgentLive(status: .working)
        #expect(notified(reading: { _ = live.status }, after: { live.report(.done) }))
        #expect(live.status == .done)
    }

    @Test func aSampleRedrawsWhatReadsSamplesAndNotWhatReadsStatus() {
        let live = AgentLive(status: .working)
        #expect(!notified(reading: { _ = live.status }, after: { live.samples = [1, 2] }))
        #expect(notified(reading: { _ = live.samples }, after: { live.samples = [1, 2, 3] }))
        #expect(!notified(reading: { _ = live.samples }, after: { live.report(.done) }))
    }
}
