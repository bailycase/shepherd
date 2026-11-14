import AppKit
import SwiftUI
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What a thread's view holds on to once it is gone. The lazy history stack is kept as the view it was (`ThreadHistoryCache`) and that view
/// holds the thread that drew it; the scroll monitor AppKit keeps is held by the view's state. Neither may keep the store or the tail guard.
@Suite("Thread history retention", .mainActorExclusive)
@MainActor
struct ThreadHistoryRetentionTests {
    /// How the thread's view goes away.
    enum Teardown: CaseIterable {
        /// Its window is closed and everything that held it is released, while the view is still in the window's tree.
        case windowReleased
        /// The view is taken out of the window's tree, which tells it (`onDisappear`), and then the window is released.
        case viewRemoved
        /// It was hidden with some of its rows let go, so its stack of history is the dormant one, and then the window is released.
        case dormant
    }

    private struct Watched {
        weak var store: NativeThreadStore?
        weak var tailGuard: ThreadTailGuard?
        var released: Bool { store == nil && tailGuard == nil }
    }

    /// A thread of more rows than the eager tail, so it draws a lazy history stack, loaded and settled.
    private func mount() async throws -> (FakeThread, Watched) {
        let store = NativeThreadStore()
        let tailGuard = ThreadTailGuard()
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(ThreadView.eagerRows * 3)), store: store, tailGuard: tailGuard)
        try await thread.waitUntilReady()
        #expect(store.rows.count > ThreadView.eagerRows)
        return (thread, Watched(store: store, tailGuard: tailGuard))
    }

    /// Mounts a thread, takes it down as `teardown` says, and lets go of everything the test held.
    private func mountAndTearDown(_ teardown: Teardown) async throws -> Watched {
        let (thread, watched) = try await mount()
        switch teardown {
        case .windowReleased:
            break
        case .viewRemoved:
            thread.window.show(EmptyView())
            ListPerf.settle(thread.window)
        case .dormant:
            try await thread.show(false)
            thread.store.releaseTranscript(bytes: 1)
            ListPerf.settle(thread.window)
        }
        thread.close()
        return watched
    }

    @Test(arguments: Teardown.allCases)
    func aThreadWithHistoryReleasesItsStoreAndTailGuardWhenItsViewIsGone(teardown: Teardown) async throws {
        let watched = try await mountAndTearDown(teardown)
        try await eventuallyOnMain("the store and the tail guard to be released") { watched.released }
    }
}
