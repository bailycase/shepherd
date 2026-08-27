import Foundation
import Testing
@testable import TerminalSurfaceKit

@Suite("Terminal surface attachment lifecycle")
struct SurfaceAttachmentTrackerTests {
    @Test @MainActor func appearanceUpdatesInPlace() {
        let model = TerminalSurfaceModel(
            appearance: TerminalAppearance(
                background: "111215",
                foreground: "CDD0D7",
                cursorColor: "CDD0D7"
            )
        )
        let viewState = model.viewState

        let changed = model.updateAppearance(
            TerminalAppearance(
                background: "F3F1ED",
                foreground: "2E3032",
                cursorColor: "8F4E37"
            )
        )

        #expect(changed)
        #expect(model.viewState === viewState)
        #expect(viewState.renderedConfig.contains("background = F3F1ED"))
        #expect(viewState.renderedConfig.contains("foreground = 2E3032"))
        #expect(viewState.renderedConfig.contains("cursor-color = 8F4E37"))
    }

    @Test func firstViewBecomesReadyWithoutReplacement() {
        var tracker = SurfaceAttachmentTracker()
        let view = UUID()

        tracker.appeared(view)

        #expect(tracker.becameReady() == .ready)
        #expect(tracker.isReady)
    }

    @Test func lateDetachFromOldViewDoesNotInvalidateReplacement() throws {
        var tracker = SurfaceAttachmentTracker()
        let oldView = UUID()
        let newView = UUID()

        tracker.appeared(oldView)
        #expect(tracker.becameReady() == .ready)
        tracker.appeared(newView)
        let action = tracker.becameReady()
        let generation = try #require(action.replacementGeneration)

        // SwiftUI may dismantle the old representable after the replacement
        // has already attached and requested its replay.
        tracker.disappeared(oldView)

        let finished = tracker.finishReplacement(generation: generation)
        #expect(finished)
        #expect(tracker.isReady)
    }

    @Test func staleReplayCannotFinishANewerSurface() throws {
        var tracker = SurfaceAttachmentTracker()
        let firstView = UUID()
        let secondView = UUID()
        let thirdView = UUID()

        tracker.appeared(firstView)
        #expect(tracker.becameReady() == .ready)

        tracker.appeared(secondView)
        let secondGeneration = try #require(tracker.becameReady().replacementGeneration)
        tracker.disappeared(secondView)

        tracker.appeared(thirdView)
        let thirdGeneration = try #require(tracker.becameReady().replacementGeneration)

        let staleFinished = tracker.finishReplacement(generation: secondGeneration)
        #expect(!staleFinished)
        #expect(!tracker.isReady)
        let currentFinished = tracker.finishReplacement(generation: thirdGeneration)
        #expect(currentFinished)
        #expect(tracker.isReady)
    }
}

private extension SurfaceAttachmentTracker.ReadinessAction {
    var replacementGeneration: UInt64? {
        guard case .replacement(let generation) = self else { return nil }
        return generation
    }
}
