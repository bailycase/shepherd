import Foundation
import Testing
@testable import ShepherdRemote
@testable import ShepherdApp

/// The thread's row IDs, rebuilt only when the store's row structure revision moves (or the view's filter changes them).
@Suite("Thread row index")
@MainActor
struct ThreadRowIndexTests {
    private func row(_ id: String, live: Bool = false) -> NativeThreadRow {
        NativeThreadRow(turn: NativeTurn(id: id, isUser: false, messages: []), presentation: nil, live: live, promptText: nil, startedAt: nil)
    }

    @Test func rebuildsOnlyWhenTheStructureRevisionOrTheFilteredViewChanges() {
        let index = ThreadRowIndex()
        index.update([row("a"), row("b", live: true)], revision: 1)
        #expect(index.ids == ["a", "b"])
        #expect(index.set == ["a", "b"])
        let stamp = index.stamp

        // Live -> finished with unchanged IDs: same revision, nothing rebuilt.
        index.update([row("a"), row("b")], revision: 1)
        #expect(index.stamp == stamp)

        // A filtered view of the rows at one revision (a project thread hiding a turn): the count tells them apart.
        index.update([row("a")], revision: 1)
        #expect(index.ids == ["a"])
        #expect(index.stamp == stamp + 1)
    }

    /// A Project's runtime operations changing can hide one interior turn and show another at the
    /// same revision, count and ends: the filter is part of the key.
    @Test func aNewFilterSwappingInteriorRowsRebuilds() {
        let index = ThreadRowIndex()
        let one = UUID(), two = UUID()
        index.update([row("a"), row("u2"), row("c")], revision: 1, filter: [one])
        let stamp = index.stamp
        index.update([row("a"), row("u2"), row("c")], revision: 1, filter: [one])
        #expect(index.stamp == stamp, "the same filter at the same revision walks nothing")
        index.update([row("a"), row("u1"), row("c")], revision: 1, filter: [two])
        #expect(index.ids == ["a", "u1", "c"] && index.set == ["a", "u1", "c"])
        #expect(index.stamp == stamp + 1)
    }

    @Test func middleReplacementPrependAndResetRebuild() {
        let index = ThreadRowIndex()
        index.update([row("a"), row("b"), row("c")], revision: 1)
        var stamp = index.stamp

        index.update([row("a"), row("x"), row("c")], revision: 2)
        #expect(index.stamp == stamp + 1)
        #expect(index.set == ["a", "x", "c"])
        stamp = index.stamp

        index.update([row("x"), row("a"), row("c")], revision: 3)
        #expect(index.stamp == stamp + 1)
        #expect(index.ids == ["x", "a", "c"])
        stamp = index.stamp

        index.update([row("p"), row("x"), row("a"), row("c")], revision: 4)
        #expect(index.stamp == stamp + 1)
        stamp = index.stamp

        // A revision that moved without new IDs (a replacement put back): an equal set, no new stamp.
        index.update([row("p"), row("x"), row("a"), row("c")], revision: 5)
        #expect(index.stamp == stamp)

        index.update([], revision: 6)
        #expect(index.stamp == stamp + 1)
        #expect(index.ids.isEmpty)
    }
}
