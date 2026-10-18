import Testing
@testable import ShepherdSessions

@Suite("Resource ownership")
struct ResourceOwnershipTests {
    private func process(_ pid: Int32, parent: Int32, born: UInt64 = 1) -> ResourceOwnership.Process {
        .init(pid: pid, parent: parent, seconds: born, micros: 0)
    }

    @Test func followsDescendantsAcrossReparentingWithoutClaimingUnrelatedProcesses() {
        var tracker = ResourceOwnership()
        let owner = process(10, parent: 1)
        let wrapper = process(11, parent: 10)
        let child = process(12, parent: 11)
        let unrelated = process(30, parent: 1)
        #expect(tracker.update([owner, wrapper, child, unrelated], roots: [10]) == [10: false, 11: false, 12: false])
        #expect(tracker.update([process(11, parent: 1), child, unrelated], roots: []) == [11: true, 12: true])
        // A new process with a reused PID is not an orphan of the previous session.
        #expect(tracker.update([process(11, parent: 1, born: 2), unrelated], roots: []).isEmpty)
    }

    @Test func rootPIDReuseDoesNotAdoptOldSurvivors() {
        var tracker = ResourceOwnership()
        _ = tracker.update([process(10, parent: 1), process(11, parent: 10)], roots: [10])
        let result = tracker.update([process(10, parent: 1, born: 2), process(11, parent: 1)], roots: [10])
        #expect(result == [10: false, 11: true])
    }

    @Test func censusIsOrderIndependentAndOwnershipIsBounded() {
        var tracker = ResourceOwnership()
        let rows = [process(12, parent: 11), process(11, parent: 10), process(10, parent: 1)]
        #expect(tracker.update(rows, roots: [10], limit: 2).count == 2)
        #expect(tracker.truncated)
        #expect(tracker.update([], roots: []).isEmpty)
        #expect(!tracker.truncated)
    }
}
