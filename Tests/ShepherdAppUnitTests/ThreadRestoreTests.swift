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

    /// What a hidden view drew is drawn: showing it again is a flip, and does not take its stack away for a frame; one whose history was let
    /// go draws its first rows again as any thread does.
    @Test func aThreadThatDrewItsRowsWhileHiddenKeepsItsStackAndOneThatLostThemWaitsAgain() {
        let long = store(turns: 24)
        let rows = long.rows
        let restore = ThreadRestore()
        _ = restore.plan(active: false, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 })
        #expect(restore.plan(active: true, hiddenKept: nil, rows: rows, eagerRows: 12, owed: { _ in 0 }) == nil)
        _ = restore.plan(active: false, hiddenKept: nil, rows: [NativeThreadRow](), eagerRows: 12, owed: { _ in 0 })
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
