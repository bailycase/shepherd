import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote

/// The "Edited N files" card a finished reply carries: the host's record of its turn, found by the
/// user message that opened it, and following the record as Undo and Redo change it.
@Suite("NativeThreadStore changes card", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadStoreChangesTests {
    static let asked = NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "go")], timestamp: 42)
    static let edit = Fixture.tool("edit", args: #"{"path":"a.go","oldText":"x","newText":"y\nz"}"#, output: "Edited", id: "t")
    static let reply = Fixture.assistant("done", id: "a")

    static func turn(_ state: ChangesTurn.State) -> ChangesTurn {
        ChangesTurn(id: UUID(uuidString: "7E000000-0000-4000-8000-000000000002")!, messageTimestamp: 42, startedAt: 40, state: state,
                    files: [ChangesFile(path: "a.go", status: .modified, added: 9, removed: 3)], added: 9, removed: 3,
                    canUndo: state == .ready, canRedo: state == .undone)
    }

    static func snapshot(revision: UInt64 = 1, turns: [ChangesTurn]?) -> NativeThreadSnapshot {
        var snapshot = Fixture.snapshot(revision: revision, messages: [asked, edit, reply])
        snapshot.turnChanges = turns
        return snapshot
    }

    @Test func aFinishedReplyCarriesItsRecordedTurnAndFollowsUndo() async {
        let host = FakeHost(Self.snapshot(turns: [Self.turn(.ready)]))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        let card = store.rows.last?.changes
        #expect(card?.turnID == Self.turn(.ready).id && card?.canUndo == true && card?.added == 9)

        host.snapshot = Self.snapshot(revision: 2, turns: [Self.turn(.undone)])
        await store.refresh()
        #expect(store.rows.last?.changes?.state == .undone && store.rows.last?.changes?.canRedo == true)
    }

    /// An older host records no turns: the card comes from the edit calls, without Undo.
    @Test func withoutARecordTheReplyKeepsTheCardFromItsEdits() async {
        let host = FakeHost(Self.snapshot(turns: nil))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        let card = store.rows.last?.changes
        #expect(card?.turnID == nil && card?.canUndo == false && card?.rows.map(\.path) == ["a.go"])
        #expect(store.rows.first?.changes == nil)
    }
}
