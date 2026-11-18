import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Where a thread's eager tail starts, and how far it moves when the thread's rows change (`ThreadEagerTail`).
@Suite("Thread eager tail boundary")
@MainActor
struct ThreadEagerTailBoundaryTests {
    private static let maxRows = 30

    /// Sixty question and answer pairs of one short line each: rows with stable IDs, of which a test reveals as many as it likes.
    private static let all: [NativeThreadRow] = {
        let messages = (0..<60).flatMap { i in
            ["user", "assistant"].map { role in
                NativeThreadMessage(entryID: "\(role)-\(i)", role: role, blocks: [NativeThreadBlock(kind: .text, text: "\(role) \(i)")])
            }
        }
        let store = NativeThreadStore()
        store.preview(NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: [],
                                           dialogsSupported: true, dialogs: [], messages: messages, provisional: [], clipped: false))
        return store.rows
    }()

    /// The tail once the thread has its first `count` rows, at structure `revision`, the rule saying `rule`.
    private func update(_ tail: ThreadEagerTail, count: Int, revision: Int, rule: Int, cover: Int = 1, costs: Int = 0, detached: Bool = true) -> Int {
        tail.update(rows: Array(Self.all.prefix(count)), revision: revision, costs: costs, cover: cover, maxRows: Self.maxRows, crossing: 2,
                    detached: detached) { rule }
    }

    @Test func aThreadDrawnForTheFirstTimeTakesTheRuleWhole() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 80, revision: 1, rule: 7) == 7)
        #expect(tail.held(rows: Array(Self.all.prefix(80))) { Issue.record("a thread that has drawn needs no rule"); return 0 } == 7)
    }

    /// Thirty rows of cheap turns slide a row each time one arrives, as a fixed thirty did.
    @Test func aTailOfCheapRowsSlidesAsTheThreadGrows() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 4, revision: 1, rule: 4) == 4)
        #expect(update(tail, count: 30, revision: 2, rule: 30) == 30)
        for (revision, count) in [(3, 31), (4, 32), (5, 34), (6, 35), (7, 80)] {
            #expect(update(tail, count: count, revision: revision, rule: 30) == 30, "\(count) rows")
        }
    }

    /// A reader away from the tail sees the rows at the start of the tail: no more than two of them leave for the lazy stack, whatever
    /// a heavy reply that landed asks, and a turn's own rows arriving at the end do not count as a crossing.
    @Test func aDetachedReadersTailMovesTwoRowsAtATimeTowardTheRule() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 40, revision: 1, rule: 24) == 24)
        var seen: [Int] = []
        for (step, count) in [42, 44, 46, 48, 50].enumerated() {
            seen.append(update(tail, count: count, revision: 2 + step, rule: 6))
        }
        #expect(seen == [24, 24, 24, 24, 24], "two rows arrive and two leave: \(seen)")
        #expect(update(tail, count: 50, revision: 7, rule: 6) == 22, "no row arrives and two leave")
        #expect(update(tail, count: 50, revision: 7, rule: 6) == 22, "nothing changed, nothing moved")
        #expect(update(tail, count: 51, revision: 8, rule: 6) == 21, "one row arrived and two left")
    }

    @Test func aTailMovesNoMoreThanTwoRowsOutOfItsStackWhateverTheRuleAsks() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 40, revision: 1, rule: 20) == 20)
        // The same rows with the window changed: the rule wants 4, the start moves two rows.
        #expect(update(tail, count: 40, revision: 2, rule: 4) == 18)
        #expect(update(tail, count: 40, revision: 3, rule: 4) == 16)
        #expect(update(tail, count: 40, revision: 4, rule: 4) == 14)
    }

    /// A reader following the tail cannot see the rows that leave (above the two viewports it covers), so a thread that turned heavy
    /// under it comes down to what its rows cost in one change, however many rows arrive with each turn.
    @Test func aFollowingReadersTailComesDownToTheRuleAtOnce() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 40, revision: 1, rule: 30, detached: false) == 30)
        #expect(update(tail, count: 42, revision: 2, rule: 9, detached: false) == 9)
        #expect(update(tail, count: 44, revision: 3, rule: 9, detached: false) == 9)
        #expect(update(tail, count: 44, revision: 4, rule: 5, detached: false) == 5)
    }

    @Test func aTailGrowsBackTwoRowsAtATimeAndNeverPastTheRule() {
        for detached in [true, false] {
            let tail = ThreadEagerTail()
            #expect(update(tail, count: 40, revision: 1, rule: 4, detached: detached) == 4)
            #expect(update(tail, count: 40, revision: 2, rule: 20, detached: detached) == 6)
            #expect(update(tail, count: 40, revision: 3, rule: 20, detached: detached) == 8)
            #expect(update(tail, count: 40, revision: 4, rule: 7, detached: detached) == 7, "never past the rule")
        }
    }

    /// A catch-up that lands many rows at once leaves a tail of more than thirty: the rows past thirty go at once, as they always did.
    @Test func rowsPastTheMostAThreadDrawsAreNotKept() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 40, revision: 1, rule: 30) == 30)
        #expect(update(tail, count: 52, revision: 2, rule: 30) == 30)
        let heavy = ThreadEagerTail()
        #expect(update(heavy, count: 40, revision: 1, rule: 12) == 12)
        #expect(update(heavy, count: 72, revision: 2, rule: 12) == 30, "thirty is the most a detached reader's tail keeps")
    }

    @Test func aBoundaryRowThatIsGoneStartsAgainFromTheRule() {
        let tail = ThreadEagerTail()
        #expect(update(tail, count: 40, revision: 1, rule: 10) == 10)
        // The history was let go and came back as other rows (a session swap does the same).
        let other = Array(Self.all.suffix(8))
        #expect(tail.update(rows: other, revision: 2, costs: 0, cover: 1, maxRows: Self.maxRows, crossing: 2, detached: true) { 3 } == 3)
        #expect(tail.update(rows: [NativeThreadRow](), revision: 3, costs: 0, cover: 1, maxRows: Self.maxRows, crossing: 2, detached: true) { 3 } == 0, "no rows, no tail")
        #expect(update(tail, count: 40, revision: 4, rule: 9) == 9, "and the rule whole again when rows return")
    }

    @Test func theRuleIsAskedOnlyWhenTheRowsOrTheWindowChange() {
        let tail = ThreadEagerTail()
        var asked = 0
        func read(count: Int, revision: Int, cover: Int, costs: Int = 0) -> Int {
            tail.update(rows: Array(Self.all.prefix(count)), revision: revision, costs: costs, cover: cover, maxRows: Self.maxRows, crossing: 2,
                        detached: true) { asked += 1; return 20 }
        }
        for _ in 0..<3 { _ = read(count: 40, revision: 1, cover: 1) }
        #expect(asked == 1, "a streamed chunk redraws the body and moves nothing")
        _ = read(count: 40, revision: 1, cover: 2)
        _ = read(count: 42, revision: 2, cover: 2)
        #expect(asked == 3)
        _ = read(count: 42, revision: 2, cover: 2, costs: 1)
        #expect(asked == 4, "a reply's parse landing changes what a row costs")
    }

    /// The stack of older rows waits for the tail's replies to have their blocks the first time, and a reader in it never loses it after.
    @Test func theHistoryWaitsForTheTailTheFirstTimeAndStaysOnceDrawn() {
        let tail = ThreadEagerTail()
        #expect(tail.drawsHistory(rows: 0, settling: true), "no rows, nothing to hold back")
        #expect(!tail.drawsHistory(rows: 40, settling: true))
        #expect(!tail.drawsHistory(rows: 42, settling: true))
        #expect(tail.drawsHistory(rows: 42, settling: false))
        #expect(tail.drawsHistory(rows: 44, settling: true), "a large reply arriving later leaves the reader's stack alone")
        #expect(tail.drawsHistory(rows: 0, settling: false), "its history was let go")
        #expect(!tail.drawsHistory(rows: 40, settling: true), "and the next load waits again")
    }

    @Test func aThreadThatNeverDrewHoldsWhatTheRuleSays() {
        let tail = ThreadEagerTail()
        #expect(tail.held(rows: Array(Self.all.prefix(40))) { 9 } == 9)
        #expect(tail.held(rows: Array(Self.all.prefix(5))) { 9 } == 5, "never more than its rows")
        #expect(tail.held(rows: [NativeThreadRow]()) { 9 } == 0)
    }
}
