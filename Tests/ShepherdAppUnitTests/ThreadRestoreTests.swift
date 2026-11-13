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
