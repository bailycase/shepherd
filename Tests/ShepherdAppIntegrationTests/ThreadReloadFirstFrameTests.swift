import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

/// A thread that fell out of the history bounds (`NativeThreadStores`) and comes back draws its tail in its first frame, from what
/// it kept: no pull has returned, nothing is parsed, and the pull that lands after it neither moves the reader nor builds a row again.
@Suite("Thread reload first frame", .mainActorExclusive)
@MainActor
struct ThreadReloadFirstFrameTests {
    private static let session = ThreadFixture.history(240)

    /// A thread on screen that holds more than the newest page (it paged older history in).
    private func openPaged() async throws -> FakeThread {
        let thread = FakeThread(ThreadFixture.snapshot([]), history: Self.session, deckHosting: true)
        try await thread.waitUntilReady()
        await thread.store.loadOlder()
        await thread.store.loadOlder()
        ListPerf.settle(thread.window)
        #expect(thread.store.messages.count > 2 * FakeThread.pageSize, "it holds older pages: \(thread.store.messages.count) messages")
        return thread
    }

    /// The thread is hidden, and the stores around it have shown another thread since, past `retainedHistories`, so the bounds take
    /// what they take of it.
    @discardableResult
    private func leaveTheDeck(_ thread: FakeThread) async throws -> NativeThreadStores<String> {
        let stores = NativeThreadStores<String>()
        stores.retainedHistories = 0
        stores.install(thread.store, for: "away")
        let other = stores.store(for: "other")
        other.preview(ThreadFixture.snapshot(ThreadFixture.history(4)))
        stores.noteShown("away")
        try await thread.show(false)
        stores.noteShown("other")
        stores.enforceHistoryBounds()
        return stores
    }

    private func distanceFromTail(_ thread: FakeThread) throws -> CGFloat {
        let scroll = try #require(thread.scrollView)
        let document = try #require(scroll.documentView)
        let clip = scroll.contentView
        return document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom)
    }

    @Test func aThreadPastTheBoundsDrawsItsTailBeforeItsPullReturns() async throws {
        let thread = try await openPaged()
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        let tail = Array(Self.session.suffix(10))
        #expect(store.messages.suffix(10) == tail, "the end of the thread is what it kept")
        #expect(!store.rows.isEmpty && store.holdsHistory)

        // The thread comes back with its pull on its way.
        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        ListPerf.settle(thread.window)
        let first = ThreadRowMemory.built(in: store)
        #expect(first >= ThreadView.eagerRows, "its first frame drew its tail: \(first) rows built")
        #expect(try abs(distanceFromTail(thread)) < 2, "at the end of the thread")
    }

    @Test func aPullThatLandsAfterTheFirstFrameMovesNothingAndBuildsNoRowAgain() async throws {
        let thread = try await openPaged()
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        ListPerf.settle(thread.window)
        let ids = store.rows.suffix(ThreadView.eagerRows).map(\.id)
        #expect(ids.count == ThreadView.eagerRows && ThreadRowMemory.built(in: store) >= ids.count, "the first frame drew its tail")
        var built = [ThreadRowMemory.built(in: store)]
        var distances = [try distanceFromTail(thread)]

        thread.releaseSnapshots()
        try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        for _ in 0..<10 {
            ListPerf.settle(thread.window)
            built.append(ThreadRowMemory.built(in: store))
            distances.append(try distanceFromTail(thread))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.rows.suffix(ids.count).map(\.id) == ids, "the rows it drew are the rows it has, with the same identities")
        #expect(built == built.sorted(), "no row was built again, none went: \(built)")
        #expect(distances.allSatisfy { abs($0) < 2 }, "the reader stayed at the end of the thread: \(distances)")
    }
    /// A thread of heavy rows, whose eager tail is a few of them with more above: its first frame draws that tail alone, from what it kept,
    /// and the lazy stack of the older rows waits for the pull that catches it up. Neither moves the end of the thread.
    @Test func aHeavyThreadDrawsItsEagerTailAloneAndItsStackAfterThePull() async throws {
        let messages = ThreadEagerTailTests.messages(turns: 40, cycles: ThreadEagerTailTests.cycles)
        let thread = FakeThread(ThreadFixture.snapshot(messages), deckHosting: true)
        try await thread.waitUntilReady()
        await thread.store.waitForProse()
        ListPerf.settle(thread.window)
        let tail = try #require(thread.store.drawnEagerRows)
        #expect(tail < ThreadView.eagerRows / 2, "its tail is bound by cost: \(tail) rows")
        defer { thread.close() }
        try await leaveTheDeck(thread)
        let store = thread.store
        #expect(store.keepsOnlyTail && store.rows.count > tail)

        let requests = thread.snapshotRequests
        thread.holdingSnapshots = true
        thread.visibility.active = true
        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)
        defer { thread.releaseSnapshots() }
        try await eventuallyOnMain("the pull to be on its way") { thread.snapshotRequests > requests }
        ListPerf.settle(thread.window)
        let first = ThreadRowMemory.built(in: store)
        #expect(first > 0 && first <= tail, "the first frame drew the eager tail alone: \(first) rows of \(tail), \(store.rows.count) in the thread")
        #expect(try abs(distanceFromTail(thread)) < 2)

        thread.releaseSnapshots()
        try await eventuallyOnMain("the pull to land") { store.catchUp != nil }
        var distances: [CGFloat] = []
        for _ in 0..<20 {
            ListPerf.settle(thread.window)
            distances.append(try distanceFromTail(thread))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ThreadRowMemory.built(in: store) >= first)
        #expect(distances.allSatisfy { abs($0) < 2 }, "the end of the thread stayed where it was: \(distances)")
    }
}
