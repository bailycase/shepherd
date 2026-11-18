import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// How many rows at the end of a thread its view lays out for real (`NativeThreadStore.eagerTailRows`): the last rows within a cost, at
/// least the rows that cover the window, and the rows a stream needs.
@Suite("Eager tail rule", .timeLimit(.minutes(1)))
@MainActor
struct NativeEagerTailTests {
    typealias Cost = NativeMountedCost
    typealias F = Fixture

    /// `replies` question and answer pairs; the answer of pair `i` is `cycles(i)` cycles of fences and tables (0: one short line).
    private func messages(_ replies: Int, cycles: (Int) -> Int) -> [NativeThreadMessage] {
        (0..<replies).flatMap { i -> [NativeThreadMessage] in
            let text = cycles(i) == 0 ? "Done." : NativeMountedCostTests.bigReply(cycles: cycles(i))
            return [F.user("question \(i)", id: "u\(i)"), F.assistant(text, id: "a\(i)")]
        }
    }

    private func store(_ replies: Int, cycles: (Int) -> Int) async -> NativeThreadStore {
        let store = NativeThreadStore()
        store.preview(F.snapshot(messages: messages(replies, cycles: cycles)))
        await store.waitForProse()
        return store
    }

    private func costs(_ store: NativeThreadStore) -> [Int] { store.rows.map { Cost.row($0) } }

    /// The rule, read off the rows' costs: the last row, then each one before while the sum stays within `cap`.
    private func within(_ cap: Int, _ costs: [Int], max: Int = 30) -> Int {
        var sum = 0, taken = 0
        for cost in costs.reversed() where taken < max {
            if taken > 0, sum + cost > cap { break }
            sum += cost
            taken += 1
        }
        return taken
    }

    @Test func rowsThatCostLittleAreAllTheRowsAThreadMayLayOut() async {
        let store = await store(40, cycles: { _ in 0 })
        #expect(store.rows.count == 80)
        #expect(store.eagerTailRows(maxRows: 30, costCap: Cost.eagerTailCap, coveringHeight: 2_000) == 30)
        #expect(store.eagerTailRows(maxRows: 12, costCap: Cost.eagerTailCap, coveringHeight: 2_000) == 12, "never past the rows allowed")
    }

    @Test func heavyRowsStopWhereTheirCostReachesTheCap() async {
        let store = await store(20, cycles: { _ in 8 })
        let costs = costs(store)
        let reply = costs[1]
        #expect(reply > 8 * Cost.rowBase, "a reply of fences and tables is the cost")
        for cap in [3 * reply, 5 * reply + reply / 2, 9 * reply] {
            let expected = within(cap, costs)
            #expect(expected > 1 && expected < 30)
            #expect(store.eagerTailRows(maxRows: 30, costCap: cap, coveringHeight: 1) == expected, "cap \(cap >> 20) MiB")
        }
    }

    @Test func theDefaultCapHoldsAFewHeavyRepliesNotThirtyRows() async {
        let store = await store(40, cycles: { _ in 20 })
        let rows = store.eagerTailRows(maxRows: 30, costCap: Cost.eagerTailCap, coveringHeight: 1)
        let held = store.mountedCost(eagerRows: rows)
        #expect(rows >= 2 && rows < 30)
        #expect(held <= Cost.eagerTailCap, "the rows it counts hold the cap or less: \(held >> 20) MiB")
        #expect(store.mountedCost(eagerRows: 30) > 2 * Cost.eagerTailCap, "the thirty it used to count are far over it")
    }

    @Test func theLastRowIsLaidOutWhateverItCosts() async {
        let store = await store(6, cycles: { _ in 8 })
        #expect(store.eagerTailRows(maxRows: 30, costCap: 1, coveringHeight: 1) == 1)
        #expect(store.eagerTailRows(maxRows: 30, costCap: 1, coveringHeight: 0) == 1)
    }

    /// Heavy rows that are short could add up to a cap without filling a window: they would stand at the end of the thread, and what the
    /// lazy stack above them estimates, a reader could scroll past.
    @Test func theRowsThatCoverTheWindowAreLaidOutWhateverTheyCost() async {
        let store = await store(20, cycles: { _ in 8 })
        let costs = costs(store)
        let cover = store.eagerRowCount(coveringHeight: 9_000, maxRows: 30)
        #expect(cover > within(1, costs) && cover < 30, "\(cover) rows cover 9,000 points")
        #expect(store.eagerTailRows(maxRows: 30, costCap: 1, coveringHeight: 9_000) == cover)
        #expect(store.eagerTailRows(maxRows: 30, costCap: 1, coveringHeight: 1_000_000) == 30, "never more rows than allowed")
        // The cap still bounds what the window does not need.
        let cap = 4 * costs[1]
        #expect(store.eagerTailRows(maxRows: 30, costCap: cap, coveringHeight: 1) == within(cap, costs))
        #expect(store.eagerTailRows(maxRows: 30, costCap: cap, coveringHeight: 9_000) == max(within(cap, costs), cover))
    }

