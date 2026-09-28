import Foundation

/// Fixture failures terminate before the runner can announce READY or capture a misleading screen.
enum FixtureCheck {
    static func fail(_ message: String) -> Never {
        print("FIXTURE FAILED \(message)")
        fflush(stdout)
        exit(1)
    }

    static func report(_ message: String) {
        print(message)
        if message.hasPrefix("FIXTURE CHECK FAILED") { fail(message) }
    }

    @MainActor
    static func wait(_ name: String, seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Task.isCancelled { fail("Cancelled waiting for \(name)") }
            if Date() >= deadline { fail("Timed out after \(seconds)s waiting for \(name)") }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { fail("Cancelled waiting for \(name): \(error)") }
        }
    }
}
