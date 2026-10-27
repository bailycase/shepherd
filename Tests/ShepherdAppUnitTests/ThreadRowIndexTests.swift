import Testing
@testable import ShepherdRemote
@testable import ShepherdApp

/// The thread's row IDs and live row, derived once per change rather than on every streamed chunk.
@Suite("Thread row index")
@MainActor
struct ThreadRowIndexTests {
    private func row(_ id: String, live: Bool = false) -> NativeThreadRow {
        NativeThreadRow(turn: NativeTurn(id: id, isUser: false, messages: []), presentation: nil, live: live, promptText: nil, startedAt: nil)
    }

    @Test func rebuildsOnlyWhenTheRowsChange() {
        let index = ThreadRowIndex()
        index.update([row("a"), row("b", live: true)], version: 1)
        #expect(index.ids == ["a", "b"])
        #expect(index.set == ["a", "b"])
        #expect(index.liveRow?.id == "b")
        let stamp = index.stamp

        // The same rows at the same version (a render for a reason other than the rows): nothing rebuilt.
        index.update([row("a"), row("b", live: true)], version: 1)
        #expect(index.stamp == stamp)

        // A new version (the live row finished): rebuilt.
        index.update([row("a"), row("b")], version: 2)
        #expect(index.stamp == stamp + 1)
        #expect(index.liveRow == nil)

        // A filtered view of the rows at one version (a project thread hiding a turn): the count tells them apart.
        index.update([row("a")], version: 2)
        #expect(index.ids == ["a"])
    }
}
