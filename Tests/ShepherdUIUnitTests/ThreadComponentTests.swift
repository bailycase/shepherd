import Testing
@testable import ShepherdUI

@Suite("Thread components")
struct ThreadComponentTests {
    @Test(arguments: [(0.0, "0s"), (14.7, "14s"), (62, "1m 02s"), (3_720, "1h 02m"), (-3, "0s")] as [(Double, String)])
    func liveElapsedCountsWholeSecondsThenMinutes(seconds: Double, text: String) {
        #expect(NWElapsed.text(seconds) == text)
    }
}
