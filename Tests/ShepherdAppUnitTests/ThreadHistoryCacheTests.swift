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

    private func key(arrived: Set<String> = []) -> ThreadHistoryCache.Key {
        ThreadHistoryCache.Key(rows: rows(["a", "b"]), dormant: false, boundary: "a", running: false, detached: false, arrived: arrived,
                               inspected: nil, fleet: nil, actions: [false, false, false, false])
    }

    @Test func aKeptStackIsHandedBackUntilTheKeyChanges() {
        let cache = ThreadHistoryCache()
        var made = 0
        func make() -> AnyView {
            made += 1
            return AnyView(Text("\(made)"))
        }
        _ = cache.view(for: key(), make: make)
        _ = cache.view(for: key(), make: make)
        #expect(made == 1)
        _ = cache.view(for: key(arrived: ["b"]), make: make)
        #expect(made == 2)
    }

    @Test func withNoKeyTheStackIsMadeEveryTime() {
        let cache = ThreadHistoryCache()
        var made = 0
        for _ in 0..<3 { _ = cache.view(for: nil) { made += 1; return AnyView(EmptyView()) } }
        #expect(made == 3)
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
