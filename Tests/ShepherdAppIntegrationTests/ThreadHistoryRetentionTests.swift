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
    /// lazy stack builds, and keeps built, the last row it is handed: a one-line reply's view state is about 0.6 MB, so every turn
    /// would have stayed in memory for as long as the thread did.
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
        #expect(after - before < more / 4, "\(more) more turns left \(after - before) more rows built (\(before) before)")
        thread.close()
    }

    /// The element the history's stack ends with (`ThreadView.historyColumn`) is not a gap: every row, the last of the history and the
    /// first of the tail included, stands the column's spacing from the one before it.
    @Test func theHistorysEndAddsNoSpaceBeforeTheTail() async throws {
        let rows = ThreadView.eagerRows + 4
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(rows)), size: CGSize(width: 900, height: 12_000))
        try await thread.waitUntilReady()
        ListPerf.settle(thread.window)
        func markers(_ view: NSView) -> [ThreadTailGuard.RowMarker] {
            (view as? ThreadTailGuard.RowMarker).map { [$0] } ?? view.subviews.flatMap(markers)
        }
        let document = try #require(thread.scrollView?.documentView)
        let frames = markers(thread.window.host).map { ($0.rowID, $0.convert($0.bounds, to: document)) }.sorted { $0.1.minY < $1.1.minY }
        #expect(frames.map(\.0) == thread.store.rows.map(\.id), "every row is built, in order")
        let gaps = zip(frames, frames.dropFirst()).map { $1.1.minY - $0.1.maxY }
        #expect(gaps.allSatisfy { abs($0 - AppLayout.turnSpacing) < 0.5 }, "gaps between rows: \(gaps)")
        thread.close()
    }
}
