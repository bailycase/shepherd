import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// How a thread that let its rows go decides what its first frame back draws (`ThreadRestore`).
@Suite("Thread restore")
@MainActor
struct ThreadRestoreTests {
    /// A store whose thread is `turns` question and answer pairs, each of one short line, or, where `heavy` says so, an answer of
    /// text and a fence (what a code-heavy reply costs the views).
    private func store(turns: Int, heavy: (Int) -> Bool = { _ in false }) -> NativeThreadStore {
        let code = (0..<60).map { "let value\($0) = compute(\($0), scale: 2.5) // a line of Swift" }.joined(separator: "\n")
        let messages = (0..<turns).flatMap { i in
            ["user", "assistant"].map { role in
                let text = role == "assistant" && heavy(i) ? "Here is the change.\n\n```swift\n\(code)\n```" : "\(role) \(i)"
                return NativeThreadMessage(entryID: "\(role)-\(i)", role: role, blocks: [NativeThreadBlock(kind: .text, text: text)])
            }
        }
        let store = NativeThreadStore()
        store.preview(NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: [],
                                           dialogsSupported: true, dialogs: [], messages: messages, provisional: [], clipped: false))
        return store
    }

    /// Hidden at its last screen, then shown: what the first update back draws.
    private func firstFrame(_ store: NativeThreadStore, restore: ThreadRestore = ThreadRestore()) -> (plan: ThreadRestore.Plan?, restoring: Bool) {
        let rows = store.rows, eager = ThreadView.eagerRows
        let owed: (Int) -> Int = { store.restoreCost(drawn: $0, upTo: eager) }
        _ = restore.plan(active: false, hiddenKept: store.keptRows, rows: rows, eagerRows: eager, owed: owed)
        let plan = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed)
        return (plan, restore.restoring)
    }

    @Test func aThreadThatOwesMoreThanAStepDrawsOnlyItsLastScreenFirst() {
        let long = store(turns: 12, heavy: { _ in true })
        #expect(long.keptRows == 4 && long.restoreCost(drawn: 4, upTo: ThreadView.eagerRows) > AppLayout.restoreStepBytes)
        let frame = firstFrame(long)
        #expect(frame.plan == ThreadRestore.Plan(eager: 4, history: false) && frame.restoring, "the rows it kept, and the rest after that frame")
    }

    /// Mostly short rows with a heavy reply now and then still owe more than a step: what they cost to build is the replies'.
    @Test func aThreadOfShortRowsWithHeavyRepliesAmongThemStillRestoresInSteps() {
        let mixed = store(turns: 15, heavy: { $0 % 3 == 0 })
        #expect(mixed.restoreCost(drawn: mixed.keptRows, upTo: ThreadView.eagerRows) > AppLayout.restoreStepBytes)
        let frame = firstFrame(mixed)
        #expect(frame.plan == ThreadRestore.Plan(eager: mixed.keptRows, history: false) && frame.restoring)
    }

    /// There is nothing to spread over frames, and a last screen shorter than the window would be all it drew first.
    @Test func aThreadThatOwesNoMoreThanAStepDrawsItAllInItsFirstFrame() {
        let short = store(turns: 3)
        #expect(short.rows.count == 6 && short.keptRows == 4)
        #expect(short.restoreCost(drawn: 4, upTo: ThreadView.eagerRows) <= AppLayout.restoreStepBytes)
        let frame = firstFrame(short)
        #expect(frame.plan == nil && !frame.restoring, "it draws every row, as the thread on screen does")
    }

    /// A row's chrome costs 0.59 MiB of memory but a few views, so a dozen rows of one line each are not worth spreading over frames,
    /// though their chrome alone adds up to more than a step: they draw whole in the first frame, and never hold the window at the
    /// bottom (`ThreadTailAnchor`) to take it away once the rest is back.
    @Test(arguments: [6, 12, 15, 20])
    func aThreadOfOneLineRowsDrawsItAllInItsFirstFrame(turns: Int) {
        let cheap = store(turns: turns)
        let owed = min(cheap.rows.count, ThreadView.eagerRows) - cheap.keptRows
        #expect(cheap.keptRows == 4)
        if turns >= 6 { #expect(owed * NativeMountedCost.rowBase > AppLayout.restoreStepBytes, "their chrome alone is more than a step") }
        #expect(cheap.restoreCost(drawn: cheap.keptRows, upTo: ThreadView.eagerRows) <= AppLayout.restoreStepBytes)
        let frame = firstFrame(cheap)
        #expect(frame.plan == nil && !frame.restoring, "\(turns) turns draw every row at once")
    }

    /// A thread that let go of its older history and kept its end (`NativeThreadStore.releaseToTail`): its hidden view draws none of the
    /// rows, what it owes is little, and its tail is bound by cost with more rows above it. The first frame draws that tail alone and the
    /// lazy stack comes after it, as for rows that arrive: the stack's first screen would be built with the tail, rows as heavy as it. The
    /// stack waits for the pull that catches the thread up.
    @Test func aThreadThatKeptOnlyItsTailDrawsItsEagerTailAloneAndTheLazyStackAfterThatFrame() {
        let long = store(turns: 24)
        let rows = long.rows, eager = 12
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        #expect(owed(1) <= AppLayout.restoreStepBytes, "what it owes is no more than a step")
        let restore = ThreadRestore()
        _ = restore.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        let first = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, keepsOnlyTail: true, owed: owed)
        #expect(first == ThreadRestore.Plan(eager: 12, history: false) && restore.restoring && restore.awaitsHistory && restore.awaitsPull)
        let more = restore.advance(rows: rows, eagerRows: eager) { _ in Issue.record("the stack takes no rows"); return 0 }
        #expect(more && restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, keepsOnlyTail: true, owed: owed) == nil,
                "the stack and every row are drawn")
        #expect(!restore.awaitsPull, "and nothing is waited for any more")

        // A thread that is no more than its tail has no stack to hold back: it draws at once.
        let short = ThreadRestore()
        let few = store(turns: 6).rows
        _ = short.plan(active: false, hiddenKept: 0, rows: few, eagerRows: few.count, owed: owed)
        #expect(short.plan(active: true, hiddenKept: nil, rows: few, eagerRows: few.count, keepsOnlyTail: true, owed: owed) == nil
                && !short.restoring && !short.awaitsPull)
    }

    /// A release that cut nothing (the thread held no more than a tail) leaves the same thread: it comes back as a tail does, its eager tail
    /// alone, where a thread that holds its history draws every row it owes in its first frame.
    @Test func aThreadReleasedToATailThatCutNothingRestoresAsATailDoes() {
        let long = store(turns: 24)
        let rows = long.rows, eager = 12
        long.releaseToTail(rows: ThreadView.eagerRows, maxBytes: .max)
        #expect(long.keepsOnlyTail && long.rows == rows, "nothing was cut")
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        let restore = ThreadRestore()
        _ = restore.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        let first = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, keepsOnlyTail: long.keepsOnlyTail, owed: owed)
        #expect(first == ThreadRestore.Plan(eager: 12, history: false) && restore.awaitsPull)

        let holding = ThreadRestore()
        _ = holding.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        #expect(holding.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed) == nil && !holding.awaitsPull)
    }

    /// The lazy stack of a thread that kept only its tail waits for its pull for the looks the parse is waited for, and not at all for
    /// one that has landed or is not coming (it failed, or pi is not up), and a thread that holds its history waits for none.
    @Test func theFirstStackWaitsForThePullOnlyWhileItIsOnItsWay() {
        let long = store(turns: 24)
        let rows = long.rows, eager = 12
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        let tail = ThreadRestore()
        _ = tail.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        _ = tail.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, keepsOnlyTail: true, owed: owed)
        #expect(tail.waitsForPull(landed: false, failed: false, retries: 0))
        #expect(tail.waitsForPull(landed: false, failed: false, retries: AppLayout.restoreParseRetries - 1))
        #expect(!tail.waitsForPull(landed: false, failed: false, retries: AppLayout.restoreParseRetries), "not for ever")
        #expect(!tail.waitsForPull(landed: true, failed: false, retries: 0), "it landed")
        #expect(!tail.waitsForPull(landed: false, failed: true, retries: 0), "it failed, or pi is not up: nothing is on its way")

        let holding = ThreadRestore()
        _ = holding.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        _ = holding.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed)
        #expect(!holding.waitsForPull(landed: false, failed: false, retries: 0))
    }

    /// A thread that holds its history and let its rows go (the mounted budget's pass) draws what it owes in its first frame when that is
    /// no more than a step, as it did before, and its stack waits for no pull.
    @Test func aThreadThatHoldsItsHistoryAndLetItsRowsGoDrawsWhatItOwesAtOnce() {
        let long = store(turns: 24)
        let rows = long.rows, eager = 12
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        let restore = ThreadRestore()
        _ = restore.plan(active: false, hiddenKept: 0, rows: rows, eagerRows: eager, owed: owed)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed) == nil, "all of it is drawn at once")
        #expect(!restore.restoring && !restore.awaitsPull)
    }

    @Test func aThreadThatKeptEveryRowRestoresNothing() {
        let few = store(turns: 2)
        let frame = firstFrame(few)
        #expect(few.keptRows == few.rows.count && frame.plan == nil && !frame.restoring)
    }

    /// The first rows of a thread (it opened, or its history came back) draw their eager tail alone, and the lazy stack the frame after:
    /// a stack drawn with them is shown its estimates before the scroll view is held to the tail, and builds rows at the top.
    @Test func theFirstRowsOfAThreadWhoseTailIsBoundByCostDrawItAloneAndTheLazyStackAfterThatFrame() {
        let long = store(turns: 24)
        let rows = long.rows, eager = 12
        #expect(rows.count == 48)
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        let restore = ThreadRestore()
        #expect(restore.plan(active: true, hiddenKept: nil, rows: [NativeThreadRow](), eagerRows: eager, owed: owed) == nil, "no rows, nothing to hold back")
        let first = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed)
        #expect(first == ThreadRestore.Plan(eager: 12, history: false) && restore.restoring && restore.awaitsHistory)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed) == first, "until the step that brings the stack")
        let more = restore.advance(rows: rows, eagerRows: eager) { _ in Issue.record("the stack takes no rows"); return 0 }
        #expect(more && !restore.awaitsHistory)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed) == nil, "the stack and every row are drawn")
        #expect(!restore.restoring)
        // A thread of cheap rows, whose tail is the most there is, draws its stack with it as it always did.
        let cheap = ThreadRestore()
        #expect(cheap.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: ThreadView.eagerRows, owed: owed) == nil && !cheap.restoring)
    }

    /// The stack waits for an update that drew the tail's replies with their blocks: the one that brings them builds them.
    @Test func theRestoreKnowsWhetherTheLastUpdateDrewTheTailWithItsBlocks() {
        let long = store(turns: 24)
        let restore = ThreadRestore()
        #expect(restore.tailDrawnParsed)
        _ = restore.plan(active: true, hiddenKept: nil, rows: long.rows, eagerRows: 12, tailParsed: false, owed: { _ in 0 })
        #expect(!restore.tailDrawnParsed && restore.awaitsHistory)
        _ = restore.plan(active: true, hiddenKept: nil, rows: long.rows, eagerRows: 12, tailParsed: true, owed: { _ in 0 })
        #expect(restore.tailDrawnParsed)
    }

    /// A reply with no blocks to draw (whitespace before a tool call, a comment) is not one whose parse is awaited, so the stack comes after
    /// the frame that drew the tail as it does for any other thread, and not when the wait runs out.
    @Test func aTailWhoseLastReplyHasNothingToDrawStillGetsItsStack() {
        for reply in ["\n\n", "<!-- c -->"] {
            let messages = (0..<24).flatMap { i in
                [NativeThreadMessage(entryID: "u\(i)", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "question \(i)")]),
                 NativeThreadMessage(entryID: "a\(i)", role: "assistant",
                                     blocks: ((i == 23 ? [reply] : []) + ["answer \(i)"]).map { NativeThreadBlock(kind: .text, text: $0) })]
            }
            let long = NativeThreadStore()
            long.preview(NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: [],
                                              dialogsSupported: true, dialogs: [], messages: messages, provisional: [], clipped: false))
            let rows = long.rows, eager = 12
            #expect(rows.count == 48)
            #expect(rows.last?.presentation?.items.contains { if case .prose(_, let text, let prose) = $0 { text == reply && prose.isEmpty } else { false } } == true,
                    "the premise: a reply among the last rows with text and no blocks")
            let awaited = long.tailAwaitsParse(lastRows: eager)
            #expect(!awaited, "\(reply.debugDescription)")
            let restore = ThreadRestore()
            let first = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, tailParsed: !awaited, owed: { _ in 0 })
            #expect(first == ThreadRestore.Plan(eager: 12, history: false) && restore.awaitsHistory)
            #expect(!restore.waitsForParse(retries: 0), "nothing to wait for")
            #expect(restore.advance(rows: rows, eagerRows: eager) { _ in 0 } && !restore.awaitsHistory, "the stack comes")
        }
    }

    /// A parse that does not land holds the stack back only so long.
    @Test func theStackWaitsForAParseOnlyForSoLong() {
        let long = store(turns: 24)
        let restore = ThreadRestore()
        _ = restore.plan(active: true, hiddenKept: nil, rows: long.rows, eagerRows: 12, tailParsed: false, owed: { _ in 0 })
        #expect(restore.awaitsHistory && !restore.tailDrawnParsed)
        #expect(restore.waitsForParse(retries: 0) && restore.waitsForParse(retries: AppLayout.restoreParseRetries - 1))
        #expect(!restore.waitsForParse(retries: AppLayout.restoreParseRetries), "the stack comes with the tail still without its blocks")
        #expect(restore.advance(rows: long.rows, eagerRows: 12) { _ in 0 } && !restore.awaitsHistory)
    }

    @Test func aThreadWithNoRowsBeyondItsEagerTailHasNoStackToWaitFor() {
        let short = store(turns: 10)
        let restore = ThreadRestore()
        #expect(restore.plan(active: true, hiddenKept: nil, rows: short.rows, eagerRows: 20, owed: { _ in 0 }) == nil)
        #expect(!restore.restoring)
    }

    /// The first rows of a thread that arrive while it is hidden (a seeded history, another view polling it) draw its eager tail alone, as
    /// they do when it is shown: a lazy stack drawn with them in a window nobody sees is laid out from the top of the thread, and builds the
    /// rows there that nothing counts. It comes after the first frame the thread is shown, with the scroll view at the tail.
    @Test func aThreadWhoseRowsArriveWhileHiddenDrawsItsTailAloneAndItsStackAfterItIsShown() {
        let long = store(turns: 24)
        let rows = long.rows
        let restore = ThreadRestore()
        let hidden = restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 })
        #expect(hidden == ThreadRestore.Plan(eager: 12, history: false) && restore.awaitsHistory)
        #expect(restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == hidden, "it waits as long as it stays hidden")
        let shown = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 })
        #expect(shown == ThreadRestore.Plan(eager: 12, history: false) && restore.awaitsHistory, "and is shown as its tail")
        #expect(restore.advance(rows: rows, eagerRows: 12) { _ in 0 } && !restore.awaitsHistory)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == nil, "then the stack and every row are drawn")
        // A thread of cheap rows, whose tail is the most there is, draws its stack with it hidden as it always did.
        let cheap = ThreadRestore()
        #expect(cheap.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: ThreadView.eagerRows, owed: { _ in 0 }) == nil && !cheap.restoring)
    }

    /// Rows that arrive while the tail waits for its stack (a hidden thread waits as long as it stays hidden) are the rule's rows at most:
    /// the tail does not keep the row it started from and grow with them.
    @Test func rowsThatArriveWhileATailWaitsForItsStackDoNotGrowIt() {
        let long = store(turns: 24)
        let rows = long.rows
        let restore = ThreadRestore()
        #expect(restore.plan(active: false, hiddenKept: nil, rows: Array(rows.prefix(20)), eagerRows: 12, owed: { _ in 0 }) == ThreadRestore.Plan(eager: 12, history: false))
        for count in [24, 31, 48] {
            let plan = restore.plan(active: false, hiddenKept: nil, rows: Array(rows.prefix(count)), eagerRows: 12, owed: { _ in 0 })
            #expect(plan == ThreadRestore.Plan(eager: 12, history: false), "\(count) rows")
        }
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == ThreadRestore.Plan(eager: 12, history: false))
        let smaller = restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 6, owed: { _ in 0 })
        #expect(smaller == ThreadRestore.Plan(eager: 6, history: false), "or what the rule says now")
    }

    /// A hidden thread that follows its tail draws that tail alone, whichever way its stack came to be drawn: a stack in a window nobody
    /// scrolls builds the oldest rows and keeps them. A reader left in the history keeps the stack that holds their place.
    @Test func aHiddenThreadThatFollowsItsTailLosesItsStackAndAReaderKeepsIt() {
        let long = store(turns: 24)
        let rows = long.rows
        let restore = ThreadRestore()
        // Shown, it has its stack and every row.
        _ = restore.plan(active: true, hiddenKept: nil, rows: Array(rows.prefix(2)), eagerRows: 12, owed: { _ in 0 })
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == nil && !restore.restoring)
        // Hidden, it keeps its stack at first, so that taking it down is not a turn of the switch; a while after, it draws its tail alone.
        #expect(restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, following: true, owed: { _ in 0 }) == nil)
        restore.withdrawStack()
        #expect(restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, following: true, owed: { _ in 0 })
                == ThreadRestore.Plan(eager: 12, history: false))
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, following: true, owed: { _ in 0 })
                == ThreadRestore.Plan(eager: 12, history: false), "and shown again, the stack waits for its first frame")
        #expect(restore.advance(rows: rows, eagerRows: 12) { _ in 0 } && !restore.awaitsHistory)
        // A reader who is not at the tail keeps the stack.
        let reader = ThreadRestore()
        _ = reader.plan(active: true, hiddenKept: nil, rows: Array(rows.prefix(2)), eagerRows: 12, owed: { _ in 0 })
        _ = reader.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 })
        reader.withdrawStack()
        #expect(reader.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, following: false, owed: { _ in 0 }) == nil && !reader.restoring)
        // A thread of cheap rows has no cost to bound and keeps it too.
        let cheap = ThreadRestore()
        cheap.withdrawStack()
        #expect(cheap.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: ThreadView.eagerRows, following: true, owed: { _ in 0 }) == nil)
    }

    /// One whose history was let go draws its first rows again as any thread does.
    @Test func aThreadThatLostItsRowsWhileHiddenWaitsAgain() {
        let long = store(turns: 24)
        let rows = long.rows
        let restore = ThreadRestore()
        _ = restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 })
        _ = restore.plan(active: false, hiddenKept: nil, rows: [NativeThreadRow](), eagerRows: 12, owed: { _ in 0 })
        #expect(!restore.restoring)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: [NativeThreadRow](), eagerRows: 12, owed: { _ in 0 }) == nil)
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == ThreadRestore.Plan(eager: 12, history: false))
    }

    /// The lazy stack comes back with the first step, and until it does a reader cannot scroll to the rows above the last screen.
    @Test func aRestoreAwaitsItsLazyStackUntilItsFirstStep() {
        let long = store(turns: 12, heavy: { _ in true })
        let restore = ThreadRestore()
        let frame = firstFrame(long, restore: restore)
        #expect(frame.restoring && restore.awaitsHistory)
        let more = restore.advance(rows: long.rows, eagerRows: ThreadView.eagerRows) { _ in Issue.record("the first step takes no rows"); return 0 }
        #expect(more && !restore.awaitsHistory, "the first step brings the lazy stack back")
        let rows = long.rows, eager = ThreadView.eagerRows
        let owed: (Int) -> Int = { long.restoreCost(drawn: $0, upTo: eager) }
        let plan = restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: eager, owed: owed)
        #expect(plan == ThreadRestore.Plan(eager: 4, history: true))
        #expect(!ThreadRestore().awaitsHistory, "a thread that is not restoring awaits nothing")
    }
}
