import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdApp

/// The automatic pi update check waits a minute after launch and runs at most once a day across
/// launches, so relaunching many agents never competes with a login shell running pi and npm.
@Suite("Pi update schedule")
@MainActor
struct PiUpdateScheduleTests {
    nonisolated private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    nonisolated private static let day: TimeInterval = 86_400

    /// (hours since the last successful check, nil for never; due; seconds until the first check)
    @Test(arguments: [
        (nil, true, 60.0),
        (0.0, false, day),
        (1.0, false, day - 3_600),
        (23.99, false, 60.0),
        (24.0, true, 60.0),
        (72.0, true, 60.0),
    ] as [(Double?, Bool, Double)])
    func aCheckWithinADayIsSkippedAndTheFirstWaitsAMinute(hoursAgo: Double?, due: Bool, firstCheck: Double) {
        let lastChecked = hoursAgo.map { Self.now.addingTimeInterval(-$0 * 3_600) }
        #expect(PiUpdateManager.isCheckDue(now: Self.now, lastChecked: lastChecked) == due)
        let delay = PiUpdateManager.firstCheckDelay(now: Self.now, lastChecked: lastChecked)
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        #expect(abs(seconds - firstCheck) < 1)
    }

    /// A successful check's result survives a relaunch, so the next launch knows it is recent
    /// and Settings shows it before any new check.
    @Test func aSuccessfulCheckIsRestoredByTheNextLaunch() {
        let defaults = ScratchDefaults()
        PiUpdateManager(defaults: defaults).recordCheck(current: "0.87.1", latest: "0.88.0", at: Self.now)

        let relaunched = PiUpdateManager(defaults: defaults)
        #expect(relaunched.lastChecked == Self.now)
        #expect(relaunched.currentVersion == "0.87.1" && relaunched.latestVersion == "0.88.0")
        #expect(relaunched.isOutdated)
        #expect(PiUpdateManager(defaults: ScratchDefaults()).lastChecked == nil)
    }
}
