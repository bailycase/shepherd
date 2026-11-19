import Testing
@testable import ShepherdRemote

/// The overlay a client shows for a rename the person submitted: the latest intent wins, a refusal
/// restores the host's name, and a snapshot older than the host's answer never undoes it.
@Suite("Pending agent renames")
struct PendingAgentRenamesTests {
    private func started(_ renames: inout PendingAgentRenames<String>, _ name: String, host: String = "old") -> String? {
        renames.submit("t", name: name, hostName: host) ? renames.beginSend("t") : nil
    }

    @Test func submitShowsAtOnceAndSendsOnce() {
        var renames = PendingAgentRenames<String>()
        #expect(renames.presented("t", hostName: "old") == "old")
        #expect(started(&renames, "new") == "new")
        #expect(renames.presented("t", hostName: "old") == "new")
        // A second submit while one is in flight is held for after it.
        #expect(renames.submit("t", name: "newer", hostName: "old") == false)
        #expect(renames.presented("t", hostName: "old") == "newer")
    }

    @Test func theLatestIntentIsSentWhenTheRequestInFlightEnds() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "a")
        renames.submit("t", name: "b", hostName: "old")
        renames.submit("t", name: "c", hostName: "old")
        // The first request failing does not revert the newer intent.
        #expect(renames.completed("t", sent: "a", failed: true) == .resend("c"))
        #expect(renames.presented("t", hostName: "old") == "c")
        #expect(renames.completed("t", sent: "c", failed: false) == .settled)
    }

    @Test func aRefusedLatestRenameRestoresTheHostName() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "new")
        #expect(renames.completed("t", sent: "new", failed: true) == .reverted)
        #expect(renames.presented("t", hostName: "old") == "old")
        #expect(renames.isEmpty)
    }

    @Test func anAcceptedRenameHoldsOffSnapshotsThatPredateIt() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "new")
        // Before the host answers, any snapshot leaves the overlay alone.
        renames.observe("t", hostName: "old")
        #expect(renames.presented("t", hostName: "old") == "new")
        #expect(renames.completed("t", sent: "new", failed: false) == .settled)
        // The answer arrived before the snapshot with the name: the old one is still older.
        renames.observe("t", hostName: "old")
        #expect(renames.presented("t", hostName: "old") == "new")
        renames.observe("t", hostName: "new")
        #expect(renames.isEmpty)
    }

    @Test func aRenameBackAndForthIsNotUndoneByTheIntermediateName() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "B")
        renames.submit("t", name: "old", hostName: "old")
        #expect(renames.completed("t", sent: "B", failed: false) == .resend("old"))
        #expect(renames.completed("t", sent: "old", failed: false) == .settled)
        renames.observe("t", hostName: "B")
        #expect(renames.presented("t", hostName: "B") == "old", "B is older than the host's answer")
        renames.observe("t", hostName: "old")
        #expect(renames.isEmpty)
    }

    @Test func aNameNobodyHereChoseEndsTheOverlayOnceSettled() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "mine")
        _ = renames.completed("t", sent: "mine", failed: false)
        renames.observe("t", hostName: "someone else's")
        #expect(renames.isEmpty)
    }

    @Test func aGoneThreadAndPruneDropTheOverlay() {
        var renames = PendingAgentRenames<String>()
        _ = started(&renames, "mine")
        renames.observe("t", hostName: nil)
        #expect(renames.isEmpty)
        _ = started(&renames, "mine")
        renames.prune { _ in false }
        #expect(renames.isEmpty)
        #expect(renames.completed("t", sent: "mine", failed: true) == .ignored)
    }
}
