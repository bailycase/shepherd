import Foundation
import Testing
@testable import ShepherdApp

/// The app's start: the server acquires the workspace off the main thread, and nothing that acts
/// on the workspace is made before that succeeds.
@Suite("Launch")
@MainActor
struct ShepherdLaunchTests {
    final class Model {}
    struct Refused: Error {}

    @Test func theModelWaitsForTheServerWhileTheMainActorRuns() async {
        let gate = DispatchSemaphore(value: 0)
        var made = 0
        let launch = ShepherdLaunch<Model>(start: { gate.wait() }, makeModel: { made += 1; return Model() },
                                           failed: { _ in Issue.record("a start that succeeds never fails") })
        let work = launch.begin()
        #expect(launch.begin() == nil, "starts once")
        // The main actor is free while the server starts: this runs, and nothing is made yet.
        await Task.yield()
        #expect(launch.model == nil)
        #expect(made == 0)
        gate.signal()
        await work?.value
        #expect(launch.model != nil)
        #expect(made == 1)
    }

    @Test func aFailedStartMakesNothingAndReportsTheError() async {
        var made = 0
        var failure: Error?
        let launch = ShepherdLaunch<Model>(start: { throw Refused() }, makeModel: { made += 1; return Model() },
                                           failed: { failure = $0 })
        await launch.begin()?.value
        #expect(failure is Refused)
        #expect(made == 0)
        #expect(launch.model == nil)
    }
}
