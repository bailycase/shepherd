import Foundation
import Testing

/// Why a wait gave up: what was awaited, so a failing integration test says what never happened.
public struct WaitTimeout: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "timed out waiting for \(what)" }
}

/// How long a wait gives a condition by default. The happy path returns as soon as it holds;
/// the bound is for a process started on a loaded 3-core CI runner, where a stub pi took about
/// ten seconds to answer.
public let defaultWaitTimeout: Duration = .seconds(30)

/// Wait for `condition` to hold, polling quickly. Integration tests use this only where no
/// callback exists to await; it never sleeps a fixed amount. Throws `WaitTimeout` naming `what`.
public func eventually(
    _ what: String,
    timeout: Duration = defaultWaitTimeout,
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
    timeout: Duration = defaultWaitTimeout,
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

/// Runs the body of an exit test (`#expect(processExitsWith:)`), recording what it throws as an
/// issue. An error that escapes the body kills the child process with SIGTRAP ("Error raised at
/// top level"), and the parent reports only the signal; recorded, a wait that timed out fails
/// the test by what it waited for. A failed `#require` has already recorded its own issue.
public func recordingErrors(sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void) async {
    do {
        try await body()
    } catch is ExpectationFailedError {
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}
