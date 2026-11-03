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

        // A new version (the live row finished, IDs unchanged): the live row clears, the IDs are kept.
        index.update([row("a"), row("b")], version: 2)
        #expect(index.stamp == stamp)
        #expect(index.liveRow == nil)

        // A filtered view of the rows at one version (a project thread hiding a turn): the count tells them apart.
        index.update([row("a")], version: 2)
        #expect(index.ids == ["a"])
    }

    /// Streaming text in the tail of many short turns advances the version but never the IDs.
    @Test func tailTextDoesNotRebuildStructure() {
        let index = ThreadRowIndex()
        var rows = (0..<200).map { row("t\($0)") } + [row("tail", live: true)]
        index.update(rows, version: 1)
        let stamp = index.stamp
        for version in 2...50 { index.update(rows, version: version) }
        #expect(index.stamp == stamp)
        #expect(index.liveRow?.id == "tail")

        // Live -> finished with unchanged IDs: the live row clears without a structural rebuild.
        rows[rows.count - 1] = row("tail")
        index.update(rows, version: 51)
        #expect(index.liveRow == nil)
        #expect(index.stamp == stamp)
    }

    @Test func middleReplacementPrependAndResetRebuild() {
        let index = ThreadRowIndex()
        index.update([row("a"), row("b"), row("c")], version: 1)
        var stamp = index.stamp

        index.update([row("a"), row("x"), row("c")], version: 2)
        #expect(index.stamp == stamp + 1)
        #expect(index.set == ["a", "x", "c"])
        stamp = index.stamp

        index.update([row("x"), row("a"), row("c")], version: 3)
        #expect(index.stamp == stamp + 1)
        #expect(index.ids == ["x", "a", "c"])
        stamp = index.stamp

        index.update([row("p"), row("x"), row("a"), row("c")], version: 4)
        #expect(index.stamp == stamp + 1)
        stamp = index.stamp

        index.update([], version: 5)
        #expect(index.stamp == stamp + 1)
        #expect(index.ids.isEmpty && index.liveRow == nil)
    }
}
