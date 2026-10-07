import AppKit
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What the tail guard leaves the scroll view as, once it has walked it. A scroll view of the
/// thread's shape (a tall document, the composer's inset) and a guard told what the lazy stack
/// would say, with no window and no SwiftUI: the stack's guesses are the cause of a stranded view,
/// and this is the cure's own bookkeeping.
@Suite("Thread tail guard", .serialized, .mainActorExclusive)
@MainActor
struct ThreadTailGuardTests {
    final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    final class Rig {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = Flipped(frame: NSRect(x: 0, y: 0, width: 800, height: 6000))
        let guardian = ThreadTailGuard()
        private(set) var landings = 0
        private var token: NSObjectProtocol?

        var clip: NSClipView { scroll.contentView }

        init() {
            scroll.documentView = document
            scroll.hasVerticalScroller = false
            scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 134, right: 0)
            clip.postsBoundsChangedNotifications = true
            guardian.scrollView = { [scroll] in scroll }
            guardian.bottomID = "thread-bottom"
            guardian.rowIDs = ["row"]
            guardian.active = true
            guardian.following = true
            guardian.land = { [unowned self] in landings += 1 }
            scrollToEnd()
        }

        /// How far the visible bottom sits above the end of the document.
        var gap: Double {
            Double(document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom))
        }

        func scrollToEnd() {
            clip.scroll(to: NSPoint(x: 0, y: document.bounds.height + scroll.contentInsets.bottom - clip.bounds.height))
            scroll.reflectScrolledClipView(clip)
        }

        /// Runs `change` the first time the offset moves: the rows the move realized, and whatever the
        /// document did around them.
        func onFirstMove(_ change: @escaping @MainActor () -> Void) {
            let start = clip.bounds.origin.y
            var fired = false
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard !fired, abs(self.clip.bounds.origin.y - start) > 1 else { return }
                    fired = true
                    change()
                }
            }
        }

        func close() {
            guardian.stop()
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// A thread drawing nothing is walked back toward its rows, and the walk is the guard's own
    /// scrolling: a view it leaves a little above the end of the document (the marker is in view from
    /// there, under the composer) is taken the rest of the way. Seeing only the clear bottom marker
    /// is still a blank transcript, not a successful repair. A cached target for a live reply that
    /// completion replaced is no better; only a current row can end the repair.
    @Test(arguments: [[], ["thread-bottom"], ["removed-live-reply", "thread-bottom"]])
    func aRepairedThreadRestingUnderTheComposerIsTakenToTheEndOfItsDocument(visible: [String]) async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.onFirstMove {
            // The rows the walk realized put the document's end 100 pt below the view.
            rig.document.setFrameSize(NSSize(width: 800, height: 5500))
            rig.guardian.targets(["row", "thread-bottom"])
        }
        if visible.contains("removed-live-reply") { rig.guardian.rowIDs = ["removed-live-reply"] }
        rig.guardian.targets(visible)
        // History replaces the live reply before another target-visibility callback arrives.
        rig.guardian.rowIDs = ["row"]
        try await eventuallyOnMain("the guard to walk the view and finish", timeout: .seconds(10)) { rig.guardian.visible.contains("row") && !rig.guardian.repairing }
        try await eventuallyOnMain("the view to rest on the end of its document", timeout: .seconds(5)) { rig.gap <= ThreadTailGuard.slack }
        #expect(rig.landings == 0, "the guard aimed at the end the stack believes in, which would undo an exact landing")
    }

    /// SwiftUI can keep reporting the clear marker after the walk has found no current row.
    /// It is not evidence of content, and must not suppress the final tail landing.
    @Test func aBottomMarkerWithoutAnyCurrentRowDoesNotEndRecovery() async throws {
        let rig = Rig()
        defer { rig.close() }
        let land = rig.guardian.land
        rig.guardian.land = {
            land()
            rig.scrollToEnd()
            rig.guardian.targets(["row", "thread-bottom"])
        }
        rig.guardian.targets(["thread-bottom"])
        try await eventuallyOnMain("a marker-only viewport to land on real content", timeout: .seconds(5)) {
            rig.landings > 0 && rig.guardian.visible.contains("row") && !rig.guardian.repairing
        }
        #expect(rig.landings == 1)
        #expect(abs(rig.gap) <= ThreadTailGuard.slack)
    }

    @Test func aNewCompletedTurnCanRecoverAfterEarlierAttemptsFailed() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.guardian.scrollView = { nil }
        rig.guardian.targets([])
        try await eventuallyOnMain("bounded attempts are exhausted", timeout: .seconds(10)) {
            rig.landings == ThreadTailGuard.maxAttempts
        }
        try await Task.sleep(for: .milliseconds(250))
        rig.guardian.scrollView = { rig.scroll }
        rig.onFirstMove { rig.guardian.targets(["completed-reply", "thread-bottom"]) }
        rig.guardian.rowIDs = ["completed-reply"]
        rig.guardian.targets([])
        rig.guardian.turnFinished()
        try await eventuallyOnMain("the completed turn gets its own bounded recovery", timeout: .seconds(3)) {
            rig.guardian.visible.contains("completed-reply") && !rig.guardian.repairing
        }
    }

    @Test func returningToAThreadCompletedWhileHiddenRestartsRecovery() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.guardian.active = false
        rig.guardian.scrollView = { nil }
        rig.guardian.targets([])
        rig.guardian.turnFinished()
        let land = rig.guardian.land
        rig.guardian.land = {
            land()
            rig.guardian.targets(["row", "thread-bottom"])
        }
        rig.guardian.active = true
        try await eventuallyOnMain("visible completion rechecks its missing rows", timeout: .seconds(3)) {
            rig.landings > 0
        }
    }

    @Test(arguments: ["hidden", "reader"])
    func completionOnlyRecoversAVisibleFollowingThread(state: String) async throws {
        let rig = Rig()
        defer { rig.close() }
        if state == "hidden" { rig.guardian.active = false }
        if state == "reader" { rig.guardian.readerMoved() }
        rig.guardian.targets([])
        rig.guardian.turnFinished()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.landings == 0)
        #expect(!rig.guardian.repairing)
    }

    /// Farther above its end than the composer hides, the marker is out of view and the guard's walk is
    /// the cure: the end of the document is not a place to scroll to for a view the stack stranded (the
    /// rows may end well above it).
    @Test func aRepairedThreadFarAboveTheEndOfItsDocumentIsNotSentThere() async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.onFirstMove {
            rig.guardian.targets(["row", "thread-bottom"])
        }
        rig.guardian.targets([])
        try await eventuallyOnMain("the guard to walk the view", timeout: .seconds(10)) { rig.guardian.visible.count == 2 && !rig.guardian.repairing }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.gap > 400, "the view was left where the walk put it, \(Int(rig.gap)) pt above the end")
    }

    /// The follower stands aside while the guard walks. A thread that grew by a line in that time
    /// (the "Thinking…" row) rested that far above its tail for good: the marker was back in view, so
    /// the repair looked done, and nothing asked the follower again.
    @Test func aThreadThatGrewWhileTheGuardWalkedIsFollowedToItsNewEnd() async throws {
        let rig = Rig()
        defer { rig.close() }
        var endedOnTheEnd = false, walking = false
        rig.onFirstMove {
            // The walk realized rows and the document settled shorter; AppKit clamps the view to its end.
            rig.document.setFrameSize(NSSize(width: 800, height: 3400))
            rig.clip.scroll(to: rig.clip.constrainBoundsRect(rig.clip.bounds).origin)
            rig.scroll.reflectScrolledClipView(rig.clip)
            endedOnTheEnd = abs(rig.gap) <= 1
            // The follower is not heard while the guard walks, and the line arrives meanwhile.
            walking = rig.guardian.repairing
            rig.document.setFrameSize(NSSize(width: 800, height: 3438))
            rig.guardian.targets(["row", "thread-bottom"])
        }
        rig.guardian.targets([])
        try await eventuallyOnMain("the guard to finish", timeout: .seconds(10)) { rig.guardian.visible.count == 2 && !rig.guardian.repairing }
        #expect(endedOnTheEnd, "the walk ended on the end of the document")
        #expect(walking, "the line arrived while the guard walked")
        try await eventuallyOnMain("the thread to rest on its new end", timeout: .seconds(5)) { rig.gap <= ThreadTailGuard.slack }
        #expect(rig.landings == 0)
    }

    /// A reader's hands are never fought: the end is not taken for a reader who has just moved.
    @Test(arguments: [["row"], ["row", "thread-bottom"]])
    func aReaderWhoJustMovedIsNotTakenToTheEnd(visible: [String]) async throws {
        let rig = Rig()
        defer { rig.close() }
        rig.onFirstMove {
            rig.document.setFrameSize(NSSize(width: 800, height: 5500))
            rig.guardian.targets(visible)
            rig.guardian.readerMoved()
        }
        rig.guardian.targets([])
        try await eventuallyOnMain("the guard to walk the view", timeout: .seconds(10)) { rig.guardian.visible.contains("row") && !rig.guardian.repairing }
        #expect(rig.landings == 0, "a wheel tick that interrupts recovery must not jump back to the tail")
        #expect(rig.gap > 90, "the view stayed where the reader's last move left it")
    }
}
