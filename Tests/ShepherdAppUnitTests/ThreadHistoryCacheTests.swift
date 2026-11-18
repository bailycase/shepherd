import SwiftUI
import Testing
@testable import ShepherdRemote
@testable import ShepherdApp

/// The history stack is kept as the view it was while its key is unchanged (`ThreadHistoryCache`), so what the key holds and leaves out
/// decides when a switch redraws the stack.
@Suite("Thread history cache")
@MainActor
struct ThreadHistoryCacheTests {
    private func rows(_ ids: [String]) -> ArraySlice<NativeThreadRow> {
        ids.map { NativeThreadRow(turn: NativeTurn(id: $0, isUser: false, messages: []), presentation: nil, live: false, promptText: nil, startedAt: nil) }[...]
    }

    private func key(arrived: Set<String> = [], store: NativeThreadStore, tailGuard: ThreadTailGuard) -> ThreadHistoryCache.Key {
        ThreadHistoryCache.Key(rows: rows(["a", "b"]), dormant: false, boundary: "a", running: false, detached: false, arrived: arrived,
                               inspected: nil, fleet: nil, actions: [false, false, false, false],
                               store: ObjectIdentifier(store), tailGuard: ObjectIdentifier(tailGuard))
    }

    @Test func aKeptStackIsHandedBackUntilTheKeyChanges() {
        let cache = ThreadHistoryCache()
        let store = NativeThreadStore(), tailGuard = ThreadTailGuard()
        var made = 0
        func make() -> AnyView {
            made += 1
            return AnyView(Text("\(made)"))
        }
        _ = cache.view(for: key(store: store, tailGuard: tailGuard), make: make)
        _ = cache.view(for: key(store: store, tailGuard: tailGuard), make: make)
        #expect(made == 1)
        _ = cache.view(for: key(arrived: ["b"], store: store, tailGuard: tailGuard), make: make)
        #expect(made == 2)
    }

    @Test func withNoKeyTheStackIsMadeEveryTime() {
        let cache = ThreadHistoryCache()
        var made = 0
        for _ in 0..<3 { _ = cache.view(for: nil) { made += 1; return AnyView(EmptyView()) } }
        #expect(made == 3)
    }

    @Test func anotherStoreOrTailGuardIsAnotherKey() {
        let store = NativeThreadStore(), tailGuard = ThreadTailGuard()
        let same = key(store: store, tailGuard: tailGuard)
        #expect(same == key(store: store, tailGuard: tailGuard))
        #expect(same != key(store: NativeThreadStore(), tailGuard: tailGuard))
        #expect(same != key(store: store, tailGuard: ThreadTailGuard()))
    }

    @Test func arrivalsInTheTailAreNotTheHistorys() {
        let history = rows(["h0", "h1", "h2"]), tail = rows(["t0", "t1"])
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: []).isEmpty)
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: ["t1"]).isEmpty)
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: ["t0", "t1"]).isEmpty)
    }

    /// A batch larger than the tail reaches the history, and only its rows there count; one not drawn at all counts nowhere.
    @Test func aBatchLargerThanTheTailKeepsItsArrivalsInTheHistory() {
        let history = rows(["h0", "h1", "h2"]), tail = rows(["t0", "t1"])
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: ["h2", "t0", "t1"]) == ["h2"])
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: ["h0", "h1", "h2", "t0", "t1"]) == ["h0", "h1", "h2"])
        #expect(ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: ["gone", "t1"]).isEmpty)
    }
}

/// When the history's stack starts again (`ThreadHistoryBuilt`).
@Suite("Thread history built")
@MainActor
struct ThreadHistoryBuiltTests {
    private func rows(_ range: Range<Int>) -> ArraySlice<NativeThreadRow> {
        range.map { NativeThreadRow(turn: NativeTurn(id: "r\($0)", isUser: false, messages: []), presentation: nil, live: false, promptText: nil, startedAt: nil) }[...]
    }

    /// Adds `count` rows at the end, two at a time as a turn does, until the stack starts again or they are all added.
    private func grow(_ built: ThreadHistoryBuilt, from start: Int, by count: Int, onScreen: Bool = true, mayLetGo: Bool = true) -> (end: Int, stack: Int) {
        var end = start
        while end < start + count {
            end += 2
            _ = built.stack(history: rows(0..<end), onScreen: onScreen, mayLetGo: mayLetGo)
        }
        return (end, built.stack)
    }

    @Test func aStackStartsAgainAfterTheRowsItMayHaveBuiltHaveBeenAdded() {
        let built = ThreadHistoryBuilt()
        _ = built.stack(history: rows(0..<10), onScreen: true, mayLetGo: true)
        let (end, stack) = grow(built, from: 10, by: ThreadHistoryBuilt.rows - 2)
        #expect(stack == 0, "not before")
        _ = built.stack(history: rows(0..<(end + 2)), onScreen: true, mayLetGo: true)
        #expect(built.stack == 1)
    }

    @Test func aReaderAwayFromTheTailKeepsTheStackUntilTheyAreBack() {
        let built = ThreadHistoryBuilt()
        _ = built.stack(history: rows(0..<10), onScreen: true, mayLetGo: false)
        let (end, stack) = grow(built, from: 10, by: 3 * ThreadHistoryBuilt.rows, mayLetGo: false)
        #expect(stack == 0)
        _ = built.stack(history: rows(0..<end), onScreen: true, mayLetGo: true)
        #expect(built.stack == 1, "once they are back at the tail")
    }

    @Test func rowsPagedInAboveOrAThreadComingBackAreNotCounted() {
        let built = ThreadHistoryBuilt()
        _ = built.stack(history: rows(0..<10), onScreen: true, mayLetGo: true)
        // Older rows join at the top: the last row is the same.
        let older = (0..<200).map { NativeThreadRow(turn: NativeTurn(id: "o\($0)", isUser: false, messages: []), presentation: nil, live: false, promptText: nil, startedAt: nil) }
        _ = built.stack(history: (older + rows(0..<10))[...], onScreen: true, mayLetGo: true)
        // The whole thread comes back at once after being let go.
        _ = built.stack(history: [], onScreen: true, mayLetGo: true)
        _ = built.stack(history: rows(0..<300), onScreen: true, mayLetGo: true)
        #expect(built.stack == 0)
    }

    @Test func aHiddenThreadsGrowthIsNotCounted() {
        let built = ThreadHistoryBuilt()
        _ = built.stack(history: rows(0..<10), onScreen: false, mayLetGo: true)
        let (end, stack) = grow(built, from: 10, by: 3 * ThreadHistoryBuilt.rows, onScreen: false)
        #expect(stack == 0)
        _ = built.stack(history: rows(0..<end), onScreen: true, mayLetGo: true)
        #expect(built.stack == 0, "shown again, it has built nothing for them")
    }
}
