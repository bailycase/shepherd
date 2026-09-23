import Foundation

/// Why a wait gave up: what was awaited, so a failing integration test says what never happened.
public struct WaitTimeout: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "timed out waiting for \(what)" }
}

/// Wait for `condition` to hold, polling quickly. Integration tests use this only where no
/// callback exists to await; it never sleeps a fixed amount. Throws `WaitTimeout` naming `what`.
public func eventually(
    _ what: String,
    timeout: Duration = .seconds(10),
    poll: Duration = .milliseconds(10),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: poll)
    }
    if try await condition() { return }
    throw WaitTimeout(what: what)
}

/// Main-actor form for view-model state.
@MainActor
public func eventuallyOnMain(
    _ what: String,
    timeout: Duration = .seconds(10),
    poll: Duration = .milliseconds(10),
    _ condition: @MainActor () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: poll)
    }
    if try condition() { return }
    throw WaitTimeout(what: what)
}
