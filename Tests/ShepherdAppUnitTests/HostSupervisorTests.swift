import Testing
import ShepherdSessions
@testable import ShepherdApp

/// When the app starts its own host again (`HostSupervisor.RestartPolicy`).
@Suite("Host supervisor restarts")
struct HostSupervisorTests {
    typealias Policy = HostSupervisor.RestartPolicy

    @Test func failedStartsBackOffFromHalfASecondAndTheThirdIsShown() {
        var policy = Policy()
        #expect(policy.exited(status: 1, served: false) == .restart(after: .milliseconds(500)))
        #expect(policy.exited(status: nil, served: false) == .restart(after: .seconds(1)))
        #expect(policy.exited(status: 1, served: false) == .fail, "three failed starts in a row are shown, not retried")
        // Try Again: three more starts, the backoff carrying on up to its cap.
        policy.retry()
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(2)))
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(4)))
        #expect(policy.exited(status: 1, served: false) == .fail)
        policy.retry()
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(8)))
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(10)))
        #expect(policy.delay == .seconds(10), "capped at ten seconds")
    }

    @Test func aRunThatServedResetsTheBackoffAndTheFailures() {
        var policy = Policy()
        _ = policy.exited(status: 1, served: false)
        _ = policy.exited(status: 1, served: false)
        // A crash after serving: started again at once, with three fresh tries.
        #expect(policy.exited(status: nil, served: true) == .restart(after: .milliseconds(500)))
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(1)))
        #expect(policy.exited(status: 1, served: false) == .restart(after: .seconds(2)))
        #expect(policy.exited(status: 1, served: false) == .fail)
    }

    @Test func anOwnedExitFollowsTheOwnerInsteadOfRestarting() {
        var policy = Policy()
        _ = policy.exited(status: 1, served: false)
        _ = policy.exited(status: 1, served: false)
        #expect(policy.exited(status: SessionHost.ownedExitStatus, served: false) == .followOwner)
        #expect(policy == Policy(), "following an owner is no failure: the next start begins afresh")
        #expect(SessionHost.ownedExitStatus != 1, "no ordinary failure reads as owned")
    }
}
