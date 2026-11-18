import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// A thread lays out for real only the rows at its end that its cost allows, whatever its history holds: counted in what the
/// window builds (code fields), as the person sees it, not in what a store reports.
@Suite("Thread eager tail", .serialized, .mainActorExclusive)
@MainActor
struct ThreadEagerTailTests {
    /// The estimated bytes of views the rows at the end of a thread may hold (`NativeMountedCost.eagerTailCap`).
    static let cap = NativeMountedCost.eagerTailCap
    /// Cycles of a paragraph, a fence, a table and a list in one reply: each is a code field in the window while its row is built.
    static let cycles = 20

    /// `turns` questions and answers, each answer of `cycles` cycles.
    static func messages(turns: Int, cycles: Int) -> [NativeThreadMessage] {
        (0..<turns).flatMap { i in
            [ThreadFixture.user("u\(i)", "Question \(i)"), ThreadFixture.assistant("a\(i)", MarkdownFixtures.longReply(cycles: cycles, from: i * cycles))]
        }
    }

    private static func fields(in view: NSView) -> Int {
        (view is SHNativeCodeText.Field ? 1 : 0) + view.subviews.reduce(0) { $0 + fields(in: $1) }
    }

    /// A thread opened in a window, loaded and drawn: the code fields it built once they stopped changing, and the most it held on the way.
    private static func open(turns: Int, cycles: Int) async throws -> (thread: FakeThread, fields: Int, peak: Int) {
        let thread = FakeThread(ThreadFixture.snapshot(messages(turns: turns, cycles: cycles)), deckHosting: true)
        try await thread.waitUntilReady()
        var last = -1, still = 0, peak = 0
        try await eventuallyOnMain("the thread to stop building code fields", timeout: .seconds(60)) {
            ListPerf.settle(thread.window)
            let now = fields(in: thread.window.host)
            peak = max(peak, now)
            still = now > 0 && now == last ? still + 1 : 0
            last = now
            return still >= 8
        }
        return (thread, last, peak)
    }

    /// How many of the last rows of `store` fit `cap`, the last one always: what the rule counts.
    private static func rowsWithin(_ cap: Int, of store: NativeThreadStore) -> Int {
        var cost = 0, taken = 0
        for row in store.rows.reversed() {
            let next = NativeMountedCost.row(row)
            if taken > 0, cost + next > cap { break }
            cost += next
            taken += 1
        }
        return taken
    }

    /// Opening a thread of heavy replies builds the replies its cost allows and not the thirty rows it used to: a code field is a
    /// fence of a built reply, so what the window holds is what was laid out.
    @Test func aHeavyThreadBuildsOnlyTheRowsItsCostAllowsWhenItOpens() async throws {
        let (thread, fields, peak) = try await Self.open(turns: 40, cycles: Self.cycles)
        defer { thread.close() }
        let store = thread.store
        #expect(store.rows.count == 80)
        let tail = store.mountedCost(eagerRows: ThreadView.eagerRows)
        #expect(tail > 2 * Self.cap, "the thirty rows at the end hold \(tail >> 20) MiB, the fixture is heavy enough")
        let allowed = Self.rowsWithin(Self.cap, of: store)
        #expect(allowed >= 4 && allowed < ThreadView.eagerRows / 2 + 4, "\(allowed) rows fit the cap")
        // The lazy stack above the tail builds nothing: the window is at the tail, and the stack is drawn once the tail has its content.
        let ceiling = allowed / 2 * Self.cycles
        #expect(fields <= ceiling, "\(fields) code fields are built, \(ceiling) at most for \(allowed) rows")
        #expect(peak <= ceiling, "and never more on the way: \(peak) code fields at most")
        #expect(fields >= Self.cycles, "the last reply is built")
    }

    /// Shown again after its history was let go, the thread reloads it and lays out the same: the rows its cost allows, not the
    /// thirty a reload used to build in one update.
    @Test func aThreadWhoseHistoryReloadsBuildsOnlyTheRowsItsCostAllowsToo() async throws {
        let (thread, _, _) = try await Self.open(turns: 40, cycles: Self.cycles)
        defer { thread.close() }
        let store = thread.store
        try await thread.show(false)
        store.release()
        #expect(store.rows.isEmpty, "its history is gone")
        try await thread.show(true)
        var last = -1, still = 0
        try await eventuallyOnMain("the reloaded thread to stop building code fields", timeout: .seconds(60)) {
            ListPerf.settle(thread.window)
            let now = Self.fields(in: thread.window.host)
            still = now > 0 && now == last ? still + 1 : 0
            last = now
            return still >= 8 && store.rows.count == 80
        }
        let allowed = Self.rowsWithin(Self.cap, of: store)
        #expect(allowed >= 4 && allowed < ThreadView.eagerRows / 2 + 4, "\(allowed) rows fit the cap")
        let ceiling = allowed / 2 * Self.cycles
        #expect(last <= ceiling, "\(last) code fields are built, \(ceiling) at most for \(allowed) rows")
        #expect(last >= Self.cycles, "the last reply is built")
    }

    /// A thread whose rows are cheap has nothing to bound: its thirty rows are laid out as before.
    @Test func aCheapThreadStillLaysOutItsWholeTail() async throws {
        let (thread, fields, _) = try await Self.open(turns: 40, cycles: 1)
        defer { thread.close() }
        #expect(thread.store.mountedCost(eagerRows: ThreadView.eagerRows) < Self.cap / 4)
        #expect(fields >= ThreadView.eagerRows / 2, "the fifteen replies of its tail are built: \(fields)")
    }
}
