import Foundation

/// Separate processes exercise the actual fixture failure path without UIKit or a simulator.
@main
struct FixtureReadinessCheck {
    @MainActor static func main() async {
        switch CommandLine.arguments.last {
        case "timeout":
            await FixtureCheck.wait("missing snapshot", seconds: 0) { false }
        case "failed-check":
            FixtureCheck.report("FIXTURE CHECK FAILED: missing proposal pins")
        case "cancelled":
            let task = Task {
                await FixtureCheck.wait("cancelled snapshot", seconds: 10) { false }
            }
            task.cancel()
            await task.value
        default:
            await FixtureCheck.wait("loaded snapshot", seconds: 0) { true }
        }
        print("FIXTURE READY readiness-check")
    }
}
