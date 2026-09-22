import Foundation
import Testing
@testable import TerminalSurfaceKit

/// The tracker is the authority on which SwiftUI view generation owns a pane's surface.
/// Getting it wrong either drops output (a live surface treated as detached) or replays a
/// stale snapshot into a newer surface.
@Suite("Surface attachment tracker")
struct SurfaceAttachmentTrackerTests {
    @Test func theFirstViewBecomesReadyWithoutAReplay() {
        var tracker = SurfaceAttachmentTracker()
        tracker.appeared(UUID())

        let action = tracker.becameReady()

        #expect(action == .ready)
        #expect(tracker.isReady)
    }

    @Test func aSnapshotOwningHostRequiresAReplayEvenForTheFirstView() throws {
        var tracker = SurfaceAttachmentTracker()
        tracker.appeared(UUID(), requiresReplay: true)

        let generation = try #require(tracker.becameReady().replacementGeneration)
        #expect(!tracker.isReady)

        let finished = tracker.finishReplacement(generation: generation)
        #expect(finished)
        #expect(tracker.isReady)
    }

    @Test func readinessWithoutAnAttachedViewIsDetached() {
        var tracker = SurfaceAttachmentTracker()
        let unattached = tracker.becameReady()
        #expect(unattached == .detached)

        tracker.appeared(UUID())
        let otherView = tracker.becameReady(UUID())
        #expect(otherView == .detached, "a readiness report for another view is ignored")
        #expect(!tracker.isReady)
    }

    @Test func aReplacementViewWaitsForItsReplay() throws {
        var tracker = SurfaceAttachmentTracker()
        tracker.appeared(UUID())
        _ = tracker.becameReady()

        tracker.appeared(UUID())
        let generation = try #require(tracker.becameReady().replacementGeneration)
        let again = tracker.becameReady()
        #expect(again == .waitingForReplay)
        #expect(!tracker.isReady)

        let finished = tracker.finishReplacement(generation: generation)
        #expect(finished)
        #expect(tracker.isReady)
    }

    /// SwiftUI may dismantle the old representable after the replacement has already
    /// attached and requested its replay.
    @Test func aLateDetachFromTheOldViewDoesNotInvalidateTheReplacement() throws {
        var tracker = SurfaceAttachmentTracker()
        let oldView = UUID()
        let newView = UUID()
        tracker.appeared(oldView)
        _ = tracker.becameReady()
        tracker.appeared(newView)
        let generation = try #require(tracker.becameReady().replacementGeneration)

        tracker.disappeared(oldView)

        #expect(tracker.isActive(newView))
        let finished = tracker.finishReplacement(generation: generation)
        #expect(finished)
        #expect(tracker.isReady)
    }

    @Test func aStaleReplayCannotFinishANewerSurface() throws {
        var tracker = SurfaceAttachmentTracker()
        tracker.appeared(UUID())
        _ = tracker.becameReady()

        let second = UUID()
        tracker.appeared(second)
        let secondGeneration = try #require(tracker.becameReady().replacementGeneration)
        tracker.disappeared(second)
        tracker.appeared(UUID())
        let thirdGeneration = try #require(tracker.becameReady().replacementGeneration)

        let staleFinished = tracker.finishReplacement(generation: secondGeneration)
        #expect(!staleFinished)
        #expect(!tracker.isReady)

        let currentFinished = tracker.finishReplacement(generation: thirdGeneration)
        #expect(currentFinished)
        #expect(tracker.isReady)
    }

    @Test func detachingTheActiveViewDropsReadiness() {
        var tracker = SurfaceAttachmentTracker()
        let view = UUID()
        tracker.appeared(view)
        _ = tracker.becameReady()

        tracker.disappeared(view)

        #expect(!tracker.isReady)
        #expect(!tracker.isActive(view))
        let afterDetach = tracker.becameReady()
        #expect(afterDetach == .detached)
    }

    @Test func reappearingWithTheSameViewKeepsItReady() {
        var tracker = SurfaceAttachmentTracker()
        let view = UUID()
        tracker.appeared(view)
        _ = tracker.becameReady()

        tracker.appeared(view)

        #expect(tracker.isReady)
    }
}

private extension SurfaceAttachmentTracker.ReadinessAction {
    var replacementGeneration: UInt64? {
        guard case .replacement(let generation) = self else { return nil }
        return generation
    }
}
