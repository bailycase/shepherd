import Foundation
import Testing
@testable import ShepherdApp

/// When the composer says "Starting…": only for a pi slower than a normal start, and sooner
/// over a thread that has nothing to show.
@Suite("Starting indicator")
struct StartingIndicatorTests {
    @Test(arguments: [
        (false, AppLayout.startingIndicatorDelay, AppLayout.startingIndicatorDelay),
        (true, AppLayout.startingIndicatorDelay, AppLayout.blankStartingIndicatorDelay),
        (false, Duration.zero, Duration.zero),
        (true, Duration.zero, Duration.zero),
    ] as [(Bool, Duration, Duration)])
    func aBlankThreadIsExplainedSoonerThanOneThatDrawsSomething(blank: Bool, delay: Duration, expected: Duration) {
        #expect(Composer.startingDelay(blank: blank, delay: delay) == expected)
    }

    /// pi as Shepherd launches it answers about 0.8 s after ⌘N and 1 s after a relaunch (on
    /// the machine the start path was measured on): a thread that draws something waits well
    /// past that, so a normal start never says it is starting.
    @Test func aNormalStartIsOverBeforeAThreadThatDrawsSomethingSaysPiIsStarting() {
        let normalStart = Duration.milliseconds(1000)
        #expect(AppLayout.startingIndicatorDelay >= normalStart * 2)
    }
}
