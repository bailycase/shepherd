import AppKit
import SwiftUI
import ShepherdProtocol
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

    /// Turns that are added one at a time to a thread on screen. Each one's rows join the lazy history as the eager tail moves on, and a
    /// lazy stack builds, and keeps built, the last row it is handed: a one-line reply's view state is some 0.6 MB, so every turn would
    /// stay in memory for as long as the thread did. A reader at the tail has no use for them: the stack starts again
    /// (`ThreadHistoryBuilt`), and the rows it has built stay within a few turns' worth.
    @Test func aThreadThatGrowsTurnByTurnKeepsOnlyItsTailBuilt() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]))
        try await thread.waitUntilReady()
        var messages: [NativeThreadMessage] = []
        var revision: UInt64 = 1
        func addTurns(_ range: Range<Int>) async {
            for i in range {
                messages += [ThreadFixture.user("u\(i)", "Say hi \(i)"), ThreadFixture.assistant("a\(i)", "Hi there, number \(i).")]
                revision += 1
                await thread.serve(ThreadFixture.snapshot(messages, revision: revision))
                ListPerf.settle(thread.window)
            }
        }
        let warm = ThreadView.eagerRows
        let more = 60
        await addTurns(0..<warm)
        let before = ThreadRowMemory.built.load(ordering: .relaxed)
        await addTurns(warm..<(warm + more))
        let after = ThreadRowMemory.built.load(ordering: .relaxed)
        #expect(thread.store.rows.count == 2 * (warm + more), "every turn is a row of the thread")
        // Without the restarts every one of the turns' replies stays built: `more` of them.
        #expect(after - before <= ThreadHistoryBuilt.rows, "\(more) more turns left \(after - before) more rows built (\(before) before)")
        thread.close()
    }

    /// A reader who has scrolled up through the history keeps the rows they passed: the stack does not start again under them while
    /// the thread grows.
    @Test func aReaderAwayFromTheTailKeepsTheHistoryTheyHaveBuilt() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]))
        try await thread.waitUntilReady()
        var messages: [NativeThreadMessage] = []
        var revision: UInt64 = 1
        func addTurns(_ range: Range<Int>) async {
            for i in range {
                messages += [ThreadFixture.user("u\(i)", "Say hi \(i)"), ThreadFixture.assistant("a\(i)", "Hi there, number \(i). " + ThreadFixture.answer)]
                revision += 1
                await thread.serve(ThreadFixture.snapshot(messages, revision: revision))
                ListPerf.settle(thread.window)
            }
        }
        await addTurns(0..<ThreadView.eagerRows)
        let scroll = try #require(thread.scrollView)
        let clip = scroll.contentView
        for _ in 0..<8 {
            thread.input.readerScrolled(upward: true)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.bounds.origin.y - 400), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            ListPerf.settle(thread.window)
        }
        let away = clip.bounds.origin.y
        let before = ThreadRowMemory.built.load(ordering: .relaxed)
        await addTurns(ThreadView.eagerRows..<(ThreadView.eagerRows + 3 * ThreadHistoryBuilt.rows))
        let after = ThreadRowMemory.built.load(ordering: .relaxed)
        #expect(after >= before, "the rows the reader has built stay: \(before) before, \(after) after")
        #expect(abs(clip.bounds.origin.y - away) < 1, "and the reader's place does not move: \(clip.bounds.origin.y) from \(away)")
        thread.close()
    }
}
