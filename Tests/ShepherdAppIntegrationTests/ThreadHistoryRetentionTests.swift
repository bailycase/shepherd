import AppKit
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

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

    private func makeGuard() -> ThreadTailGuard {
        let guardrail = ThreadTailGuard()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHEPHERD_TEST_MEASURED_HISTORY"] == "1" {
            guardrail.measuredHistoryForTests = ThreadMeasuredHistory()
        }
        #endif
        return guardrail
    }

    #if DEBUG
    @Test(arguments: [false, true])
    func measuredHistoryLetsGoWhenParkedOrReleased(park: Bool) async throws {
        let guardrail = ThreadTailGuard()
        let history = ThreadMeasuredHistory()
        guardrail.measuredHistoryForTests = history
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(ThreadView.eagerRows * 3)), tailGuard: guardrail)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the measured history to retain rows") { history.retainedRowCount > 0 }
        if park {
            thread.visibility.liveResizing = true
        } else {
            try await thread.show(false)
            thread.store.releaseTranscript(keepingLastScreen: true)
            #expect(thread.store.transcriptReleased)
        }
        try await eventuallyOnMain("the measured history to release its rows") { history.retainedRowCount == 0 }
    }
    #endif

    private struct Watched {
        weak var store: NativeThreadStore?
        weak var tailGuard: ThreadTailGuard?
        var released: Bool { store == nil && tailGuard == nil }
    }

    /// A thread of more rows than the eager tail, so it draws a lazy history stack, loaded and settled.
    private func mount() async throws -> (FakeThread, Watched) {
        let store = NativeThreadStore()
        let tailGuard = makeGuard()
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

    /// Turns that are added one at a time to a thread on screen. The rows are counted for this thread's store only: other suites draw
    /// threads in the same process while this one runs. Each one's rows join the lazy history as the eager tail moves on, and a
    /// lazy stack builds, and keeps built, the last row it is handed: a one-line reply's view state is some 0.6 MB, so every turn would
    /// stay in memory for as long as the thread did. A reader at the tail has no use for them: the stack starts again
    /// (`ThreadHistoryBuilt`), and the rows it has built stay within a few turns' worth.
    @Test func aThreadThatGrowsTurnByTurnKeepsOnlyItsTailBuilt() async throws {
        let guardrail = makeGuard()
        let thread = FakeThread(ThreadFixture.snapshot([]), tailGuard: guardrail)
        try await thread.waitUntilReady()
        var messages: [NativeThreadMessage] = []
        var revision: UInt64 = 1
        var ends: [CGFloat] = []
        func addTurns(_ range: Range<Int>) async throws {
            for i in range {
                messages += [ThreadFixture.user("u\(i)", "Say hi \(i)"), ThreadFixture.assistant("a\(i)", "Hi there, number \(i).")]
                revision += 1
                await thread.serve(ThreadFixture.snapshot(messages, revision: revision))
                ListPerf.settle(thread.window)
                // The tail's landing follows the lazy stack's estimate of the history above it, which swings by hundreds of points as the
                // stack starts again, and the view can land a few points to 20 short of its end in the frame it lands in (with the
                // old row heights too: it is the row heights that decide which turns). The tail guard puts it back once things are quiet,
                // so the end is read where the thread rests.
                try await eventuallyOnMain("the thread to rest on its tail") {
                    ListPerf.settle(thread.window)
                    return guardrail.rests(quietFor: ThreadTailGuard.quiet)
                }
                if let scroll = thread.scrollView, let document = scroll.documentView { ends.append(document.bounds.height - scroll.contentView.bounds.maxY) }
            }
        }
        let warm = ThreadView.eagerRows
        let more = 60
        try await addTurns(0..<warm)
        let before = ThreadRowMemory.built(in: thread.store)
        try await addTurns(warm..<(warm + more))
        let after = ThreadRowMemory.built(in: thread.store)
        #expect(thread.store.rows.count == 2 * (warm + more), "every turn is a row of the thread")
        #expect(before > 0, "the thread's rows are counted")
        // Without the restarts every one of the turns' replies stays built: `more` of them.
        #expect(after - before <= ThreadHistoryBuilt.rows, "\(more) more turns left \(after - before) more rows built (\(before) before)")
        // The restarts happen behind the reader: the end of the thread stays where it was through every turn, to within the
        // follower's own tolerance of resting on its tail (`repinSlack`): the guard does not move a thread that close to it. A
        // restart that moved the end would move it by the rows it dropped, hundreds of points.
        let steady = ends.suffix(more)
        #expect(steady.count == more && (steady.max() ?? 0) - (steady.min() ?? 0) <= NativeScrollFollower.repinSlack, "the thread's end moved: \(Array(steady))")
        thread.close()
    }

    /// The same thread when its rows are heavy: the eager tail is bound by what its rows cost and holds fewer than `eagerRows` at rest
    /// (`NativeThreadStore.eagerTailRows`), and its start follows the rule turn by turn (`ThreadEagerTail`). The stack starts again after
    /// the rows the thread adds all the same, and not before: what the tail's size is, or that it is not the eager rows, is not what counts.
    @Test func aHeavyThreadThatGrowsTurnByTurnStartsItsHistoryStackAgainToo() async throws {
        let cycles = ThreadEagerTailTests.cycles
        let first = 40
        var turns = first
        let thread = FakeThread(ThreadFixture.snapshot(ThreadEagerTailTests.messages(turns: turns, cycles: cycles)),
                                deckHosting: true, tailGuard: makeGuard())
        defer { thread.close() }
        try await thread.waitUntilReady()
        await thread.store.waitForProse()
        ListPerf.settle(thread.window)
        let tail = try #require(thread.store.drawnEagerRows)
        #expect(tail < ThreadView.eagerRows / 2, "its tail is bound by cost: \(tail) rows")
        let stack = ThreadHistoryBuilt.drawn(in: thread.store)
        var revision: UInt64 = 1
        // A turn is two rows: a few turns more than `rows` of them are given.
        let most = ThreadHistoryBuilt.rows / 2 + 4
        while turns < first + most, ThreadHistoryBuilt.drawn(in: thread.store) == stack {
            turns += 1
            revision += 1
            await thread.serve(ThreadFixture.snapshot(ThreadEagerTailTests.messages(turns: turns, cycles: cycles), revision: revision))
            await thread.store.waitForProse()
            ListPerf.settle(thread.window)
        }
        let added = 2 * (turns - first)
        #expect(thread.store.rows.count == 2 * turns)
        #expect(ThreadHistoryBuilt.drawn(in: thread.store) > stack, "\(added) rows did not start the stack again")
        // The tail's own moves are no turn's: the rows it gave the history while the thread opened and settled do not add up to the stack's
        // start before the thread has added its own.
        #expect(added >= ThreadHistoryBuilt.rows - 2, "the stack started again after \(added) rows")
    }

    /// A reader who has scrolled up through the history keeps the rows they passed: the stack does not start again under them while
    /// the thread grows.
    @Test func aReaderAwayFromTheTailKeepsTheHistoryTheyHaveBuilt() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]), tailGuard: makeGuard())
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
        let before = ThreadRowMemory.built(in: thread.store)
        let stack = ThreadHistoryBuilt.drawn(in: thread.store)
        await addTurns(ThreadView.eagerRows..<(ThreadView.eagerRows + 3 * ThreadHistoryBuilt.rows))
        let after = ThreadRowMemory.built(in: thread.store)
        #expect(ThreadHistoryBuilt.drawn(in: thread.store) == stack, "the stack the reader reads in does not start again")
        #expect(after >= before, "the rows the reader has built stay: \(before) before, \(after) after")
        #expect(abs(clip.bounds.origin.y - away) < 1, "and the reader's place does not move: \(clip.bounds.origin.y) from \(away)")
        thread.close()
    }

    /// A live window resize moves rows from the eager tail into the history in one update: the tail drops to the rows that cover the
    /// window (`ThreadView.eagerCount`), and with it as many rows as the history takes before its stack would start again. They are no
    /// turn's, so the stack does not start again in the drag's first frame, nor while the tail grows back after it.
    @Test func aLiveResizeAtTheTailDoesNotStartTheHistoryStackAgain() async throws {
        func builtRows(in view: NSView) -> Int {
            (view is ThreadTailGuard.RowMarker ? 1 : 0) + view.subviews.reduce(0) { $0 + builtRows(in: $1) }
        }
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(ThreadView.eagerRows * 3)), tailGuard: makeGuard())
        try await thread.waitUntilReady()
        let scroll = try #require(thread.scrollView)
        let tail = thread.store.eagerRowCount(coveringHeight: AppLayout.eagerCoverHeight(forViewport: scroll.bounds.height), maxRows: ThreadView.eagerRows)
        #expect(ThreadView.eagerRows - tail >= ThreadHistoryBuilt.rows, "the drag moves rows enough to start the stack again: \(tail) of \(ThreadView.eagerRows) stay in the tail")
        let full = builtRows(in: thread.window.host)
        let stack = ThreadHistoryBuilt.drawn(in: thread.store)
        thread.visibility.liveResizing = true
        ListPerf.settle(thread.window)
        #expect(builtRows(in: thread.window.host) < full - 8, "the drag lays out fewer rows: \(builtRows(in: thread.window.host)) of \(full)")
        #expect(ThreadHistoryBuilt.drawn(in: thread.store) == stack, "the drag's first frame started the stack again")
        thread.visibility.liveResizing = false
        try await eventuallyOnMain("the tail back at its size") { builtRows(in: thread.window.host) >= ThreadView.eagerRows }
        #expect(ThreadHistoryBuilt.drawn(in: thread.store) == stack, "the stack started again once the tail was back")
        thread.close()
    }
}
