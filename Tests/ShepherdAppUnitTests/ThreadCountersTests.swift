import Testing
@testable import ShepherdApp

/// The toolbar's counters show the context only once pi has measured it.
@Suite("Thread counters")
struct ThreadCountersTests {
    @Test(arguments: [(nil, nil), (0, nil), (812, "812 ctx"), (46_300, "46k ctx")] as [(Int?, String?)])
    func theContextShowsOnceItIsMeasured(tokens: Int?, text: String?) {
        #expect(ThreadCounters.context(tokens) == text)
    }
}
