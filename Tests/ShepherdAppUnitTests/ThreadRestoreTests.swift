import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// How a thread that let its rows go decides what its first frame back draws (`ThreadRestore`).
@Suite("Thread restore")
@MainActor
struct ThreadRestoreTests {
    /// A store whose thread is `turns` question and answer pairs of one short line each.
    private func store(turns: Int) -> NativeThreadStore {
        let messages = (0..<turns).flatMap { i in
            ["user", "assistant"].map { role in
                NativeThreadMessage(entryID: "\(role)-\(i)", role: role, blocks: [NativeThreadBlock(kind: .text, text: "\(role) \(i)")])
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
        let long = store(turns: 12)
        #expect(long.keptRows == 4 && long.restoreCost(drawn: 4, upTo: ThreadView.eagerRows) > AppLayout.restoreStepBytes)
        let frame = firstFrame(long)
        #expect(frame.plan == ThreadRestore.Plan(eager: 4, history: false) && frame.restoring, "the rows it kept, and the rest after that frame")
    }

    /// There is nothing to spread over frames, and a last screen shorter than the window would be all it drew first.
    @Test func aThreadThatOwesNoMoreThanAStepDrawsItAllInItsFirstFrame() {
        let short = store(turns: 3)
        #expect(short.rows.count == 6 && short.keptRows == 4)
        #expect(short.restoreCost(drawn: 4, upTo: ThreadView.eagerRows) <= AppLayout.restoreStepBytes)
        let frame = firstFrame(short)
        #expect(frame.plan == nil && !frame.restoring, "it draws every row, as the thread on screen does")
    }

    @Test func aThreadThatKeptEveryRowRestoresNothing() {
        let few = store(turns: 2)
        let frame = firstFrame(few)
        #expect(few.keptRows == few.rows.count && frame.plan == nil && !frame.restoring)
    }
}