    @Test func theStreamingReplyIsReachedPastRowsQueuedBelowIt() async {
        var queued = F.user("later", id: "u-later")
        queued.status = "queued"
        let host = FakeHost(F.snapshot(running: true, messages: messages(6, cycles: { _ in 8 }) + [queued]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        await store.waitForProse()
        #expect(store.liveRowID != nil && store.rows.contains(where: \.live))
        let below = store.rows.count - (store.rows.lastIndex(where: \.live) ?? 0)
        #expect(below == 2)
        #expect(store.eagerTailRows(maxRows: 30, costCap: 1, coveringHeight: 1) == below, "the live reply and the rows queued under it")
    }

    @Test func rowsTheViewLeavesOutDoNotCount() async {
        let store = await store(20, cycles: { _ in 8 })
        let costs = costs(store)
        let replies = costs.indices.filter { !store.rows[$0].isUser }.map { costs[$0] }
        let cap = 5 * replies[0]
        #expect(store.eagerTailRows(maxRows: 30, costCap: cap, coveringHeight: 1) { $0.isUser } == within(cap, replies), "five replies, not their questions too")
        #expect(store.eagerTailRows(maxRows: 30, costCap: .max, coveringHeight: 1) { $0.isUser } == 20)
        #expect(store.eagerTailRows(maxRows: 30, costCap: .max, coveringHeight: 1) { _ in true } == 0)
    }

    /// A large reply is parsed off the main thread and has no blocks until it lands, which is when a thread is first drawn: its rows would
    /// all be cheap, and the whole tail would be built.
    @Test func aLargeReplyCostsByItsTextUntilItsParseLands() async {
        let reply = NativeMountedCostTests.bigReply(cycles: 12)
        #expect(reply.utf8.count >= NativeThreadStore.offMainProseBytes)
        let store = NativeThreadStore()
        store.preview(F.snapshot(messages: [F.user("question", id: "u"), F.assistant(reply, id: "a")]))
        let pending = costs(store)[1]
        let revision = store.rowCostRevision
        #expect(pending == Cost.rowBase + reply.utf8.count * Cost.textByte, "\(pending >> 20) MiB")
        #expect(store.eagerTailRows(maxRows: 30, costCap: pending - 1, coveringHeight: 1) == 1, "the cap sees the reply at once")
        await store.waitForProse()
        #expect(costs(store)[1] != pending && costs(store)[1] > 2 * Cost.rowBase, "its blocks cost what they cost")
        #expect(store.rowCostRevision != revision, "a view looks again at what the tail may hold")
    }

    /// A reply with no blocks draws as nothing, so the tail is a few points tall until they land; a lazy stack drawn above it would be in
    /// the window and build its rows.
    @Test func theTailAwaitsTheParseOfALargeReplyAndNotOfASmallOne() async {
        let large = NativeThreadStore()
        large.preview(F.snapshot(messages: messages(3, cycles: { _ in 12 })))
        #expect(large.tailAwaitsParse(lastRows: 1) && large.tailAwaitsParse(lastRows: 6))
        #expect(!large.tailAwaitsParse(lastRows: 0))
        await large.waitForProse()
        #expect(!large.tailAwaitsParse(lastRows: 6), "its blocks landed")
        let small = await store(3, cycles: { _ in 0 })
        #expect(!small.tailAwaitsParse(lastRows: 6), "a short reply is parsed at once")
    }

    @Test func aStreamedChunkLeavesTheCostRevisionAlone() async {
        let host = FakeHost(F.snapshot(running: true, messages: messages(3, cycles: { _ in 0 }) + [F.user("go", id: "u-go")],
                                       provisional: [F.assistant("chunk", status: "streaming", id: "live")]))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel(); store.stop() }
        #expect(store.liveRowID != nil)
        let first = store.rowCostRevision, cost = costs(store).last
        for text in ["chunk and more words", "chunk and more words, and a few more\n\n```swift\nlet a = 1\n```"] {
            host.snapshot.revision += 1
            host.snapshot.provisional = [F.assistant(text, status: "streaming", id: "live")]
            await store.refresh()
        }
        #expect(costs(store).last != cost, "the live reply costs more with every chunk")
        #expect(store.rowCostRevision == first, "and a view is not asked to look at the tail again for it")
    }

    @Test func aThreadWithoutRowsHasNoTail() {
        #expect(NativeThreadStore().eagerTailRows(maxRows: 30, costCap: Cost.eagerTailCap, coveringHeight: 2_000) == 0)
    }

    /// What a view says it drew is what the budget counts, and a thread whose history was let go has drawn nothing.
    @Test func whatTheViewDrewIsClearedWithTheHistory() async {
        let host = FakeHost(F.snapshot(messages: messages(4, cycles: { _ in 0 })))
        let store = manualStore()
        let loop = await start(store, host)
        defer { loop.cancel() }
        store.drawnEagerRows = 3
        loop.cancel()
        store.stop()
        store.release()
        #expect(store.rows.isEmpty && store.drawnEagerRows == nil)
    }
}
